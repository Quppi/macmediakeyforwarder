import Foundation

/// Three-state machine for detecting long-press (key hold) on media keys.
///
/// Used only in iTunes-priority mode to distinguish between:
/// - Short press → next/previous track
/// - Long press → fast-forward/rewind (while held), then resume on release
///
/// State transitions:
/// ```
/// Key down (first)  → None     → Waiting
/// Key down (repeat) → Waiting  → Holding  (triggers fast-forward/rewind)
/// Key up            → Waiting  → None     (triggers next/previous track)
/// Key up            → Holding  → None     (triggers resume)
/// ```
enum KeyHoldState {
    case none
    case waiting
    case holding
}

struct KeyHoldStateMachine {

    private(set) var state: KeyHoldState = .none

    enum Action {
        /// Transition to waiting state (first press detected).
        case startWaiting
        /// Long press confirmed — start fast-forward or rewind.
        case startHolding
        /// Short press released — trigger next/previous track.
        case shortRelease
        /// Long press released — trigger resume playback.
        case holdRelease
        /// No action needed.
        case none
    }

    /// Process a key-down event and return the action to perform.
    mutating func keyDown() -> Action {
        switch state {
        case .none:
            state = .waiting
            return .startWaiting
        case .waiting:
            state = .holding
            return .startHolding
        case .holding:
            return .none
        }
    }

    /// Process a key-up event and return the action to perform.
    mutating func keyUp() -> Action {
        defer { state = .none }
        switch state {
        case .none:
            return .none
        case .waiting:
            return .shortRelease
        case .holding:
            return .holdRelease
        }
    }
}
