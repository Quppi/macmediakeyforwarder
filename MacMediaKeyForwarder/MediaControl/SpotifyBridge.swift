import Cocoa
import ScriptingBridge
import os.log

// MARK: - ScriptingBridge Protocol

@objc private protocol SpotifyApplication {
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func previousTrack()
}

extension SBApplication: SpotifyApplication {}

// MARK: - Spotify Bridge

/// Controls Spotify via ScriptingBridge when Automation permission is granted,
/// falling back to CGEvent keyboard simulation when it is not.
final class SpotifyBridge {

    static let bundleID = "com.spotify.client"

    private static let log = Logger(
        subsystem: "eu.meyer.mmkf", category: "SpotifyBridge"
    )

    /// Serial queue for every Apple Event sent to Spotify.
    ///
    /// `AESendMessage` is synchronous, so a target that stops answering parks
    /// the calling thread — with no upper bound in practice. On the main thread
    /// that froze the entire app: the menu bar stopped responding and the media
    /// key tap could no longer run, so macOS disabled it and the keys fell
    /// through to whatever app was in front. Commands therefore never run on
    /// the main thread.
    private let commandQueue = DispatchQueue(
        label: "eu.meyer.mmkf.spotify-commands", qos: .userInitiated
    )

    /// Built eagerly so the command queue never races on lazy initialization.
    private let app: (any SpotifyApplication)?

    init() {
        let app = SBApplication(bundleIdentifier: Self.bundleID)
        // Fire and forget: media transport commands have no useful reply, and
        // never let Spotify put up UI that we would then be waiting on.
        app?.sendMode = AESendMode(kAENoReply | kAENeverInteract)
        // Bounds the connect handshake, in ticks (1/60 s).
        app?.timeout = 120
        self.app = app

        AutomationPermissionMonitor.shared.refresh(bundleID: Self.bundleID)
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    /// Whether Automation permission is currently granted for Spotify.
    /// Reads the cached status — never blocks (the live check can hang).
    var hasAutomationPermission: Bool {
        AutomationPermissionMonitor.shared.canAutomate(bundleID: Self.bundleID)
    }

    func playPause() {
        if hasAutomationPermission {
            Self.log.notice("playPause via ScriptingBridge")
            perform { $0.playpause?() }
        } else {
            Self.log.notice("playPause via CGEvent fallback (no Automation permission)")
            sendKey(code: 49) // Space
        }
    }

    func nextTrack() {
        if hasAutomationPermission {
            Self.log.notice("nextTrack via ScriptingBridge")
            perform { $0.nextTrack?() }
        } else {
            Self.log.notice("nextTrack via CGEvent fallback")
            sendKey(code: 124, flags: .maskCommand) // Cmd+Right
        }
    }

    func previousTrack() {
        if hasAutomationPermission {
            Self.log.notice("previousTrack via ScriptingBridge")
            perform { $0.previousTrack?() }
        } else {
            Self.log.notice("previousTrack via CGEvent fallback")
            sendKey(code: 123, flags: .maskCommand) // Cmd+Left
        }
    }

    /// Sends an Apple Event off the main thread — see `commandQueue`.
    private func perform(_ command: @escaping (any SpotifyApplication) -> Void) {
        guard let app else { return }
        commandQueue.async { command(app) }
    }

    // MARK: - CGEvent Fallback

    private var runningApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    private func sendKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let pid = runningApp?.processIdentifier else { return }
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
