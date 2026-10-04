import AppKit
import Common

/// Fork addition. Keep the window tree across AeroSpace restarts.
///
/// After every complete refresh session the tree (workspaces, containers, weights, floating windows, which workspace
/// is visible on which monitor) is written to `layoutFileUrl` if it changed. At startup, once all windows are
/// registered, the saved tree is restored. Window ids are only stable within one boot and can be reused by another
/// process, so a snapshot from a previous boot session is ignored and a window is only restored if its pid matches.
/// Windows that no longer exist are skipped; new windows keep their default placement.
///
/// Nothing is saved or restored while the system is suspended (SystemSuspend): around sleep and lock, windows look
/// closed. If AeroSpace starts while the screen is locked, the restore is retried once the screen is unlocked.
///
/// Upstream's closedWindowsCache.swift solves the same problem in memory for the lock screen. This file uses its own
/// Codable snapshot types so that the upstream ones stay untouched.

private let layoutFileUrl = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/AeroSpace/layout.json")

private struct PersistedLayout: Codable, Equatable {
    /// kern.bootsessionuuid. Unlike "now - uptime", it doesn't drift across sleep
    let bootSession: String
    let workspaces: [PersistedWorkspace]
    let monitors: [PersistedMonitor]
}

private struct PersistedMonitor: Codable, Equatable {
    let topLeftCorner: CGPoint
    let visibleWorkspace: String
    /// Matched first on restore: monitor points shift when the display arrangement changes, names don't
    let name: String?
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
    let pid: Int32? // nil in snapshots written before pids were stored
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
@MainActor private var lastWriteDate = Date.distantPast
@MainActor private var isDelayedWriteScheduled = false
private let minWriteInterval: TimeInterval = 1.5

private let currentBootSession: String = {
    var size = 0
    sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0)
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
}()

// MARK: - Save

@MainActor
func persistLayoutIfChanged() {
    if !isPersistedLayoutRestoreDone || isStartup { return } // Don't overwrite the snapshot before it's restored
    // While the system is suspended, windows look closed. Don't persist that
    if SystemSuspend.isActive || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return }
    if currentlyManipulatedWithMouseWindowId != nil { return } // Weights change continuously. Saved on mouse up
    let sinceLastWrite = Date.now.timeIntervalSince(lastWriteDate)
    if sinceLastWrite < minWriteInterval {
        if !isDelayedWriteScheduled {
            isDelayedWriteScheduled = true
            Task.startUnstructured { @MainActor in
                try? await Task.sleep(for: .seconds(minWriteInterval - sinceLastWrite))
                isDelayedWriteScheduled = false
                persistLayoutIfChanged()
            }
        }
        return
    }
    let layout = PersistedLayout(
        bootSession: currentBootSession,
        workspaces: Workspace.all.map(PersistedWorkspace.init),
        monitors: monitorInfos.map {
            PersistedMonitor(topLeftCorner: $0.rect.topLeftCorner, visibleWorkspace: $0.activeWorkspace.name, name: $0.name)
        },
    )
    if layout == lastPersistedLayout { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(layout) else { return }
    try? FileManager.default.createDirectory(at: layoutFileUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
    lastWriteDate = .now
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
        pid = window.app.pid
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
    if SystemSuspend.isActive { return false } // Windows look closed. Retried by retryPersistedLayoutRestoreIfPending
    defer { isPersistedLayoutRestoreDone = true }
    guard let data = try? Data(contentsOf: layoutFileUrl),
          let layout = try? JSONDecoder().decode(PersistedLayout.self, from: data),
          layout.bootSession == currentBootSession // Window ids are reused after reboot
    else { return false }
    lastPersistedLayout = layout
    return try await restore(layout)
}

/// Called when SystemSuspend ends. Covers AeroSpace being (re)started while the screen was locked
@MainActor
func retryPersistedLayoutRestoreIfPending() async {
    if isPersistedLayoutRestoreDone { return }
    try? await runLightSession(.globalObserver("fork.restorePersistedLayout"), .forceRun) {
        _ = try await restorePersistedLayoutAtStartup()
    }
}

@MainActor
private func restore(_ layout: PersistedLayout) async throws -> Bool {
    let focusedWindowBefore = focus.windowOrNil
    var restoredAnything = false
    for persistedWorkspace in layout.workspaces {
        let workspace = Workspace.get(byName: persistedWorkspace.name)
        for persistedWindow in persistedWorkspace.floatingWindows {
            guard let window = persistedWindow.liveWindow else { continue }
            window.bindAsFloatingWindow(to: workspace)
            if let size = persistedWindow.floatingSize { window.lastFloatingSize = size }
            persistedWindow.applyFlags(to: window)
            if let position = persistedWindow.hiddenProportionalPosition {
                (window as? MacWindow)?.prevUnhiddenProportionalPositionInsideWorkspaceRect = position
            }
            restoredAnything = true
        }
        if !collectWindows(persistedWorkspace.root).contains(where: { $0.liveWindow != nil }) { continue }
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

    let liveMonitors = monitorInfos
    for monitor in layout.monitors where monitor.visibleWorkspace != scratchpadWorkspaceName {
        let byName = monitor.name.flatMap { name in liveMonitors.filter { $0.name == name }.singleOrNil() }
        let byPoint = liveMonitors.filter { $0.rect.topLeftCorner == monitor.topLeftCorner }.singleOrNil()
        _ = (byName ?? byPoint)?.setActiveWorkspace(Workspace.get(byName: monitor.visibleWorkspace))
    }

    // The focus still points to the startup placement. If the focused window was moved to a workspace that isn't
    // visible anymore, the focus would fall back to an invisible workspace and make it visible again
    if let focusedWindowBefore, focusedWindowBefore.nodeWorkspace?.isVisible == true {
        _ = focusedWindowBefore.focusWindow()
    } else {
        let monitor = focusedWindowBefore?.nodeWorkspace?.workspaceMonitor ?? mainMonitorInfo
        _ = monitor.activeWorkspace.focusWorkspace()
    }
    return restoredAnything
}

extension PersistedWindow {
    /// The live window with the same id, if it still belongs to the same process (window ids can be reused)
    @MainActor var liveWindow: Window? {
        Window.get(byId: id)?.takeIf { pid == nil || $0.app.pid == pid }
    }
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
            guard let window = persistedWindow.liveWindow else { return }
            window.bind(to: parent, adaptiveWeight: persistedWindow.weight, index: INDEX_BIND_LAST)
            persistedWindow.applyFlags(to: window)
    }
}

private func collectWindows(_ node: PersistedNode) -> [PersistedWindow] {
    switch node {
        case .container(_, _, _, let children): children.flatMap(collectWindows)
        case .window(let window): [window]
    }
}
