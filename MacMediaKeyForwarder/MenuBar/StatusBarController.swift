import Cocoa

/// Manages the `NSStatusItem`, its menu, and all menu actions.
final class StatusBarController: NSObject, NSMenuDelegate {

    private let preferences: AppPreferences
    private let eventTap: MediaKeyEventTap

    private var statusItem: NSStatusItem!
    private var priorityItems: [NSMenuItem] = []
    private var pauseItems: [NSMenuItem] = []
    private var startupItem: NSMenuItem!
    private var hideFromMenuBarItem: NSMenuItem!

    init(preferences: AppPreferences, eventTap: MediaKeyEventTap) {
        self.preferences = preferences
        self.eventTap = eventTap
        super.init()
        setupStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        // Version string
        let bundleInfo = Bundle.main.infoDictionary ?? [:]
        let version = bundleInfo["CFBundleShortVersionString"] as? String ?? "?"
        let versionString = "Version \(version)"

        // Build menu
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: versionString, action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // Pause options
        let pauseItem = menu.addItem(
            withTitle: String(localized: "Pause"),
            action: #selector(manualPause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        pauseItems.append(pauseItem)

        let autoPauseItem = menu.addItem(
            withTitle: String(localized: "Pause if no player is running"),
            action: #selector(autoPause),
            keyEquivalent: ""
        )
        autoPauseItem.target = self
        pauseItems.append(autoPauseItem)

        menu.addItem(.separator())

        // Priority options
        let bothItem = menu.addItem(
            withTitle: String(localized: "Send events to both players"),
            action: #selector(prioritizeNone),
            keyEquivalent: ""
        )
        bothItem.target = self
        priorityItems.append(bothItem)

        let iTunesItem = menu.addItem(
            withTitle: String(localized: "Prioritize iTunes"),
            action: #selector(prioritizeITunes),
            keyEquivalent: ""
        )
        iTunesItem.target = self
        priorityItems.append(iTunesItem)

        let spotifyItem = menu.addItem(
            withTitle: String(localized: "Prioritize Spotify"),
            action: #selector(prioritizeSpotify),
            keyEquivalent: ""
        )
        spotifyItem.target = self
        priorityItems.append(spotifyItem)

        menu.addItem(.separator())

        // Login item & hide
        startupItem = menu.addItem(
            withTitle: String(localized: "Open at login"),
            action: #selector(toggleStartupItem),
            keyEquivalent: ""
        )
        startupItem.target = self

        hideFromMenuBarItem = menu.addItem(
            withTitle: String(localized: "Hide from menu bar"),
            action: #selector(hideFromMenuBar),
            keyEquivalent: ""
        )
        hideFromMenuBarItem.target = self

        menu.addItem(.separator())

        // Support & updates
        let donateItem = menu.addItem(
            withTitle: String(localized: "Donate if you like the app"),
            action: #selector(support),
            keyEquivalent: ""
        )
        donateItem.target = self

        let updateItem = menu.addItem(
            withTitle: String(localized: "Check for updates"),
            action: #selector(update),
            keyEquivalent: ""
        )
        updateItem.target = self

        let quitItem = menu.addItem(
            withTitle: String(localized: "Quit"),
            action: #selector(quit),
            keyEquivalent: ""
        )
        quitItem.target = self

        // Status item
        let image = NSImage(named: "icon")
        image?.isTemplate = true

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Mac Media Key Forwarder"
        statusItem.button?.image = image
        statusItem.menu = menu
        statusItem.behavior = .removalAllowed
        statusItem.isVisible = !preferences.hideFromMenuBar

        // Initial UI state
        updatePauseCheckmarks()
        updatePriorityCheckmarks()
        updateStartupItemCheckmark()
    }

    // MARK: - Public

    /// Makes the status item visible again (used when re-opening the app).
    func showStatusItem() {
        if preferences.hideFromMenuBar {
            preferences.hideFromMenuBar = false
            statusItem.isVisible = true
        }
    }

    // MARK: - Pause Actions

    @objc private func manualPause() {
        if preferences.pauseMode != .paused {
            preferences.pauseMode = .paused
            eventTap.stopListening()
        } else {
            preferences.pauseMode = .none
            eventTap.startListening()
        }
        updatePauseCheckmarks()
    }

    @objc private func autoPause() {
        if preferences.pauseMode != .automatic {
            preferences.pauseMode = .automatic
        } else {
            preferences.pauseMode = .none
        }
        updatePauseCheckmarks()
        eventTap.startListening()
    }

    // MARK: - Priority Actions

    @objc private func prioritizeNone() {
        preferences.priority = .none
        updatePriorityCheckmarks()
    }

    @objc private func prioritizeITunes() {
        preferences.priority = .iTunes
        updatePriorityCheckmarks()
    }

    @objc private func prioritizeSpotify() {
        preferences.priority = .spotify
        updatePriorityCheckmarks()
    }

    // MARK: - Other Actions

    @objc private func toggleStartupItem() {
        LoginItemManager.toggle()
        updateStartupItemCheckmark()
    }

    @objc private func hideFromMenuBar() {
        preferences.hideFromMenuBar = true
        LoginItemManager.ensureRegistered()
        statusItem.isVisible = false
    }

    @objc private func support() {
        NSWorkspace.shared.open(URL(string: "https://paypal.me/philippgmeyer")!)
    }

    @objc private func update() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Quppi/macmediakeyforwarder/releases")!)
    }

    @objc private func quit() {
        eventTap.stopListening()
        NSApp.terminate(nil)
    }

    // MARK: - UI State

    private func updatePauseCheckmarks() {
        pauseItems[0].state = preferences.pauseMode == .paused ? .on : .off
        pauseItems[1].state = preferences.pauseMode == .automatic ? .on : .off
    }

    private func updatePriorityCheckmarks() {
        for (index, item) in priorityItems.enumerated() {
            item.state = index == preferences.priority.rawValue ? .on : .off
        }
    }

    private func updateStartupItemCheckmark() {
        startupItem.state = LoginItemManager.isLoginItem ? .on : .off
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateStartupItemCheckmark()
    }
}
