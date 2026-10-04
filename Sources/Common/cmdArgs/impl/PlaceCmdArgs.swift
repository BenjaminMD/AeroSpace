public struct PlaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .place,
        help: place_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
            "--width": singleValueSubArgParser(\.width, "<size>", parsePlaceSize),
            "--height": singleValueSubArgParser(\.height, "<size>", parsePlaceSize),
        ],
        posArgs: [newMandatoryPosArgParser(\.anchor, parsePlaceAnchor, placeholder: PlaceAnchor.unionLiteral)],
    )

    public var anchor: Lateinit<PlaceAnchor> = .uninitialized
    public var width: PlaceSize? = nil
    public var height: PlaceSize? = nil
}

public enum PlaceAnchor: String, CaseIterable, Sendable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case center
}

public enum PlaceSize: Sendable, Equatable {
    case points(Int)
    case percent(Int)
}

func parsePlaceAnchor(i: PosArgParserInput) -> ParsedCliArgs<PlaceAnchor> {
    .init(parseEnum(i.arg, PlaceAnchor.self), advanceBy: 1)
}

/// "900" (points) or "30%" (of the monitor)
private func parsePlaceSize(_ str: String) -> ResOrStr<PlaceSize> {
    if str.hasSuffix("%") { return parsePercent(str).map(PlaceSize.percent) }
    guard let value = Int(str), value > 0 else { return .failure("'\(str)' is neither a size in points nor a percent") }
    return .success(.points(value))
}
