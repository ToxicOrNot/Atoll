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
import QuartzCore

@MainActor
final class SavedScreenshotMonitor {
    static let shared = SavedScreenshotMonitor()

    private var monitorTask: Task<Void, Never>?
    private var previewPanel: NSPanel?

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
                            if let url = items.last?.resolvedFileURL {
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
        previewPanel?.orderOut(nil)
        previewPanel = nil
    }

    private func animateIntoShelf(_ thumbnail: CGImage) {
        guard !LockScreenManager.shared.isLocked, let app = AppDelegate.shared else { return }
        let windows = app.windows.values.filter { $0.isVisible && $0.alphaValue > 0 }
        let pointer = NSEvent.mouseLocation
        let singleWindow = app.window.flatMap { $0.isVisible && $0.alphaValue > 0 ? $0 : nil }
        guard let notch = singleWindow ?? windows.first(where: { $0.screen?.frame.contains(pointer) == true })
                ?? windows.first else { return }

        previewPanel?.orderOut(nil)
        let size = CGSize(width: 52, height: 38)
        let target = CGRect(
            x: notch.atollIslandFrame.midX - 8,
            y: notch.atollIslandFrame.maxY - 21,
            width: 16, height: 12
        )
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = CGRect(
            x: notch.atollIslandFrame.midX - size.width / 2,
            y: notch.atollIslandFrame.minY - size.height - 26,
            width: size.width, height: size.height
        )
        let panel = NSPanel(
            contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = notch.level + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let image = NSImageView(frame: CGRect(origin: .zero, size: size))
        image.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.autoresizingMask = [.width, .height]
        image.wantsLayer = true
        image.layer?.cornerRadius = 5
        image.layer?.masksToBounds = true
        panel.contentView = image
        previewPanel = panel
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.35 : 0.48
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if !reduceMotion {
                panel.animator().setFrame(target, display: true)
            }
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let panel else { return }
                panel.orderOut(nil)
                if self?.previewPanel === panel {
                    self?.previewPanel = nil
                }
            }
        }
    }
}

/// Looks for macOS's screenshot attribute directly, even in folders excluded from Spotlight.
actor SavedScreenshotScanner {
    private static let imageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "jp2", "jpeg", "jpg", "pdf",
        "pict", "png", "psd", "tga", "tif", "tiff"
    ]

    private struct Screenshot: Hashable {
        let url: URL
        let createdAt: Date
    }

    private let startedAt: Date
    private var seen: Set<Screenshot> = []
    private var lastDirectory: URL?
    private var lastDirectoryModification: Date?
    private var rescanUntil = Date.distantPast

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    private static var screenshotDirectory: URL {
        if let location = CFPreferencesCopyAppValue(
            "location" as CFString,
            "com.apple.screencapture" as CFString
        ) as? String, !location.isEmpty {
            let path = NSString(string: location).expandingTildeInPath
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    func newScreenshots(in directory: URL? = nil, now: Date = Date()) -> [URL] {
        let directory = directory ?? Self.screenshotDirectory
        let modification = try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if directory != lastDirectory || modification != lastDirectoryModification {
            lastDirectory = directory
            lastDirectoryModification = modification
            // The file may appear before its screenshot metadata is committed.
            rescanUntil = now.addingTimeInterval(8)
        }
        guard now <= rescanUntil else { return [] }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        ) else { return [] }

        var screenshots: [Screenshot] = []
        for file in files {
            guard Self.imageExtensions.contains(file.pathExtension.lowercased()),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let createdAt = values.creationDate, createdAt >= startedAt,
                  let modifiedAt = values.contentModificationDate, now.timeIntervalSince(modifiedAt) >= 0.35,
                  let size = values.fileSize, size > 0 else { continue }

            let screenshot = Screenshot(url: file, createdAt: createdAt)
            guard !seen.contains(screenshot), Self.hasScreenshotAttribute(file) else { continue }
            seen.insert(screenshot)
            screenshots.append(screenshot)
        }
        return screenshots.sorted { $0.createdAt < $1.createdAt }.map(\.url)
    }

    func thumbnail(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    private static func hasScreenshotAttribute(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) > 0
        }
    }
}
