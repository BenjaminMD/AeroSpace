@testable import AppBundle
import Common
import XCTest

@MainActor
final class FloatingFullscreenTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testToggleBetweenFullAndOriginalFrame() async throws {
        let workspace = Workspace.get(byName: name)
        let original = Rect(topLeftX: 100, topLeftY: 200, width: 640, height: 480)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: original)
        _ = window.focusWindow()

        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        var rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.width, 1920) // Test monitor, no gaps
        assertEquals(rect?.height, 1080)
        XCTAssertTrue(window.isFloating)

        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.topLeftX, 100)
        assertEquals(rect?.topLeftY, 200)
        assertEquals(rect?.width, 640)
        assertEquals(rect?.height, 480)
    }

    func testMovedWindowIsFilledAgain() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: Rect(topLeftX: 0, topLeftY: 0, width: 300, height: 300))
        _ = window.focusWindow()
        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        window.setAxFrame(CGPoint(x: 50, y: 50), CGSize(width: 500, height: 400)) // The user resized it by hand
        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.width, 1920)
    }
}
