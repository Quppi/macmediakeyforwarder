import ApplicationServices

/// Result of checking Automation permission for a target app.
enum AutomationPermissionStatus {
    /// Permission is granted.
    case allowed
    /// Permission was explicitly denied by the user.
    case denied
    /// The target app is not running, so permission cannot be checked.
    case appNotRunning
    /// The user has never been prompted — permission is undetermined.
    case notDetermined
}

/// Checks whether the app has Automation permission to send Apple Events
/// to the given target application, without triggering a user prompt.
func automationPermission(for bundleID: String) -> AutomationPermissionStatus {
    guard let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc?.pointee else {
        return .denied
    }

    var targetAddress = descriptor
    let status = AEDeterminePermissionToAutomateTarget(
        &targetAddress, typeWildCard, typeWildCard, false
    )

    switch status {
    case noErr:
        return .allowed
    case OSStatus(procNotFound):
        return .appNotRunning
    case -1744: // errAEEventWouldRequireUserConsent
        return .notDetermined
    default: // errAEEventNotPermitted (-1743) and others
        return .denied
    }
}

/// Convenience: returns `true` when automation is allowed or when we can't
/// determine the status (app not running / not yet prompted).
/// Only returns `false` when permission is explicitly denied.
func canAutomateApp(bundleID: String) -> Bool {
    automationPermission(for: bundleID) != .denied
}
