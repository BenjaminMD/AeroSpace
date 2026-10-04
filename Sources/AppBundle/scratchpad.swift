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
        for window in revealed {
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

/// Hook for native focus changes. A stashed window focused from outside of AeroSpace (notification click, app
/// launcher, cmd-tab) is pulled onto the focused workspace instead of letting the focus switch to the hidden workspace
@MainActor
func pullScratchpadWindowIfNativelyFocused(_ nativeFocused: Window) {
    guard nativeFocused.nodeWorkspace?.isScratchpad == true else { return }
    let target = focus.workspace.isScratchpad ? focus.workspace.workspaceMonitor.activeWorkspace : focus.workspace
    revealFromScratchpad(nativeFocused, on: target)
}
