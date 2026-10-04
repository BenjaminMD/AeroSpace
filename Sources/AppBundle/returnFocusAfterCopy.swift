import AppKit
import Common

/// Fork addition. `return-focus-after-copy-from = ['com.apple.Passwords']`
///
/// Password managers hold Secure Input while they are frontmost. Secure Input blocks all hotkeys, AeroSpace's
/// included, so after copying a password the user is stuck until they click somewhere. While one of the configured
/// apps is frontmost, the clipboard is polled; on change, the previously focused window is focused again, which
/// releases Secure Input.
@MainActor
enum ReturnFocusAfterCopy {
    private static var pollTask: Task<(), any Error>? = nil

    static func initObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main,
        ) { notification in
            let bundleId = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task.startUnstructured { @MainActor in onAppActivated(bundleId) }
        }
    }

    private static func onAppActivated(_ bundleId: String?) {
        pollTask?.cancel()
        pollTask = nil
        guard let bundleId, config.returnFocusAfterCopyFrom.contains(bundleId) else { return }
        let initialChangeCount = NSPasteboard.general.changeCount
        pollTask = Task.startUnstructured { @MainActor in
            while NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
                try await Task.sleep(for: .milliseconds(250))
                if NSPasteboard.general.changeCount != initialChangeCount {
                    try await returnFocus()
                    return
                }
            }
        }
    }

    private static func returnFocus() async throws {
        guard let token: RunSessionGuard = .isServerEnabled, let previous = prevFocus else { return }
        try await runLightSession(.globalObserver("fork.returnFocusAfterCopy"), token) {
            if let window = previous.windowOrNil {
                _ = window.focusWindow()
                window.nativeFocus() // The light session only syncs if AeroSpace's focus changed. Force it
            } else {
                _ = previous.workspace.focusWorkspace()
            }
        }
    }
}
