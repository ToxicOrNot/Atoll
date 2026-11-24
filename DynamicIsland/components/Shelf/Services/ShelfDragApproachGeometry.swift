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

import Foundation

enum ShelfDragApproachGeometry {
    static func zone(screenFrame: CGRect, centerX: CGFloat, closedSize: CGSize) -> CGRect {
        let width = min(closedSize.width + 160, screenFrame.width)
        let bottom = max(screenFrame.minY, screenFrame.maxY - 190)
        let top = screenFrame.maxY - closedSize.height
        return CGRect(
            x: min(max(centerX - width / 2, screenFrame.minX), screenFrame.maxX - width),
            y: bottom, width: width, height: max(0, top - bottom)
        )
    }
}
