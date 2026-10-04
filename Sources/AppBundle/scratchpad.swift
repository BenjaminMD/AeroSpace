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

/// Returns the window that should be focused, or nil if everything was sent back
@MainActor
func toggleScratchpad(on workspace: Workspace, focused: Window?) -> Window? {
    let revealed = revealedScratchpadWindows()
    let stashed = stashedScratchpadWindows
    let isFocusedRevealed = focused.map { revealed.contains($0) } ?? false
    // Only one scratchpad window is visible at a time: send back everything that's out
    for window in revealed {
        stashToScratchpad(window)
    }
    if isFocusedRevealed && revealed.count + stashed.count <= 1 {
        return nil // back and forth
    }
    // Stash order, then the windows that were just sent back. If the focused window was revealed, advance past it.
    // A revealed but unfocused window (e.g. left on another workspace) is summoned again
    let candidates = (stashed + revealed).filter { !isFocusedRevealed || $0 != focused }
    guard let next = candidates.first else { return nil }
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
