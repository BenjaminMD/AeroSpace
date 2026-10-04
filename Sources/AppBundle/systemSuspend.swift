import AppKit
import Common

/// Fork addition. Is the system sleeping, locked, or showing no screens (plus a short grace period afterwards)?
///
/// Around sleep, lock and display sleep the Accessibility API and the window server temporarily report windows as
/// missing. Window garbage collection and layout persistence must not trust that state:
/// - refresh() treats the system like the lock screen (closed windows aren't collected; see closedWindowsCache.swift)
/// - ghost window collection is skipped (MacApp.swift)
/// - the persisted layout isn't overwritten (persistentLayout.swift)
/// When the gate opens, one complete refresh session runs, and a pending startup layout restore is retried.
@MainActor
enum SystemSuspend {
    private static var reasons: [String: Date] = [:]
    private static var resumedAt = Date.distantPast
    private static let gracePeriod: TimeInterval = 3
    /// A stuck reason (missed "end" notification) must not disable garbage collection forever
    private static let maxReasonAge: TimeInterval = 120

    static var isActive: Bool {
        let now = Date.now
        reasons = reasons.filter { now.timeIntervalSince($0.value) < maxReasonAge }
        return !reasons.isEmpty || isScreenLocked || now.timeIntervalSince(resumedAt) < gracePeriod
    }

    /// Undocumented session keys. A nil dictionary is treated as unlocked
    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool == true || dict[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    static func initObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, reason: "sleep")
        observe(workspace, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, reason: "screens")
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, reason: "session")
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, .init("com.apple.screenIsLocked"), .init("com.apple.screenIsUnlocked"), reason: "lock")
    }

    private static func observe(_ center: NotificationCenter, _ begin: Notification.Name, _ end: Notification.Name, reason: String) {
        center.addObserver(forName: begin, object: nil, queue: .main) { _ in
            Task.startUnstructured { @MainActor in reasons[reason] = .now }
        }
        center.addObserver(forName: end, object: nil, queue: .main) { _ in
            Task.startUnstructured { @MainActor in
                reasons[reason] = nil
                resumedAt = .now
                try? await Task.sleep(for: .seconds(gracePeriod + 0.1))
                if isActive || !TrayMenuModel.shared.isEnabled { return }
                await retryPersistedLayoutRestoreIfPending()
                scheduleCancellableCompleteRefreshSession(.globalObserver("fork.systemResumed"))
            }
        }
    }
}
