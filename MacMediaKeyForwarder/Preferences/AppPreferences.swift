import Foundation
import Observation

// MARK: - Priority Mode

enum MediaKeysPriority: Int {
    /// Send events to both players if running.
    case none = 0
    /// Prioritize iTunes/Apple Music over Spotify.
    case iTunes = 1
    /// Prioritize Spotify over iTunes/Apple Music.
    case spotify = 2
}

// MARK: - Pause State

enum PauseMode: Int {
    /// Normal operation — forward all media key events.
    case none = 0
    /// Manually paused — do not forward any events.
    case paused = 1
    /// Automatic — only forward events when a player is running.
    case automatic = 2
}

// MARK: - Preferences

@Observable
final class AppPreferences {

    private enum Keys {
        static let priority = "user_priority_option"
        static let pause = "user_pause_option"
        static let hideFromMenuBar = "user_hide_from_menu_bar_option"
    }

    var priority: MediaKeysPriority {
        didSet { UserDefaults.standard.set(priority.rawValue, forKey: Keys.priority) }
    }

    var pauseMode: PauseMode {
        didSet { UserDefaults.standard.set(pauseMode.rawValue, forKey: Keys.pause) }
    }

    var hideFromMenuBar: Bool {
        didSet { UserDefaults.standard.set(hideFromMenuBar, forKey: Keys.hideFromMenuBar) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.priority = MediaKeysPriority(rawValue: defaults.integer(forKey: Keys.priority)) ?? .none
        self.pauseMode = PauseMode(rawValue: defaults.integer(forKey: Keys.pause)) ?? .none
        self.hideFromMenuBar = defaults.bool(forKey: Keys.hideFromMenuBar)
    }
}
