@testable import AppBundle
import Common
import XCTest

/// A MonitorInfo captured before a display reconfiguration: its top-left corner no longer matches any live monitor
private struct StaleMonitorInfo: MonitorInfo {
    let monitorAppKitNsScreenScreensId = 2
    let name = "Stale Monitor"
    let rect = Rect(topLeftX: 882, topLeftY: 1440, width: 1512, height: 982)
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let isMain = false
}

@MainActor
final class StaleMonitorInfoTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testActiveWorkspaceOfStaleMonitorDoesNotRecurse() {
        let live = mainMonitorInfo.activeWorkspace
        assertEquals(StaleMonitorInfo().activeWorkspace, live)
        assertEquals(Workspace.all.filter(\.isVisible), [live]) // The stale point is not registered
        assertEquals(mainMonitorInfo.activeWorkspace, live)
    }
}
