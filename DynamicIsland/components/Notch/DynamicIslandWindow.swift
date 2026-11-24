/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import Cocoa

class DynamicIslandWindow: NSPanel {
    private var islandContent: IslandWindowContent?
    private var nominalFrame: CGRect?
    private var dropZone: CGRect?

    var islandFrame: CGRect { nominalFrame ?? frame }

    func installIslandContent(_ hostingView: NSView) {
        let content = IslandWindowContent(hostingView: hostingView)
        islandContent = content
        nominalFrame = frame
        contentView = content
        updateContentFrames(display: false)
    }

    func setIslandFrame(_ frame: CGRect, display: Bool) {
        nominalFrame = frame
        updateContentFrames(display: display)
    }

    func setShelfDropZone(_ zone: CGRect?) {
        guard dropZone != zone else { return }
        dropZone = zone
        updateContentFrames(display: true)
    }

    private func updateContentFrames(display: Bool) {
        let island = islandFrame
        let expanded = dropZone.map { island.union($0) } ?? island
        // Moving the window's bottom edge must not resize or move the SwiftUI notch.
        if frame != expanded { setFrame(expanded, display: false) }
        islandContent?.positionIsland(island, zone: dropZone, windowFrame: expanded)
        if display { self.displayIfNeeded() }
    }

    static let pinnedCollectionBehavior: NSWindow.CollectionBehavior = [
        .fullScreenAuxiliary,
        .canJoinAllSpaces,
        .ignoresCycle,
        .stationary,
    ]

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        
        collectionBehavior = Self.pinnedCollectionBehavior
        
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        hasShadow = false

        ScreenCaptureVisibilityManager.shared.register(self, scope: .entireInterface)
    }
    
    override var canBecomeKey: Bool {
        true
    }
    
    override var canBecomeMain: Bool {
        true
    }

}

extension NSWindow {
    var atollIslandFrame: CGRect {
        (self as? DynamicIslandWindow)?.islandFrame ?? frame
    }

    func setAtollIslandFrame(_ frame: CGRect, display: Bool) {
        if let island = self as? DynamicIslandWindow {
            island.setIslandFrame(frame, display: display)
        } else {
            setFrame(frame, display: display)
        }
    }
}

private final class IslandWindowContent: NSView {
    private let hostingView: NSView
    private let dropView = ShelfApproachDropView(frame: .zero)

    init(hostingView: NSView) {
        self.hostingView = hostingView
        super.init(frame: .zero)
        hostingView.autoresizingMask = []
        dropView.isHidden = true
        addSubview(dropView)
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { nil }

    func positionIsland(_ island: CGRect, zone: CGRect?, windowFrame: CGRect) {
        func local(_ rect: CGRect) -> CGRect {
            rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        }
        hostingView.frame = local(island)
        dropView.frame = zone.map(local) ?? .zero
        dropView.isHidden = zone == nil
        dropView.needsDisplay = true
    }
}
