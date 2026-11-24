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
import CoreGraphics
import Defaults
import os

/// Extends the existing notch window while the primary button is held near it.
@MainActor
final class ShelfDragApproachMonitor {
    static let shared = ShelfDragApproachMonitor()

    private static let log = os.Logger(subsystem: "com.atoll.DynamicIsland", category: "ShelfDragApproach")
    private let autoCloseToken = UUID()
    private var timer: Timer?
    private var pressLocation: CGPoint?
    private var releasedAt: TimeInterval?
    private weak var window: DynamicIslandWindow?
    private weak var island: DynamicIslandViewModel?
    private var approachZone: CGRect?
    private var openedShelf = false
    private var handedOffToShelf = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        // Finder's native drag loop may not deliver global mouse events to Atoll.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { Self.shared.update() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressLocation = nil
        releasedAt = nil
        resetApproach()
    }

    private var canOpenShelf: Bool {
        Defaults[.dynamicShelf] && !Defaults[.enableMinimalisticUI]
            && !LockScreenManager.shared.isLocked
            && !DynamicIslandViewCoordinator.shared.firstLaunch
    }

    private func update() {
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
            || CGEventSource.buttonState(.combinedSessionState, button: .left)
        if !buttonDown {
            pressLocation = nil
            guard approachZone != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let releasedAt {
                // Keep the target registered until AppKit sends the final drop.
                if now - releasedAt >= 0.18 { resetApproach() }
            } else {
                releasedAt = now
            }
            return
        }
        releasedAt = nil

        let point = NSEvent.mouseLocation
        if pressLocation == nil { pressLocation = point }
        guard canOpenShelf else {
            resetApproach()
            return
        }

        if openedShelf, let island, let window, let approachZone {
            if !window.isVisible || !approachZone.union(window.islandFrame).insetBy(dx: -24, dy: -24).contains(point) {
                resetApproach()
            } else if !handedOffToShelf && island.anyDropZoneTargeting {
                handedOffToShelf = true
                island.setAutoCloseSuppression(false, token: autoCloseToken)
            }
            return
        }

        guard let start = pressLocation,
              hypot(point.x - start.x, point.y - start.y) >= 8,
              let app = AppDelegate.shared,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
        else { return }

        let allDisplays = Defaults[.showOnAllDisplays]
        guard let window = (allDisplays ? app.windows[screen] : app.window) as? DynamicIslandWindow,
              let island = allDisplays ? app.viewModels[screen] : app.vm,
              window.isVisible, window.alphaValue > 0, island.notchState == .closed
        else {
            resetApproach()
            return
        }

        let frame = window.islandFrame
        guard frame.midX >= screen.frame.minX, frame.midX < screen.frame.maxX,
              abs(frame.maxY - screen.frame.maxY) < 32
        else {
            resetApproach()
            return
        }

        let bottom = max(screen.frame.minY, screen.frame.maxY - 190)
        let width = min(max(frame.width, island.closedNotchSize.width) + 160, screen.frame.width)
        let zone = CGRect(x: frame.midX - width / 2, y: bottom,
                          width: width, height: frame.minY - bottom)
        guard zone.height > 0, zone.insetBy(dx: -42, dy: -60).contains(point) else {
            resetApproach()
            return
        }
        if self.window === window, approachZone == zone { return }
        resetApproach()
        self.window = window
        self.island = island
        approachZone = zone
        window.setShelfDropZone(zone)
        Self.log.debug("Armed drop view in the notch window")
    }

    fileprivate func enter(_ window: NSWindow?) -> Bool {
        guard canOpenShelf, let window, self.window === window, let island else { return false }
        if openedShelf { return true }
        guard island.notchState == .closed else { return false }

        openedShelf = true
        island.setAutoCloseSuppression(true, token: autoCloseToken)
        DynamicIslandViewCoordinator.shared.currentView = .shelf
        island.open()
        Self.log.notice("Opened File Shelf after a file entered the expanded drop view")
        return true
    }

    fileprivate func receive(_ urls: [URL], in window: NSWindow?) -> Bool {
        guard !urls.isEmpty, openedShelf, let window, self.window === window, let island else { return false }
        handedOffToShelf = true
        island.setAutoCloseSuppression(false, token: autoCloseToken)
        Task {
            ShelfStateViewModel.shared.add(await ShelfDropService.items(from: urls))
        }
        Self.log.notice("Accepted a file drop from the expanded drop view")
        return true
    }

    private func resetApproach() {
        guard approachZone != nil else { return }
        defer {
            window = nil
            island = nil
            approachZone = nil
            openedShelf = false
            handedOffToShelf = false
        }
        window?.setShelfDropZone(nil)
        guard openedShelf, let island else { return }
        island.setAutoCloseSuppression(false, token: autoCloseToken)
        guard !handedOffToShelf, island.notchState == .open, !island.isAutoCloseSuppressed,
              !island.anyDropZoneTargeting, !island.dropEvent,
              DynamicIslandViewCoordinator.shared.currentView == .shelf else { return }
        island.close()
    }
}

/// A rendered native destination beneath the SwiftUI content of the same window.
final class ShelfApproachDropView: NSView {
    private static let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, Self.filenames])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil,
              sender.draggingPasteboard.availableType(from: [.fileURL, Self.filenames]) != nil,
              ShelfDragApproachMonitor.shared.enter(window) else { return [] }
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return false }
        let pasteboard = sender.draggingPasteboard
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        )
        var urls = objects?.compactMap { $0 as? URL }.filter(\.isFileURL) ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: Self.filenames) as? [String] {
            urls = paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        return ShelfDragApproachMonitor.shared.receive(urls, in: window)
    }
}
