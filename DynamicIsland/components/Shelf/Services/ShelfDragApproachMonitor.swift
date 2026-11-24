/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults

/// Registers a native drop destination below the notch for external file drags.
@MainActor
final class ShelfDragApproachMonitor {
    static let shared = ShelfDragApproachMonitor()

    private let autoCloseToken = UUID()
    private var mouseDownMonitor: Any?
    private var dragTimer: Timer?
    private var pressLocation = CGPoint.zero
    private var releasedAt: TimeInterval?
    private var panelArmed = false
    private weak var armedWindow: NSWindow?
    private weak var armedIsland: DynamicIslandViewModel?
    private weak var openedIsland: DynamicIslandViewModel?
    private var approachBounds = CGRect.zero

    private lazy var dropPanel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        // A nearly transparent surface remains hittable by WindowServer for native drags.
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.01)
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = ApproachDropView()
        return panel
    }()

    private init() {}

    func start() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            MainActor.assumeIsolated { Self.shared.beginTracking() }
        }
    }

    func stop() {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        endTracking()
    }

    private var canOpenShelf: Bool {
        Defaults[.dynamicShelf] && !Defaults[.enableMinimalisticUI]
            && !LockScreenManager.shared.isLocked
            && !DynamicIslandViewCoordinator.shared.firstLaunch
    }

    private func beginTracking() {
        endTracking()
        guard canOpenShelf else { return }
        pressLocation = NSEvent.mouseLocation
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { Self.shared.update() }
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func update() {
        guard canOpenShelf else { endTracking(); return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            // AppKit may deliver the drop just after the physical button goes up.
            let now = ProcessInfo.processInfo.systemUptime
            if let releasedAt {
                if now - releasedAt >= 0.12 { endTracking() }
            } else {
                releasedAt = now
            }
            return
        }

        let location = NSEvent.mouseLocation
        if let island = openedIsland {
            if !approachBounds.contains(location) {
                disarm()
                releaseIsland()
            } else if island.anyDropZoneTargeting {
                island.setAutoCloseSuppression(false, token: autoCloseToken)
            }
            return
        }

        guard hypot(location.x - pressLocation.x, location.y - pressLocation.y) >= 8,
              let app = AppDelegate.shared,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            disarm()
            return
        }
        let allDisplays = Defaults[.showOnAllDisplays]
        guard let window = allDisplays ? app.windows[screen] : app.window,
              window.screen == screen, window.isVisible, window.alphaValue > 0,
              let island = allDisplays ? app.viewModels[screen] : app.vm,
              island.notchState == .closed else {
            disarm()
            return
        }

        let depth: CGFloat = 156
        let width = min(max(window.frame.width, island.closedNotchSize.width) + 144, screen.frame.width)
        let zone = CGRect(x: window.frame.midX - width / 2, y: screen.frame.maxY - depth, width: width, height: depth)
        // Arm before entry, so the native drag finds the destination on the way up.
        guard zone.insetBy(dx: -40, dy: -54).contains(location) else { disarm(); return }
        guard armedWindow !== window || dropPanel.frame != zone else { return }

        panelArmed = true
        armedWindow = window
        armedIsland = island
        dropPanel.setFrame(zone, display: true)
        dropPanel.level = window.level
        dropPanel.order(.below, relativeTo: window.windowNumber)
    }

    private func openShelf() -> Bool {
        guard canOpenShelf, let island = armedIsland, let window = armedWindow else { return false }
        if openedIsland === island { return true }
        guard island.notchState == .closed else { return false }

        openedIsland = island
        island.setAutoCloseSuppression(true, token: autoCloseToken)
        DynamicIslandViewCoordinator.shared.currentView = .shelf
        island.open()
        approachBounds = dropPanel.frame.union(window.frame).insetBy(dx: -24, dy: -24)
        return true
    }

    private func endTracking() {
        dragTimer?.invalidate()
        dragTimer = nil
        releasedAt = nil
        disarm()
        releaseIsland()
    }

    private func disarm() {
        guard panelArmed else { return }
        panelArmed = false
        dropPanel.orderOut(nil)
        armedWindow = nil
        armedIsland = nil
    }

    private func releaseIsland() {
        guard let island = openedIsland else { return }
        openedIsland = nil
        island.setAutoCloseSuppression(false, token: autoCloseToken)
        guard island.notchState == .open, !island.isAutoCloseSuppressed,
              !island.anyDropZoneTargeting, !island.dropEvent,
              DynamicIslandViewCoordinator.shared.currentView == .shelf else { return }
        island.close()
    }

    private final class ApproachDropView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingSource == nil,
                  sender.draggingSourceOperationMask.contains(.copy),
                  sender.draggingPasteboard.availableType(from: [.fileURL]) != nil,
                  ShelfDragApproachMonitor.shared.openShelf() else { return [] }
            return .copy
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let objects = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            )
            let urls = objects?.compactMap { $0 as? URL } ?? []
            let monitor = ShelfDragApproachMonitor.shared
            guard !urls.isEmpty, let island = monitor.openedIsland else { return false }

            monitor.openedIsland = nil
            island.setAutoCloseSuppression(false, token: monitor.autoCloseToken)
            Task {
                ShelfStateViewModel.shared.add(await ShelfDropService.items(from: urls))
            }
            return true
        }
    }
}
