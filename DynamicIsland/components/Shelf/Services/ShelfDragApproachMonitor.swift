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

/// Opens the shelf while a Finder file is still below the screen's top edge.
@MainActor
final class ShelfDragApproachMonitor {
    static let shared = ShelfDragApproachMonitor()

    private let pasteboard = NSPasteboard(name: .drag)
    private let autoCloseToken = UUID()
    private var mouseDownMonitor: Any?
    private var dragTimer: Timer?
    private var initialChangeCount = 0
    private weak var openedIsland: DynamicIslandViewModel?
    private var approachBounds = CGRect.zero

    private init() {}

    func start() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            // AppKit calls event monitor handlers on the main thread.
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
        initialChangeCount = pasteboard.changeCount

        // A native drag session can route dragged/up events away from the source app.
        // Sample the pointer only while the mouse button from this press is held.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { Self.shared.update() }
        }
        dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func update() {
        guard NSEvent.pressedMouseButtons & 1 != 0, canOpenShelf else {
            endTracking()
            return
        }

        let location = NSEvent.mouseLocation
        if let island = openedIsland {
            if !approachBounds.contains(location) {
                releaseIsland()
            } else if island.anyDropZoneTargeting {
                // The normal drop target now owns the open/close behavior.
                island.setAutoCloseSuppression(false, token: autoCloseToken)
            }
            return
        }

        guard let app = AppDelegate.shared,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return }
        let allDisplays = Defaults[.showOnAllDisplays]
        guard let window = allDisplays ? app.windows[screen] : app.window,
              window.screen == screen, window.isVisible, window.alphaValue > 0,
              let island = allDisplays ? app.viewModels[screen] : app.vm,
              island.notchState == .closed else { return }

        let depth: CGFloat = 144
        let width = min(window.frame.width + 160, screen.frame.width)
        let zone = CGRect(
            x: window.frame.midX - width / 2,
            y: screen.frame.maxY - depth,
            width: width,
            height: depth + 1
        )
        guard zone.contains(location),
              pasteboard.changeCount != initialChangeCount,
              pasteboard.availableType(from: [.fileURL]) != nil else { return }

        openedIsland = island
        island.setAutoCloseSuppression(true, token: autoCloseToken)
        DynamicIslandViewCoordinator.shared.currentView = .shelf
        island.open()
        approachBounds = zone.union(window.frame).insetBy(dx: -24, dy: -24)
    }

    private func endTracking() {
        dragTimer?.invalidate()
        dragTimer = nil
        releaseIsland()
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
}
