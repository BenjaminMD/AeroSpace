@testable import AppBundle
import Common
import XCTest

@MainActor
final class LoneWindowMaxWidthTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testLoneWindowIsCappedAndCentered() async throws {
        config.loneWindowMaxWidth = 1000
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.width, 1000)
        assertEquals(rect?.topLeftX, 460) // Test monitor is 1920 wide, no gaps
    }

    func testTwoWindowsUseFullWidth() async throws {
        config.loneWindowMaxWidth = 1000
        let workspace = Workspace.get(byName: name)
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let rect = try await first.getAxRect(.nonCancellable)
        assertEquals(rect?.topLeftX, 0)
        assertEquals(rect?.width, 960)
    }
}
