public struct ScratchpadCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .scratchpad,
        help: scratchpad_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--width": singleValueSubArgParser(\.widthPercent, "<percent>", parsePercent),
            "--height": singleValueSubArgParser(\.heightPercent, "<percent>", parsePercent),
        ],
        posArgs: [newMandatoryPosArgParser(\.action, parseScratchpadAction, placeholder: "(stash|toggle)")],
    )

    public var action: Lateinit<ScratchpadAction> = .uninitialized
    public var widthPercent: Int? = nil
    public var heightPercent: Int? = nil
}

public enum ScratchpadAction: String, CaseIterable, Sendable {
    case stash, toggle
}

func parseScratchpadAction(i: PosArgParserInput) -> ParsedCliArgs<ScratchpadAction> {
    .init(parseEnum(i.arg, ScratchpadAction.self), advanceBy: 1)
}

/// Accepts "62" and "62%"
private func parsePercent(_ str: String) -> ResOrStr<Int> {
    let digits = str.hasSuffix("%") ? String(str.dropLast()) : str
    guard let value = Int(digits), (1 ... 100).contains(value) else { return .failure("'\(str)' is not a percent in 1...100") }
    return .success(value)
}

func parseScratchpadCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ScratchpadCmdArgs> {
    parseSpecificCmdArgs(ScratchpadCmdArgs(rawArgs: args), args)
        .filter("--width and --height are only compatible with 'toggle'") {
            ($0.widthPercent == nil && $0.heightPercent == nil) || $0.action.val == .toggle
        }
        .filter("--window-id is only compatible with 'stash'") {
            $0.windowId == nil || $0.action.val == .stash
        }
}
