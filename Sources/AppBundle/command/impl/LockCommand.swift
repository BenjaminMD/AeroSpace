import AppKit
import Common

struct LockCommand: Command {
    let args: LockCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isLocked
        }
        if newState == window.isLocked {
            return switch args.failIfNoop {
                case true: .fail
                case false: .succ(io.err((newState ? "Already locked. " : "Already not locked. ") +
                            "Tip: use --fail-if-noop to exit with non-zero exit code"))
            }
        }
        // Floating windows are pinned to their current frame. Tiled windows are pinned by refusing commands
        window.lockedFrame = newState && window.isFloating ? try? await window.getAxRect(.nonCancellable) : nil
        window.isLocked = newState
        return .succ
    }
}
