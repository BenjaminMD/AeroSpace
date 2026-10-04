import AppKit
import Common

/// Fork addition. `fullscreen` on a floating window toggles between filling the monitor (the window stays floating)
/// and the frame it had before. Upstream fills the monitor once and forgets the previous frame.
///
/// The window counts as fullscreen only while it still covers the monitor. If it was moved or resized since, the next
/// toggle fills the monitor again (and remembers the new frame).
@MainActor
func toggleFloatingFullscreen(_ window: Window, _ args: FullscreenCmdArgs, _ io: CmdIo) async -> BinaryExitCode {
    guard let workspace = window.nodeWorkspace else { return .fail(io.err(windowIsntPartOfTree(window))) }
    let monitor = workspace.workspaceMonitor
    let fullRect = args.noOuterGaps ? monitor.visibleRect : monitor.visibleRectPaddedByOuterGaps
    let current = try? await window.getAxRect(.nonCancellable)
    let isFull = window.floatingFrameBeforeFullscreen != nil && current.map { $0.roughlyEquals(fullRect) } == true
    let newState: Bool = switch args.toggle {
        case .on: true
        case .off: false
        case .toggle: !isFull
    }
    if newState == isFull {
        return switch args.failIfNoop {
            case true: .fail
            case false: .succ(io.err((newState ? "Already fullscreen. " : "Already not fullscreen. ") +
                        "Tip: use --fail-if-noop to exit with non-zero code"))
        }
    }
    if newState {
        if let current { window.floatingFrameBeforeFullscreen = current }
        window.setAxFrame(fullRect.topLeftCorner, CGSize(width: fullRect.width, height: fullRect.height))
    } else {
        guard let previous = window.floatingFrameBeforeFullscreen else { return .succ }
        window.floatingFrameBeforeFullscreen = nil
        let size = CGSize(width: previous.width, height: previous.height)
        window.lastFloatingSize = size
        window.setAxFrame(previous.topLeftCorner, size)
    }
    return .succ
}

extension Rect {
    /// Apps round their frames (terminals snap to the character grid), so allow some slack
    fileprivate func roughlyEquals(_ other: Rect) -> Bool {
        let tolerance: CGFloat = 40
        return abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(maxX - other.maxX) <= tolerance && abs(maxY - other.maxY) <= tolerance
    }
}
