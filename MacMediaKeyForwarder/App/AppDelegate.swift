import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Nib-less entry point: create the application, set the delegate, and run.
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let preferences = AppPreferences()
    private let eventTap = MediaKeyEventTap()
    private var playerController: MediaPlayerController!
    private var statusBarController: StatusBarController!

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        playerController = MediaPlayerController(preferences: preferences)

        // Create the event tap (requires accessibility permission)
        guard eventTap.createTap() else {
            showAccessibilityAlert()
            exit(0)
        }

        // Wire event tap to player controller
        eventTap.onMediaKeyEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.playerController.handleEvent(event)
            }
        }

        // Create status bar UI
        statusBarController = StatusBarController(preferences: preferences, eventTap: eventTap)

        // Start listening (unless manually paused)
        if preferences.pauseMode != .paused {
            eventTap.startListening()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBarController?.showStatusItem()
        return true
    }

    // MARK: - Accessibility Alert

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            MacMediaKeyForwarder needs accessibility permission to capture media keys.

            1. Open System Settings
            2. Go to Privacy & Security \u{2192} Accessibility
            3. Add MacMediaKeyForwarder to the list
            4. Restart the app
            """
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!
            NSWorkspace.shared.open(url)
        }
    }
}
