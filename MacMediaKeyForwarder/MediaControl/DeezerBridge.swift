import Cocoa
import os

/// Controls Deezer (com.deezer.deezer-desktop) via Chrome DevTools Protocol
/// for next/prev track commands (which rely on Electron menu accelerators that
/// only work when the app is focused) and CGEvent keyboard events for play/pause
/// (Space key is handled by a JS keydown listener, which works regardless of focus).
///
/// On startup, if Deezer is already running without CDP, it is terminated and
/// relaunched with `--remote-debugging-port` so that `window.dzPlayer.control`
/// can be called via `Runtime.evaluate` over the CDP WebSocket.
final class DeezerBridge {

    private static let bundleID = "com.deezer.deezer-desktop"
    private static let cdpPort: UInt16 = 28433
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MacMediaKeyForwarder",
        category: "DeezerBridge"
    )

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config)
    }()

    private var webSocket: URLSessionWebSocketTask?
    private var messageID = 0
    private var isConnecting = false

    private var app: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    var isRunning: Bool { app != nil }

    private var cdpConnected: Bool { webSocket != nil }

    // MARK: - Startup

    /// Try to connect CDP if Deezer is already running (e.g. from a previous
    /// session that launched it with the debug port). Does NOT relaunch —
    /// relaunch only happens on an actual next/prev key press.
    func connectIfRunning() {
        guard isRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            if await self.connectWebSocket() {
                Self.logger.info("CDP connected to running Deezer on startup")
            }
        }
    }

    // MARK: - Media Control

    /// Play/pause via CGEvent Space key (works from background without CDP).
    func playPause() {
        if !isRunning {
            launchWithCDP()                    // launch with CDP so next/prev works right away
            ensureCDPAsync(afterLaunch: true)   // connect WebSocket in background
            return
        }
        sendKey(code: 49) // Space — already running, works regardless of CDP
    }

    /// Next track via CDP JavaScript call.
    func nextTrack() {
        if cdpConnected {
            evaluateJS("window.dzPlayer.control.nextSong()")
            return
        }
        if !isRunning {
            launchWithCDP()
            ensureCDPAsync(afterLaunch: true)
            return
        }
        // Running but no CDP — fall back to CGEvent, set up CDP for next time
        ensureCDPAsync(afterLaunch: false)
        sendKey(code: 124, flags: .maskShift)
    }

    /// Previous track via CDP JavaScript call.
    func previousTrack() {
        if cdpConnected {
            evaluateJS("window.dzPlayer.control.prevSong()")
            return
        }
        if !isRunning {
            launchWithCDP()
            ensureCDPAsync(afterLaunch: true)
            return
        }
        ensureCDPAsync(afterLaunch: false)
        sendKey(code: 123, flags: .maskShift)
    }

    // MARK: - CDP Communication

    private func evaluateJS(_ expression: String) {
        guard let ws = webSocket else { return }
        messageID += 1
        let message: [String: Any] = [
            "id": messageID,
            "method": "Runtime.evaluate",
            "params": ["expression": expression]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }

        ws.send(.string(json)) { [weak self] error in
            if let error {
                Self.logger.error("CDP send failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.disconnectWebSocket()
                }
            }
        }
    }

    // MARK: - CDP Connection Management

    private func ensureCDPAsync(afterLaunch: Bool) {
        guard !isConnecting else { return }
        isConnecting = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isConnecting = false }

            if afterLaunch {
                await self.pollForCDP(timeoutSeconds: 15)
            } else {
                if await self.connectWebSocket() {
                    Self.logger.info("CDP connected to running Deezer")
                    return
                }
                guard self.isRunning else { return }
                Self.logger.info("Deezer running without CDP — relaunching")
                await self.relaunchWithCDP()
            }
        }
    }

    /// Poll the CDP endpoint until a WebSocket connection succeeds.
    @discardableResult
    private func pollForCDP(timeoutSeconds: Int) async -> Bool {
        let maxAttempts = timeoutSeconds * 10
        for _ in 0..<maxAttempts {
            if await connectWebSocket() {
                Self.logger.info("CDP connected")
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        Self.logger.warning("CDP connection timed out after \(timeoutSeconds)s")
        return false
    }

    /// Discover the debugger WebSocket URL via HTTP and connect.
    private func connectWebSocket() async -> Bool {
        let listURL = URL(string: "http://localhost:\(Self.cdpPort)/json")!

        guard let (data, _) = try? await session.data(from: listURL),
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let page = targets.first(where: { ($0["type"] as? String) == "page" }),
              let wsString = page["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: wsString) else {
            return false
        }

        let ws = session.webSocketTask(with: wsURL)
        ws.resume()

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                ws.sendPing { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
            self.webSocket = ws
            startReceiving(ws)
            return true
        } catch {
            ws.cancel(with: .goingAway, reason: nil)
            return false
        }
    }

    /// Keep the receive loop alive to detect disconnection.
    private func startReceiving(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            switch result {
            case .success:
                self?.startReceiving(ws)
            case .failure:
                DispatchQueue.main.async {
                    self?.disconnectWebSocket()
                }
            }
        }
    }

    private func disconnectWebSocket() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }

    /// Terminate Deezer, relaunch with CDP flag, and wait for connection.
    private func relaunchWithCDP() async {
        guard let runningApp = app else { return }

        runningApp.terminate()

        // Wait for Deezer to quit (up to 5 seconds)
        for _ in 0..<50 {
            if !isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Force-kill if still running
        if let stubborn = app {
            stubborn.forceTerminate()
            try? await Task.sleep(for: .milliseconds(500))
        }

        launchWithCDP()
        await pollForCDP(timeoutSeconds: 15)
    }

    // MARK: - Launch

    private func launchWithCDP() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.bundleID
        ) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--remote-debugging-port=\(Self.cdpPort)"]
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: - CGEvent Fallback

    private func sendKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let pid = app?.processIdentifier else { return }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up   = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        if !flags.isEmpty {
            down?.flags = flags
            up?.flags = flags
        }
        down?.postToPid(pid)
        up?.postToPid(pid)
    }
}
