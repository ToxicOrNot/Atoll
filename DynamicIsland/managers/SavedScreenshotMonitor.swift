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
import Darwin
import Defaults
import Foundation
import ImageIO
import SwiftUI

@MainActor
final class SavedScreenshotMonitor {
    static let shared = SavedScreenshotMonitor()

    private var monitorTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private weak var feedbackModel: DynamicIslandViewModel?
    private var feedbackID: UUID?

    func start() {
        guard monitorTask == nil else { return }
        let scanner = SavedScreenshotScanner(startedAt: Date())
        monitorTask = Task {
            while !Task.isCancelled {
                if Defaults[.dynamicShelf] || Defaults[.enableClipboardManager] {
                    let screenshots = await scanner.newScreenshots()
                    guard !Task.isCancelled else { return }

                    if Defaults[.dynamicShelf], !screenshots.isEmpty {
                        let items = await ShelfDropService.items(from: screenshots)
                        guard !Task.isCancelled else { return }
                        if Defaults[.dynamicShelf] {
                            ShelfStateViewModel.shared.add(items)
                            // Read the original capture, independently of bookmark
                            // resolution or asynchronous shelf metadata loading.
                            if !items.isEmpty, let url = screenshots.last {
                                let thumbnail = await scanner.thumbnail(for: url)
                                if !Task.isCancelled, let thumbnail {
                                    animateIntoShelf(thumbnail)
                                }
                            }
                        }
                    }

                    if Defaults[.enableClipboardManager] {
                        for url in screenshots {
                            ClipboardManager.shared.addSavedScreenshot(url)
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        dismissFeedback()
    }

    private func animateIntoShelf(_ thumbnail: CGImage) {
        guard !LockScreenManager.shared.isLocked,
              !DynamicIslandViewCoordinator.shared.firstLaunch,
              let target = AppDelegate.shared?.islandActivityTarget() else { return }
        // A screenshot must never replace a permission decision being reviewed.
        if case .codexApproval = target.model.islandActivity { return }
        feedbackTask?.cancel()
        if feedbackModel !== target.model { dismissFeedback() }
        let id = UUID()
        feedbackID = id
        feedbackModel = target.model
        target.window.alphaValue = 1
        target.window.orderFrontRegardless()
        target.model.presentIslandActivity(.screenshot(
            id: id, image: NSImage(cgImage: thumbnail, size: .zero)
        ))
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self, self.feedbackID == id else { return }
            self.dismissFeedback()
        }
    }

    private func dismissFeedback() {
        if let feedbackID { feedbackModel?.dismissIslandActivity(id: feedbackID) }
        feedbackModel = nil
        feedbackID = nil
    }
}
