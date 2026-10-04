import AppKit
import Common

/// Fork addition. Sticky and locked windows. See docs/aerospace-sticky.adoc and docs/aerospace-lock.adoc
///
/// Sticky: a floating window that follows the visible workspace of its monitor. Before every layout pass it's rebound
/// to that workspace, so it's never hidden in the corner and keeps its frame.
///
/// Locked: commands that move, resize, re-layout, close or stash the window refuse to act on it. A locked floating
/// window is pinned to the frame it had when it was locked: mouse drags and app-initiated resizes snap back.
/// A locked tiled window can't be manipulated directly, but its tile still adapts when its neighbours change.

func windowIsLockedMsg(_ window: Window) -> String {
    "Window '\(window.windowId)' is locked. Unlock it first: aerospace lock off --window-id \(window.windowId)"
}

@MainActor
func moveStickyWindowsToVisibleWorkspaces() {
    for workspace in Workspace.all where !workspace.isVisible && !workspace.isScratchpad {
        for window in workspace.floatingWindows where window.isSticky {
            let target = workspace.workspaceMonitor.activeWorkspace
            let targetMostRecent = target.mostRecentWindowRecursive
            window.bindAsFloatingWindow(to: target)
            targetMostRecent?.markAsMostRecentChild() // bind() marks the sticky window. It mustn't become the focus fallback
            (window as? MacWindow)?.unhideFromCorner()
        }
    }
}

extension Window {
    /// Returns true if the frame had to be restored
    @MainActor
    func snapBackIfLocked(_ actual: Rect?) -> Bool {
        guard isLocked, let lockedFrame, let actual else { return false }
        let drift = abs(actual.topLeftX - lockedFrame.topLeftX) + abs(actual.topLeftY - lockedFrame.topLeftY) +
            abs(actual.width - lockedFrame.width) + abs(actual.height - lockedFrame.height)
        if drift < 2 { return false }
        setAxFrame(lockedFrame.topLeftCorner, CGSize(width: lockedFrame.width, height: lockedFrame.height))
        return true
    }
}
