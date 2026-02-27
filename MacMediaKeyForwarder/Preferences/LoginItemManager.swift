import ServiceManagement

enum LoginItemManager {

    /// Whether the app is currently registered as a login item.
    static var isLoginItem: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggle the login item registration.
    /// Registers the app if not a login item; unregisters if it is.
    static func toggle() {
        do {
            if isLoginItem {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // SMAppService can fail if the user denies the request.
            // The menu will re-check status on next open, so we silently ignore.
        }
    }

    /// Ensure the app is registered as a login item.
    static func ensureRegistered() {
        if !isLoginItem {
            try? SMAppService.mainApp.register()
        }
    }
}
