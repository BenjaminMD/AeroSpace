import AppKit
import Common

/// i3-like scratchpad (fork addition). See docs/aerospace-scratchpad.adoc
///
/// Stashed windows are floating windows of the hidden `.scratchpad` workspace. Revealed windows are tracked by id,
/// in reveal order. The list is reconciled lazily: a window drops out once it's closed, stashed again, or released
/// into the tiling tree.

let scratchpadWorkspaceName = ".scratchpad"

@MainActor var revealedScratchpadWindowIds: [UInt32] = []
@MainActor var scratchpadRevealFraction = CGSize(width: 0.62, height: 0.78)

extension Workspace {
    var isScratchpad: Bool { name == scratchpadWorkspaceName }
}

@MainActor
private var stashedScratchpadWindows: [Window] {
    Workspace.get(byName: scratchpadWorkspaceName).allLeafWindowsRecursive
}

@MainActor
private func revealedScratchpadWindows() -> [Window] {
    revealedScratchpadWindowIds = revealedScratchpadWindowIds.filter { id in
        guard let window = Window.get(byId: id) else { return false }
        return window.isFloating && window.nodeWorkspace?.isScratchpad == false
    }
    return revealedScratchpadWindowIds.compactMap { Window.get(byId: $0) }
}

@MainActor
func stashToScratchpad(_ window: Window) {
    window.isSticky = false
    revealedScratchpadWindowIds.removeAll { $0 == window.windowId }
    window.bindAsFloatingWindow(to: Workspace.get(byName: scratchpadWorkspaceName))
}

/// Floats the window centered on the workspace's monitor. Doesn't focus it
@MainActor
func revealFromScratchpad(_ window: Window, on workspace: Workspace) {
    window.bindAsFloatingWindow(to: workspace)
    // Drop the "hidden in corner" state first. Otherwise the next layout pass would restore the window to its
    // pre-stash position. The setAxFrame below supersedes the frame job issued by unhideFromCorner
    (window as? MacWindow)?.unhideFromCorner()
    let rect = workspace.workspaceMonitor.visibleRect
    let size = CGSize(
        width: (rect.width * scratchpadRevealFraction.width).rounded(),
        height: (rect.height * scratchpadRevealFraction.height).rounded(),
    )
    let topLeft = CGPoint(
        x: (rect.topLeftX + (rect.width - size.width) / 2).rounded(),
        y: (rect.topLeftY + (rect.height - size.height) / 2).rounded(),
    )
    window.lastFloatingSize = size
    window.setAxFrame(topLeft, size)
    revealedScratchpadWindowIds.removeAll { $0 == window.windowId }
    revealedScratchpadWindowIds.append(window.windowId)
}

/// i3 `scratchpad show` semantics. Returns the window that should be focused, or nil if everything was sent back
/// - A revealed scratchpad window is focused: send it back. Nothing replaces it
/// - A revealed window exists, but isn't focused: focus it (summon it from another workspace if needed)
/// - Nothing is revealed: reveal the least recently shown stashed window. Sent back windows are appended to the end
///   of the stash, so repeated presses cycle through all of them
@MainActor
func toggleScratchpad(on workspace: Workspace, focused: Window?) -> Window? {
    let revealed = revealedScratchpadWindows()
    if let focused, revealed.contains(focused) {
        if focused.isLocked { return focused } // A locked window stays where it is
        for window in revealed where !window.isLocked {
            stashToScratchpad(window)
        }
        return nil
    }
    if let shown = revealed.first(where: { $0.nodeWorkspace == workspace }) ?? revealed.first {
        if shown.nodeWorkspace != workspace {
            revealFromScratchpad(shown, on: workspace)
        }
        return shown
    }
    guard let next = stashedScratchpadWindows.first else { return nil }
    revealFromScratchpad(next, on: workspace)
    return next
}

/// Called by Window.focusWindow(). A stashed window that gets focused (native focus from a notification click, app
/// launcher or cmd-tab; `focus --window-id`) is revealed on the focused workspace instead of making the hidden
/// scratchpad workspace visible
@MainActor
func pullFromScratchpadIfStashed(_ window: Window) {
    guard window.nodeWorkspace?.isScratchpad == true else { return }
    revealFromScratchpad(window, on: nonScratchpadWorkspace(focus.workspace))
}

/// The scratchpad must never become visible. Falls back to a visible workspace
@MainActor
func nonScratchpadWorkspace(_ workspace: Workspace) -> Workspace {
    if !workspace.isScratchpad { return workspace }
    let active = workspace.workspaceMonitor.activeWorkspace
    if !active.isScratchpad { return active }
    return Workspace.all.first { $0.isVisible && !$0.isScratchpad } ?? mainMonitorInfo.activeWorkspace
}

/// Fork addition. `scratchpad toggle --app-id <id>`: i3 `[app_id=...] scratchpad show` for one app, independent of the
/// stash queue. Returns nil if the app has no window (so that a binding can launch it with `||`)
/// - The app's window is focused: stash it
/// - It's on the focused workspace, but not focused: focus it
/// - Otherwise (stashed, or on another workspace): reveal it on the focused workspace, floating and centered
@MainActor
func toggleAppScratchpad(appId: String, on workspace: Workspace, focused: Window?) -> AppScratchpadResult? {
    let windows = Workspace.all.flatMap { $0.allLeafWindowsRecursive }.filter { $0.app.rawAppBundleId == appId }
    if let focused, windows.contains(focused) {
        if focused.isLocked { return .focus(focused) }
        stashToScratchpad(focused)
        return .stashed
    }
    // Prefer the window that is already here, then the most recently revealed one, then any
    let candidate = windows.first { $0.nodeWorkspace == workspace }
        ?? windows.first { revealedScratchpadWindowIds.contains($0.windowId) }
        ?? windows.first { $0.nodeWorkspace?.isScratchpad == true }
        ?? windows.first
    guard let candidate else { return nil }
    if candidate.nodeWorkspace != workspace && !candidate.isLocked {
        revealFromScratchpad(candidate, on: workspace)
    }
    return .focus(candidate)
}

enum AppScratchpadResult {
    case stashed
    case focus(Window)
}
