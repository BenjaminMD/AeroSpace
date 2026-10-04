import AppKit
import Common

struct ScratchpadCommand: Command {
    let args: ScratchpadCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        switch args.action.val {
            case .stash:
                guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
                if window.nodeWorkspace?.isScratchpad == true {
                    return .succ(io.err("Window '\(window.windowId)' is already in the scratchpad"))
                }
                stashToScratchpad(window)
                return .succ
            case .toggle:
                if let it = args.widthPercent { scratchpadRevealFraction.width = CGFloat(it) / 100 }
                if let it = args.heightPercent { scratchpadRevealFraction.height = CGFloat(it) / 100 }
                let workspace = target.workspace.isScratchpad ? target.workspace.workspaceMonitor.activeWorkspace : target.workspace
                guard let next = toggleScratchpad(on: workspace, focused: target.windowOrNil) else { return .succ }
                return .from(bool: next.focusWindow())
        }
    }
}
