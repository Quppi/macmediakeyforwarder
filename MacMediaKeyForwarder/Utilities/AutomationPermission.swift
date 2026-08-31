import Cocoa
import ApplicationServices
import os.log

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

/// Caches Automation permission status per target app and refreshes it on
/// background threads.
///
/// `AEDeterminePermissionToAutomateTarget` performs synchronous IPC to the
/// Apple Events daemon and the target app and can block indefinitely (seen on
/// macOS Tahoe when TCC state is stale after a reboot). It must therefore
/// never run on the main thread — callers read the cached status instantly
/// and receive refreshed values asynchronously.
final class AutomationPermissionMonitor {

    static let shared = AutomationPermissionMonitor()

    private static let log = Logger(
        subsystem: "eu.meyer.mmkf", category: "AutomationPermission"
    )

    /// How long to wait for a check before reporting the last known status.
    private let checkTimeout: TimeInterval = 2.0

    private let lock = NSLock()
    private var cache: [String: AutomationPermissionStatus] = [:]
    private var inFlight: Set<String> = []
    private var pendingCompletions: [String: [(AutomationPermissionStatus) -> Void]] = [:]
    private var observedBundleIDs: Set<String> = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(targetAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(targetAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
    }

    // MARK: - Reading (non-blocking, safe on the main thread)

    /// Last known status for the given app. Never blocks.
    func cachedStatus(for bundleID: String) -> AutomationPermissionStatus {
        lock.lock()
        defer { lock.unlock() }
        return cache[bundleID] ?? .notDetermined
    }

    /// Returns `true` unless permission is known to be explicitly denied.
    /// Never blocks; also kicks off a background refresh so the cache stays
    /// current for subsequent calls.
    func canAutomate(bundleID: String) -> Bool {
        let status = cachedStatus(for: bundleID)
        refresh(bundleID: bundleID)
        return status != .denied
    }

    // MARK: - Refreshing (background)

    /// Refreshes the status for the given app off the main thread. The
    /// optional completion is delivered on the main queue. If a check is
    /// already running for this app, the completion is attached to it instead
    /// of starting another one. If the check exceeds `checkTimeout`, the
    /// completion receives the last known status.
    func refresh(bundleID: String, completion: ((AutomationPermissionStatus) -> Void)? = nil) {
        lock.lock()
        observedBundleIDs.insert(bundleID)
        if let completion {
            pendingCompletions[bundleID, default: []].append(completion)
        }
        guard !inFlight.contains(bundleID) else {
            lock.unlock()
            return
        }
        inFlight.insert(bundleID)
        lock.unlock()

        // Fast path: no IPC needed when the target isn't running.
        guard Self.isRunning(bundleID: bundleID) else {
            finish(bundleID: bundleID, status: .appNotRunning)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = Self.determinePermission(bundleID: bundleID) // may block
            self?.finish(bundleID: bundleID, status: status)
        }

        // Watchdog: if the check hangs, flush waiting completions with the
        // last known status. `inFlight` stays set so we never stack up more
        // stuck threads for the same target; the cache updates whenever the
        // stuck call eventually returns.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + checkTimeout) { [weak self] in
            self?.flushAfterTimeout(bundleID: bundleID)
        }
    }

    private func finish(bundleID: String, status: AutomationPermissionStatus) {
        lock.lock()
        inFlight.remove(bundleID)
        let previous = cache[bundleID]
        cache[bundleID] = status
        let completions = pendingCompletions.removeValue(forKey: bundleID) ?? []
        lock.unlock()

        if previous != status {
            Self.log.notice("Automation permission for \(bundleID, privacy: .public): \(String(describing: status), privacy: .public)")
        }
        if !completions.isEmpty {
            DispatchQueue.main.async {
                completions.forEach { $0(status) }
            }
        }
    }

    private func flushAfterTimeout(bundleID: String) {
        lock.lock()
        guard inFlight.contains(bundleID) else {
            lock.unlock()
            return
        }
        let status = cache[bundleID] ?? .notDetermined
        let completions = pendingCompletions.removeValue(forKey: bundleID) ?? []
        lock.unlock()

        Self.log.warning("Automation permission check for \(bundleID, privacy: .public) timed out — reporting last known status")
        if !completions.isEmpty {
            DispatchQueue.main.async {
                completions.forEach { $0(status) }
            }
        }
    }

    // MARK: - Target app lifecycle

    @objc private func targetAppLaunched(_ note: Notification) {
        guard let bundleID = Self.bundleID(from: note), isObserved(bundleID) else { return }
        // Give the app a moment to register with the Apple Events daemon.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh(bundleID: bundleID)
        }
    }

    @objc private func targetAppTerminated(_ note: Notification) {
        guard let bundleID = Self.bundleID(from: note), isObserved(bundleID) else { return }
        refresh(bundleID: bundleID)
    }

    private func isObserved(_ bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedBundleIDs.contains(bundleID)
    }

    private static func bundleID(from note: Notification) -> String? {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier
    }

    private static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID
        }
    }

    // MARK: - The blocking check (background threads only)

    private static func determinePermission(bundleID: String) -> AutomationPermissionStatus {
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
}
