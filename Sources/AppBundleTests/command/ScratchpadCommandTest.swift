@testable import AppBundle
import Common
import XCTest

@MainActor
final class ScratchpadCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        assertEquals(parseCommand("scratchpad").errorOrNil, "ERROR: Argument '(stash|toggle)' is mandatory")
        assertEquals(parseCommand("scratchpad stash --width 50").errorOrNil, "--width and --height are only compatible with 'toggle'")
        assertEquals(parseCommand("scratchpad toggle --window-id 1").errorOrNil, "--window-id is only compatible with 'stash'")
        XCTAssertNotNil(parseCommand("scratchpad toggle --width 50% --height 80").cmdOrNil)
        XCTAssertNotNil(parseCommand("scratchpad toggle --width 0").errorOrNil)
    }

    func testStashAndToggleBackAndForth() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            _ = TestWindow.new(id: 2, parent: $0).focusWindow()
        }

        await parseCommand("scratchpad stash").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(scratchpadWindowIds(), [2])
        assertEquals(focus.workspace, workspace)

        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(scratchpadWindowIds(), [])
        assertEquals(focus.windowOrNil?.windowId, 2)
        XCTAssertTrue(focus.windowOrNil?.isFloating == true)
        assertEquals(focus.windowOrNil?.nodeWorkspace, workspace)

        // The only scratchpad window is focused -> send it back
        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(scratchpadWindowIds(), [2])
        assertEquals(focus.workspace, workspace)
    }

    func testToggleCyclesThroughStashedWindows() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        await parseCommand("scratchpad stash --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("scratchpad stash --window-id 3").cmdOrDie.run(.defaultEnv, .emptyStdin)
        _ = Window.get(byId: 1)!.focusWindow()

        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 2)
        assertEquals(scratchpadWindowIds(), [3])

        // i3: the focused scratchpad window is hidden, nothing replaces it
        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(scratchpadWindowIds(), [3, 2])
        assertEquals(focus.windowOrNil?.windowId, 1)

        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 3)
        assertEquals(scratchpadWindowIds(), [2])

        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(scratchpadWindowIds(), [2, 3])

        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 2)
    }

    func testToggleFocusesRevealedButUnfocusedWindow() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        await parseCommand("scratchpad stash --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("scratchpad stash --window-id 3").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 2)
        _ = Window.get(byId: 1)!.focusWindow()

        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.windowOrNil?.windowId, 2)
        assertEquals(scratchpadWindowIds(), [3])
    }

    func testScratchpadIsNotListed() async {
        Workspace.get(byName: name).rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
            TestWindow.new(id: 2, parent: $0)
        }
        await parseCommand("scratchpad stash --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let result = await parseCommand("list-workspaces --all").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertFalse(result.stdout.joined(separator: "\n").contains(scratchpadWorkspaceName))
    }

    func testRevealedWindowReleasedIntoTilingIsForgotten() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            _ = TestWindow.new(id: 2, parent: $0).focusWindow()
        }
        await parseCommand("scratchpad stash").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        _ = Window.get(byId: 1)!.focusWindow()

        await parseCommand("scratchpad toggle").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(scratchpadWindowIds(), [])
        assertEquals(focus.windowOrNil?.windowId, 1)
        XCTAssertTrue(Window.get(byId: 2)?.isFloating == false)
    }

    func testNextPrevSkipsScratchpad() async {
        Workspace.get(byName: "a").rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
            TestWindow.new(id: 2, parent: $0)
        }
        await parseCommand("scratchpad stash --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        Workspace.get(byName: "b").rootTilingContainer.apply { TestWindow.new(id: 3, parent: $0) }

        await parseCommand("workspace next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, "b")
        await parseCommand("workspace next --wrap-around").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(focus.workspace.name, "a")
    }
}

@MainActor
private func scratchpadWindowIds() -> [UInt32] {
    Workspace.get(byName: scratchpadWorkspaceName).allLeafWindowsRecursive.map(\.windowId)
}
