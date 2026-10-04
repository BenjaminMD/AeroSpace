import AppKit
import Common

struct StickyCommand: Command {
    let args: StickyCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isSticky
        }
        if newState == window.isSticky {
            return switch args.failIfNoop {
                case true: .fail
                case false: .succ(io.err((newState ? "Already sticky. " : "Already not sticky. ") +
                            "Tip: use --fail-if-noop to exit with non-zero exit code"))
            }
        }
        if newState {
            guard let workspace = window.nodeWorkspace else { return .fail(io.err(windowIsntPartOfTree(window))) }
            if workspace.isScratchpad { return .fail(io.err("Scratchpad windows can't be sticky")) }
            if !window.isFloating { // Sticky windows are floating
                if window.isLocked { return .fail(io.err(windowIsLockedMsg(window))) }
                window.bindAsFloatingWindow(to: workspace)
                if let size = window.lastFloatingSize { window.setAxFrame(nil, size) }
            }
        }
        window.isSticky = newState
        return .succ
    }
}
