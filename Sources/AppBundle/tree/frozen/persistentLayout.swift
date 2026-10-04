import AppKit
import Common

/// Fork addition. Keep the window tree across AeroSpace restarts.
///
/// After every complete refresh session the tree (workspaces, containers, weights, floating windows, which workspace
/// is visible on which monitor) is written to `layoutFileUrl` if it changed. At startup, once all windows are
/// registered, the saved tree is restored. Window ids are only stable within one boot, so a snapshot from a previous
/// boot is ignored. Windows that no longer exist are skipped; new windows keep their default placement.
///
/// Upstream's closedWindowsCache.swift solves the same problem in memory for the lock screen. This file uses its own
/// Codable snapshot types so that the upstream ones stay untouched.

private let layoutFileUrl = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/AeroSpace/layout.json")

private struct PersistedLayout: Codable, Equatable {
    /// Seconds since 1970, rounded. Identifies the boot session
    let bootTime: Int
    let workspaces: [PersistedWorkspace]
    let monitors: [PersistedMonitor]
}

private struct PersistedMonitor: Codable, Equatable {
    let topLeftCorner: CGPoint
    let visibleWorkspace: String
}

private struct PersistedWorkspace: Codable, Equatable {
    let name: String
    let root: PersistedNode
    let floatingWindows: [PersistedWindow]
}

private indirect enum PersistedNode: Codable, Equatable {
    case container(layout: String, orientation: String, weight: CGFloat, children: [PersistedNode])
    case window(PersistedWindow)
}

private struct PersistedWindow: Codable, Equatable {
    let id: UInt32
    let weight: CGFloat
    /// Position of a floating window hidden in the corner, relative to its monitor. Without it, the window would be
    /// stuck in the corner after the restart
    let hiddenProportionalPosition: CGPoint?
    let floatingSize: CGSize?
    let isSticky: Bool?
    let isLocked: Bool?
    let lockedFrame: CGRect?
}

@MainActor private var lastPersistedLayout: PersistedLayout? = nil
@MainActor private var isPersistedLayoutRestoreDone = false

private var currentBootTime: Int {
    Int((Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime).rounded())
}

// MARK: - Save

@MainActor
func persistLayoutIfChanged() {
    if !isPersistedLayoutRestoreDone || isStartup { return } // Don't overwrite the snapshot before it's restored
    // While the screen is locked, all windows look closed. Don't persist that
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return }
    let layout = PersistedLayout(
        bootTime: currentBootTime,
        workspaces: Workspace.all.map(PersistedWorkspace.init),
        monitors: monitorInfos.map { PersistedMonitor(topLeftCorner: $0.rect.topLeftCorner, visibleWorkspace: $0.activeWorkspace.name) },
    )
    if layout == lastPersistedLayout { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(layout) else { return }
    try? FileManager.default.createDirectory(at: layoutFileUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? data.write(to: layoutFileUrl, options: .atomic)) != nil {
        lastPersistedLayout = layout
    }
}

extension PersistedWorkspace {
    @MainActor init(_ workspace: Workspace) {
        name = workspace.name
        root = PersistedNode(workspace.rootTilingContainer)
        floatingWindows = workspace.floatingWindows.map(PersistedWindow.init)
    }
}

extension PersistedNode {
    @MainActor init(_ container: TilingContainer) {
        self = .container(
            layout: container.layout.rawValue,
            orientation: container.orientation == .h ? "h" : "v",
            weight: getWeightOrNil(container) ?? 1,
            children: container.children.compactMap {
                switch $0.nodeCases {
                    case .window(let window): .window(PersistedWindow(window))
                    case .tilingContainer(let container): PersistedNode(container)
                    default: nil
                }
            },
        )
    }
}

extension PersistedWindow {
    @MainActor init(_ window: Window) {
        id = window.windowId
        weight = getWeightOrNil(window) ?? 1
        hiddenProportionalPosition = (window as? MacWindow)?.prevUnhiddenProportionalPositionInsideWorkspaceRect
        floatingSize = window.isFloating ? window.lastFloatingSize : nil
        isSticky = window.isSticky ? true : nil
        isLocked = window.isLocked ? true : nil
        lockedFrame = window.lockedFrame.map { CGRect(x: $0.topLeftX, y: $0.topLeftY, width: $0.width, height: $0.height) }
    }

