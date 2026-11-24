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

import AppKit

/// A native subview of the drag surface: AppKit delivers the click directly
/// instead of trying to hit a SwiftUI button behind NSViewRepresentable.
final class ShelfRemoveControl: NSButton {
    private let onRemove: () -> Void

    init(onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from Shelf")
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        toolTip = "Remove from Shelf"
        setAccessibilityLabel("Remove from Shelf")
        target = self
        action = #selector(removeFromShelf)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func removeFromShelf() { onRemove() }

    static func frame(in bounds: CGRect, isFlipped: Bool, isRightToLeft: Bool) -> CGRect {
        let size: CGFloat = 22
        let inset: CGFloat = 2
        return CGRect(
            x: isRightToLeft ? bounds.minX + inset : bounds.maxX - inset - size,
            y: isFlipped ? bounds.minY + inset : bounds.maxY - inset - size,
            width: size, height: size
        )
    }
}
