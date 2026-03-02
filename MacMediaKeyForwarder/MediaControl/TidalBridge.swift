import Cocoa

/// Controls Tidal (com.tidal.desktop) via CGEvent keyboard events posted
/// directly to the process.  Tidal has no AppleScript dictionary, so
/// SBApplication cannot be used.
final class TidalBridge {

    private static let bundleID = "com.tidal.desktop"

    private var app: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    var isRunning: Bool { app != nil }

    func playPause() { launchOrSendKey(code: 49) }                           // Space
    func nextTrack() { launchOrSendKey(code: 124, flags: .maskCommand) }     // Cmd+Right
    func previousTrack() { launchOrSendKey(code: 123, flags: .maskCommand) } // Cmd+Left

    private func launchOrSendKey(code: CGKeyCode, flags: CGEventFlags = []) {
        if !isRunning {
            launch()
            return
        }
        sendKey(code: code, flags: flags)
    }

    private func launch() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

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
