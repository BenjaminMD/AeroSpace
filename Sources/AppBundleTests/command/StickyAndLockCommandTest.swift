@testable import AppBundle
import Common
import XCTest

@MainActor
final class StickyAndLockCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        XCTAssertNotNil(parseCommand("sticky").cmdOrNil)
        XCTAssertNotNil(parseCommand("lock on --fail-if-noop").cmdOrNil)
        assertEquals(parseCommand("lock --fail-if-noop").errorOrNil, "--fail-if-noop requires 'on' or 'off' argument")
    }

    func testStickyFloatsAndFollowsVisibleWorkspace() async {
        let a = Workspace.get(byName: "a")
        a.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
        }
        await parseCommand("sticky on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let window = Window.get(byId: 1)!
        XCTAssertTrue(window.isSticky)
        XCTAssertTrue(window.isFloating)

        Workspace.get(byName: "b").rootTilingContainer.apply { TestWindow.new(id: 2, parent: $0) }
        await parseCommand("workspace b").cmdOrDie.run(.defaultEnv, .emptyStdin)
        moveStickyWindowsToVisibleWorkspaces()
        assertEquals(window.nodeWorkspace?.name, "b")
    }

    func testLockedWindowRefusesCommands() async {
        Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            _ = TestWindow.new(id: 2, parent: $0).focusWindow()
        }
        await parseCommand("lock on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        XCTAssertTrue(Window.get(byId: 2)!.isLocked)

        for command in ["move left", "move-node-to-workspace x", "layout floating", "close", "scratchpad stash", "resize width +10", "join-with left"] {
            let result = await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
            XCTAssertNotEqual(result.exitCode.rawValue, 0, command)
        }
        assertEquals(Window.get(byId: 2)?.nodeWorkspace?.name, name)
        XCTAssertFalse(Window.get(byId: 2)!.isFloating)

        await parseCommand("lock off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let result = await parseCommand("move-node-to-workspace x").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
    }

    func testCloseAllButCurrentSkipsLocked() async {
        Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            _ = TestWindow.new(id: 3, parent: $0).focusWindow()
        }
        Window.get(byId: 1)!.isLocked = true
        await parseCommand("close-all-windows-but-current").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(Workspace.get(byName: name).allLeafWindowsRecursive.map(\.windowId).sorted(), [1, 3])
    }
}
