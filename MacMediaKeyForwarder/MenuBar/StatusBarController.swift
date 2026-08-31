import Cocoa
import os.log

/// Manages the `NSStatusItem`, its menu, and all menu actions.
final class StatusBarController: NSObject, NSMenuDelegate {

    private static let log = Logger(
        subsystem: "eu.meyer.mmkf", category: "StatusBarController"
    )

    private let preferences: AppPreferences
    private let eventTap: MediaKeyEventTap

    private var statusItem: NSStatusItem!
    private var priorityItems: [NSMenuItem] = []
    private var pauseItems: [NSMenuItem] = []
    private var startupItem: NSMenuItem!
    private var hideFromMenuBarItem: NSMenuItem!
    private var permissionWarningItem: NSMenuItem!
    private var redDotView: NSView?

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

        // Automation permission warning (hidden by default)
        permissionWarningItem = menu.addItem(
            withTitle: "",
            action: #selector(openAutomationSettings),
            keyEquivalent: ""
        )
        permissionWarningItem.attributedTitle = NSAttributedString(
            string: String(localized: "Automation permission needed"),
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        permissionWarningItem.target = self
        permissionWarningItem.isHidden = true

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

        let tidalItem = menu.addItem(
            withTitle: String(localized: "Prioritize Tidal"),
            action: #selector(prioritizeTidal),
            keyEquivalent: ""
        )
        tidalItem.target = self
        priorityItems.append(tidalItem)

        let deezerItem = menu.addItem(
            withTitle: String(localized: "Prioritize Deezer"),
            action: #selector(prioritizeDeezer),
            keyEquivalent: ""
        )
        deezerItem.target = self
        priorityItems.append(deezerItem)

        let plexampItem = menu.addItem(
            withTitle: String(localized: "Prioritize Plexamp"),
            action: #selector(prioritizePlexamp),
            keyEquivalent: ""
        )
        plexampItem.target = self
        priorityItems.append(plexampItem)

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

        // Red dot indicator for missing permissions
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 3
        dot.frame = NSRect(x: 0, y: 0, width: 6, height: 6)
        dot.isHidden = true
        statusItem.button?.addSubview(dot)
        // Position in top-right corner of the button
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.topAnchor.constraint(equalTo: statusItem.button!.topAnchor, constant: 2),
            dot.trailingAnchor.constraint(equalTo: statusItem.button!.trailingAnchor, constant: -1),
        ])
        redDotView = dot

        // Initial UI state
        updatePauseCheckmarks()
        updatePriorityCheckmarks()
        updateStartupItemCheckmark()
        updatePermissionWarning()
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

    @objc private func prioritizeITunes() {
        preferences.priority = .iTunes
        updatePriorityCheckmarks()
        updatePermissionWarning()
    }

    @objc private func prioritizeSpotify() {
        preferences.priority = .spotify
        updatePriorityCheckmarks()
        updatePermissionWarning()
    }

    @objc private func prioritizeTidal() {
        preferences.priority = .tidal
        updatePriorityCheckmarks()
        updatePermissionWarning()
    }

    @objc private func prioritizeDeezer() {
        preferences.priority = .deezer
        updatePriorityCheckmarks()
        updatePermissionWarning()
    }

    @objc private func prioritizePlexamp() {
        preferences.priority = .plexamp
        updatePriorityCheckmarks()
        updatePermissionWarning()
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

    @objc private func openAutomationSettings() {
        // Opens System Settings → Privacy & Security → Automation
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        )
    }

    // MARK: - UI State

    private func updatePauseCheckmarks() {
        pauseItems[0].state = preferences.pauseMode == .paused ? .on : .off
        pauseItems[1].state = preferences.pauseMode == .automatic ? .on : .off
    }

    private func updatePriorityCheckmarks() {
        for (index, item) in priorityItems.enumerated() {
            item.state = (index + 1) == preferences.priority.rawValue ? .on : .off
        }
    }

    private func updateStartupItemCheckmark() {
        startupItem.state = LoginItemManager.isLoginItem ? .on : .off
    }

    private func updatePermissionWarning() {
        let bundleID: String?
        switch preferences.priority {
        case .spotify:
            bundleID = SpotifyBridge.bundleID
        case .iTunes:
            bundleID = AppleMusicBridge.bundleID
        case .tidal, .deezer, .plexamp:
            // These don't use ScriptingBridge, so no warning needed
            bundleID = nil
        }

        let permissionMissing = bundleID.map { !canAutomateApp(bundleID: $0) } ?? false

        permissionWarningItem.isHidden = !permissionMissing
        redDotView?.isHidden = !permissionMissing

        if permissionMissing, let bundleID {
            Self.log.notice("Automation permission missing for \(bundleID, privacy: .public)")
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        updateStartupItemCheckmark()
        updatePermissionWarning()
    }
}
