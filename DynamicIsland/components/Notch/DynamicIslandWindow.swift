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
import Defaults

class DynamicIslandWindow: NSPanel, NSDraggingDestination {
    weak var shelfViewModel: DynamicIslandViewModel?
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
    
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let vm = shelfViewModel else { return [] }
        let accepts = acceptsShelfDrag(sender, viewModel: vm)
        if vm.nativeShelfTargeting != accepts {
            vm.nativeShelfTargeting = accepts
        }
        return accepts ? .copy : []
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        shelfViewModel?.nativeShelfTargeting = false
    }

    func draggingEnded(_ sender: NSDraggingInfo) {
        shelfViewModel?.nativeShelfTargeting = false
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let vm = shelfViewModel else { return false }
        defer { vm.nativeShelfTargeting = false }
        guard acceptsShelfDrag(sender, viewModel: vm) else { return false }
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let urls = objects.compactMap { $0 as? URL }.filter(\.isFileURL)
        guard !urls.isEmpty else { return false }
        return vm.onShelfFileDrop?(urls) ?? false
    }

    private func acceptsShelfDrag(_ sender: NSDraggingInfo, viewModel: DynamicIslandViewModel) -> Bool {
        guard Defaults[.dynamicShelf], Defaults[.expandedDragDetection], !Defaults[.enableMinimalisticUI],
              !LockScreenManager.shared.isLocked, CodexApprovalManager.shared.request(for: viewModel) == nil,
              !ShelfSelectionModel.shared.isDragging,
              sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.availableType(from: [.fileURL]) != nil,
              let displayFrame = screen?.frame ?? getScreenFrame(viewModel.screen) else { return false }

        let location = convertPoint(toScreen: sender.draggingLocation)
        let size = expandedShelfDropArea(closedNotchSize: viewModel.closedNotchSize)
        return CGRect(
            x: displayFrame.midX - size.width / 2,
            y: displayFrame.maxY - size.height,
            width: size.width,
            height: size.height
        ).contains(location)
    }

    override var canBecomeKey: Bool {
        true
    }
    
    override var canBecomeMain: Bool {
        true
    }

}
