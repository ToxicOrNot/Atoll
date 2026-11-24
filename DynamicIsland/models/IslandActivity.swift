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
import Defaults
import SwiftUI

/// Short-lived content uses the notch's existing window, shape and animation.
enum IslandActivity: Identifiable {
    case codexApproval(CodexApprovalRequest)
    case screenshot(id: UUID, image: NSImage)

    var id: UUID {
        switch self {
        case .codexApproval(let request): return request.id
        case .screenshot(let id, _): return id
        }
    }

    func size(closedNotchHeight: CGFloat) -> CGSize {
        switch self {
        case .codexApproval:
            return CGSize(width: 440, height: closedNotchHeight + 292)
        case .screenshot:
            return CGSize(width: 320, height: closedNotchHeight + 84)
        }
    }
}

extension AppDelegate {
    /// Choose an existing island even if its closed surface is hidden. Do not
    /// create a floating fallback card disconnected from the island.
    @MainActor
    func islandActivityTarget() -> (window: NSWindow, model: DynamicIslandViewModel)? {
        if !Defaults[.showOnAllDisplays], let window { return (window, vm) }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
        if let screen, let window = windows[screen], let model = viewModels[screen] {
            return (window, model)
        }
        for (screen, window) in windows {
            if let model = viewModels[screen] { return (window, model) }
        }
        return nil
    }
}

struct SavedScreenshotFeedbackView: View {
    let image: NSImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .scaleEffect(arrived || reduceMotion ? 1 : 0.5)
                .offset(y: arrived || reduceMotion ? 0 : 24)
                .opacity(arrived ? 1 : 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("Screenshot saved").font(.system(size: 13, weight: .semibold))
                Label("Added to Shelf", systemImage: "tray.and.arrow.down.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 84)
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8)) {
                arrived = true
            }
        }
    }
}
