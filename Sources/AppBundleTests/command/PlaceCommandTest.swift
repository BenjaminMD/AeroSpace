@testable import AppBundle
import Common
import XCTest

@MainActor
final class PlaceCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testPlaceTopLeftWithPointsFloatsTheWindow() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        _ = window.focusWindow()
        await parseCommand("place top-left --width 900 --height 640").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertTrue(window.isFloating)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals([rect?.topLeftX, rect?.topLeftY, rect?.width, rect?.height], [0, 0, 900, 640])
    }

    func testPlaceBottomRightWithPercent() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer, rect: Rect(topLeftX: 10, topLeftY: 10, width: 100, height: 100))
        _ = window.focusWindow()
        await parseCommand("place bottom-right --width 50% --height 25%").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals([rect?.topLeftX, rect?.topLeftY, rect?.width, rect?.height], [960, 810, 960, 270]) // Test monitor is 1920x1080
    }

    func testPlaceCenterKeepsSize() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).floatingWindowsContainer, rect: Rect(topLeftX: 10, topLeftY: 10, width: 400, height: 200))
        _ = window.focusWindow()
        await parseCommand("place center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals([rect?.topLeftX, rect?.topLeftY, rect?.width, rect?.height], [760, 440, 400, 200])
    }
}
