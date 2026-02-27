import Foundation

// MARK: - Media Key Constants

/// NX_KEYTYPE values from IOKit/hidsystem/ev_keymap.h
enum MediaKeyCode: Int32 {
    case play     = 16  // NX_KEYTYPE_PLAY
    case fast     = 19  // NX_KEYTYPE_FAST
    case rewind   = 20  // NX_KEYTYPE_REWIND
    case next     = 17  // NX_KEYTYPE_NEXT (not used in original, but defined)
    case previous = 18  // NX_KEYTYPE_PREVIOUS (not used in original, but defined)

    /// Whether this key represents a forward-direction action (next/fast-forward).
    var isForward: Bool {
        self == .next || self == .fast
    }

    /// Whether this key represents a backward-direction action (previous/rewind).
    var isBackward: Bool {
        self == .previous || self == .rewind
    }
}

// MARK: - Media Key Event

/// Parsed representation of a system media key event extracted from the CGEvent data.
struct MediaKeyEvent {
    let keyCode: MediaKeyCode
    let isPressed: Bool
}

// MARK: - System Event Constants

/// NSEvent system-defined event subtype for media keys.
let kMediaKeyEventSubtype: Int16 = 8

/// CGEvent type value for NX_SYSDEFINED events.
let NX_SYSDEFINED: Int32 = 14
