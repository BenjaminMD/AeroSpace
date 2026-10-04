@testable import AppBundle
import XCTest

@MainActor
final class FocusAfterWindowRemovalTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    func testPrefersPreviousWindowOnSameWorkspace() {
        let workspace = Workspace.get(byName: "a")
        let previous = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let fallback = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        fallback.markAsMostRecentChild()

        let resolved = resolveFocusAfterWindowRemoval(wasFocused: true, previousWindow: previous, workspace: workspace)

        assertEquals(resolved.windowOrNil, previous)
        assertEquals(resolved.workspace, workspace)
    }

    func testFallsBackWhenPreviousWindowBelongsToAnotherWorkspace() {
        let workspace = Workspace.get(byName: "a")
        let fallback = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let previous = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)

        let resolved = resolveFocusAfterWindowRemoval(wasFocused: true, previousWindow: previous, workspace: workspace)

        assertEquals(resolved.windowOrNil, fallback)
    }

    func testFallsBackWhenPreviousWindowNoLongerExists() {
        let workspace = Workspace.get(byName: "a")
        let fallback = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)

        let resolved = resolveFocusAfterWindowRemoval(wasFocused: true, previousWindow: nil, workspace: workspace)

        assertEquals(resolved.windowOrNil, fallback)
    }

    func testFallsBackWhenRemovedWindowWasNotFocused() {
        let workspace = Workspace.get(byName: "a")
        let previous = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let fallback = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        fallback.markAsMostRecentChild()

        let resolved = resolveFocusAfterWindowRemoval(wasFocused: false, previousWindow: previous, workspace: workspace)

        assertEquals(resolved.windowOrNil, fallback)
    }

    func testPreviousFocusedWindowSurvivesCurrentWindowRemoval() async {
        let workspace = Workspace.get(byName: "a")
        let previous = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let removed = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        _ = previous.focusWindow()
        await checkOnFocusChangedCallbacks_nonCancellable()
        _ = removed.focusWindow()
        await checkOnFocusChangedCallbacks_nonCancellable()
        removed.unbindFromParent()

        assertEquals(previousFocusedWindowOrNil, previous)
    }
}

@MainActor
final class FocusAfterFloatingRemovalTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testClosedFloatingWindowReturnsToVisibleWorkspaceElsewhere() {
        let here = Workspace.get(byName: name)
        let elsewhere = Workspace.get(byName: "b")
        let previous = TestWindow.new(id: 1, parent: elsewhere.rootTilingContainer)
        TestWindow.new(id: 2, parent: here.rootTilingContainer)
        // Only `here` is visible in tests (single test monitor), so `previous` must not be chosen
        let resolved = resolveFocusAfterWindowRemoval(wasFocused: true, previousWindow: previous, workspace: here, removedWasFloating: true)
        assertEquals(resolved.workspace, here)
        // Same workspace: chosen regardless
        let sameWorkspace = TestWindow.new(id: 3, parent: here.rootTilingContainer)
        let resolved2 = resolveFocusAfterWindowRemoval(wasFocused: true, previousWindow: sameWorkspace, workspace: here, removedWasFloating: true)
        assertEquals(resolved2.windowOrNil, sameWorkspace)
    }
}