    @MainActor func applyFlags(to window: Window) {
        window.isSticky = isSticky == true
        window.isLocked = isLocked == true
        window.lockedFrame = lockedFrame.map { Rect(topLeftX: $0.minX, topLeftY: $0.minY, width: $0.width, height: $0.height) }
    }
}

@MainActor private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.orientation).map { node.getWeight($0) }
}

// MARK: - Restore

/// Call once at startup, after all windows are registered. Returns true if a snapshot was restored
@MainActor
func restorePersistedLayoutAtStartup() async throws -> Bool {
    defer { isPersistedLayoutRestoreDone = true }
    guard let data = try? Data(contentsOf: layoutFileUrl),
          let layout = try? JSONDecoder().decode(PersistedLayout.self, from: data),
          abs(layout.bootTime - currentBootTime) <= 5 // Window ids are reused after reboot
    else { return false }
    lastPersistedLayout = layout

    var restoredAnything = false
    for persistedWorkspace in layout.workspaces {
        let workspace = Workspace.get(byName: persistedWorkspace.name)
        for persistedWindow in persistedWorkspace.floatingWindows {
            guard let window = Window.get(byId: persistedWindow.id) else { continue }
            window.bindAsFloatingWindow(to: workspace)
            if let size = persistedWindow.floatingSize { window.lastFloatingSize = size }
            persistedWindow.applyFlags(to: window)
            if let position = persistedWindow.hiddenProportionalPosition {
                (window as? MacWindow)?.prevUnhiddenProportionalPositionInsideWorkspaceRect = position
            }
            restoredAnything = true
        }
        let tilingIds = collectWindowIds(persistedWorkspace.root)
        if !tilingIds.contains(where: { Window.get(byId: $0) != nil }) { continue }
        let prevRoot = workspace.rootTilingContainer // Keep a reference so that it isn't garbage collected too early
        let potentialOrphans = prevRoot.allLeafWindowsRecursive
        prevRoot.unbindFromParent()
        restoreNode(persistedWorkspace.root, parent: workspace)
        for window in potentialOrphans where !workspace.rootTilingContainer.allLeafWindowsRecursive.contains(window) {
            if window.parent == nil || window.nodeWorkspace == nil {
                try await window.relayoutWindow(on: workspace, .cancellable, forceTile: true)
            }
        }
        restoredAnything = true
    }

    let topLeftCornerToMonitor = monitorInfos.grouped { $0.rect.topLeftCorner }
    for monitor in layout.monitors where monitor.visibleWorkspace != scratchpadWorkspaceName {
        _ = topLeftCornerToMonitor[monitor.topLeftCorner]?
            .singleOrNil()?
            .setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }
    return restoredAnything
}

@MainActor
private func restoreNode(_ node: PersistedNode, parent: NonLeafTreeNodeObject) {
    switch node {
        case .container(let layout, let orientation, let weight, let children):
            let container = TilingContainer(
                parent: parent,
                adaptiveWeight: weight,
                orientation == "h" ? .h : .v,
                Layout(rawValue: layout) ?? .tiles,
                index: INDEX_BIND_LAST,
            )
            for child in children {
                restoreNode(child, parent: container) // Missing windows are skipped, the rest keeps its order
            }
        case .window(let persistedWindow):
            guard let window = Window.get(byId: persistedWindow.id) else { return }
            window.bind(to: parent, adaptiveWeight: persistedWindow.weight, index: INDEX_BIND_LAST)
            persistedWindow.applyFlags(to: window)
    }
}

private func collectWindowIds(_ node: PersistedNode) -> [UInt32] {
    switch node {
        case .container(_, _, _, let children): children.flatMap(collectWindowIds)
        case .window(let window): [window.id]
    }
}
