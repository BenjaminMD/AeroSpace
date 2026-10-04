import AppKit
import Common

/// Fork addition. See docs/aerospace-place.adoc
struct PlaceCommand: Command {
    let args: PlaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        if window.isLocked { return .fail(io.err(windowIsLockedMsg(window))) }
        guard let workspace = window.nodeWorkspace else { return .fail(io.err(windowIsntPartOfTree(window))) }
        if workspace.isScratchpad { return .fail(io.err("Can't place a window that is in the scratchpad")) }
        if !window.isFloating { window.bindAsFloatingWindow(to: workspace) }

        let bounds = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
        let current = try? await window.getAxRect(.nonCancellable)
        let width = resolve(args.width, of: bounds.width) ?? current?.width ?? window.lastFloatingSize?.width ?? bounds.width / 2
        let height = resolve(args.height, of: bounds.height) ?? current?.height ?? window.lastFloatingSize?.height ?? bounds.height / 2
        let size = CGSize(width: min(width, bounds.width), height: min(height, bounds.height))
        let x: CGFloat = switch args.anchor.val {
            case .topLeft, .bottomLeft: bounds.minX
            case .topRight, .bottomRight: bounds.maxX - size.width
            case .center: bounds.minX + ((bounds.width - size.width) / 2).rounded()
        }
        let y: CGFloat = switch args.anchor.val {
            case .topLeft, .topRight: bounds.minY
            case .bottomLeft, .bottomRight: bounds.maxY - size.height
            case .center: bounds.minY + ((bounds.height - size.height) / 2).rounded()
        }
        window.lastFloatingSize = size
        window.floatingFrameBeforeFullscreen = nil
        window.setAxFrame(CGPoint(x: x, y: y), size)
        return .succ
    }
}

private func resolve(_ size: PlaceSize?, of total: CGFloat) -> CGFloat? {
    switch size {
        case .points(let points): CGFloat(points)
        case .percent(let percent): (total * CGFloat(percent) / 100).rounded()
        case nil: nil
    }
}
