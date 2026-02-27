import Foundation

/// Routes media key events to the appropriate player based on the current
/// priority mode and pause state.
///
/// Faithfully ports the behavior from AppDelegate.m lines 95-262.
final class MediaPlayerController {

    let preferences: AppPreferences
    let appleMusic = AppleMusicBridge()
    let spotify = SpotifyBridge()

    /// Key-hold state machine for iTunes-priority fast-forward/rewind detection.
    private var keyHoldMachine = KeyHoldStateMachine()

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    // MARK: - Event Handling

    /// Main entry point: receives a parsed media key event and dispatches it.
    func handleEvent(_ event: MediaKeyEvent) {
        // Manual pause — don't forward anything
        if preferences.pauseMode == .paused {
            return
        }

        // Auto-pause — only forward when at least one player is running
        if preferences.pauseMode == .automatic {
            if !spotify.isRunning && !appleMusic.isRunning {
                return
            }
        }

        if event.isPressed {
            handleKeyDown(event)
        } else {
            handleKeyUp(event)
        }
    }

    // MARK: - Key Down

    private func handleKeyDown(_ event: MediaKeyEvent) {
        switch preferences.priority {
        case .iTunes:
            handleiTunesPriorityKeyDown(event)
        case .spotify:
            handleSpotifyPriorityKeyDown(event)
        case .none:
            handleBothPlayersKeyDown(event)
        }
    }

    private func handleiTunesPriorityKeyDown(_ event: MediaKeyEvent) {
        switch event.keyCode {
        case .play:
            appleMusic.playPause()

        case .next, .fast, .previous, .rewind:
            let action = keyHoldMachine.keyDown()
            switch action {
            case .startHolding:
                // Long press confirmed — start fast-forward or rewind
                if event.keyCode.isForward {
                    appleMusic.fastForward()
                } else {
                    appleMusic.rewind()
                }
            case .startWaiting, .none:
                break
            case .shortRelease, .holdRelease:
                break // Can't happen on key-down
            }
        }
    }

    private func handleSpotifyPriorityKeyDown(_ event: MediaKeyEvent) {
        switch event.keyCode {
        case .play:
            spotify.playPause()
        case .next, .fast:
            spotify.nextTrack()
        case .previous, .rewind:
            spotify.previousTrack()
        }
    }

    private func handleBothPlayersKeyDown(_ event: MediaKeyEvent) {
        switch event.keyCode {
        case .play:
            if spotify.isRunning { spotify.playPause() }
            if appleMusic.isRunning { appleMusic.playPause() }
        case .next, .fast:
            if spotify.isRunning { spotify.nextTrack() }
            if appleMusic.isRunning { appleMusic.nextTrack() }
        case .previous, .rewind:
            if spotify.isRunning { spotify.previousTrack() }
            if appleMusic.isRunning { appleMusic.backTrack() }
        }
    }

    // MARK: - Key Up

    private func handleKeyUp(_ event: MediaKeyEvent) {
        let action = keyHoldMachine.keyUp()

        switch action {
        case .shortRelease:
            // Only iTunes priority uses the hold state machine
            if preferences.priority == .iTunes {
                if event.keyCode.isForward {
                    appleMusic.nextTrack()
                } else if event.keyCode.isBackward {
                    appleMusic.backTrack()
                }
            }

        case .holdRelease:
            // Stop fast-forwarding/rewinding
            if preferences.priority == .iTunes {
                appleMusic.resume()
            }

        case .startWaiting, .startHolding, .none:
            break
        }
    }
}
