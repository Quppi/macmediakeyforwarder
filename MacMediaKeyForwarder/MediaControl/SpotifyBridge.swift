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

    private lazy var app: (any SpotifyApplication)? = {
        SBApplication(bundleIdentifier: Self.bundleID)
    }()

    init() {
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
            app?.playpause?()
        } else {
            Self.log.notice("playPause via CGEvent fallback (no Automation permission)")
            sendKey(code: 49) // Space
        }
    }

    func nextTrack() {
        if hasAutomationPermission {
            Self.log.notice("nextTrack via ScriptingBridge")
            app?.nextTrack?()
        } else {
            Self.log.notice("nextTrack via CGEvent fallback")
            sendKey(code: 124, flags: .maskCommand) // Cmd+Right
        }
    }

    func previousTrack() {
        if hasAutomationPermission {
            Self.log.notice("previousTrack via ScriptingBridge")
            app?.previousTrack?()
        } else {
            Self.log.notice("previousTrack via CGEvent fallback")
            sendKey(code: 123, flags: .maskCommand) // Cmd+Left
        }
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
