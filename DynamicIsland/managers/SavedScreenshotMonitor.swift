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

import Darwin
import Defaults
import Foundation

@MainActor
final class SavedScreenshotMonitor {
    static let shared = SavedScreenshotMonitor()

    private var monitorTask: Task<Void, Never>?

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
                        }
                    }

                    if Defaults[.enableClipboardManager] {
                        for url in screenshots {
                            ClipboardManager.shared.addSavedScreenshot(url)
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
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
                  let modifiedAt = values.contentModificationDate, now.timeIntervalSince(modifiedAt) >= 1,
                  let size = values.fileSize, size > 0 else { continue }

            let screenshot = Screenshot(url: file, createdAt: createdAt)
            guard !seen.contains(screenshot), Self.hasScreenshotAttribute(file) else { continue }
            seen.insert(screenshot)
            screenshots.append(screenshot)
        }
        return screenshots.sorted { $0.createdAt < $1.createdAt }.map(\.url)
    }

    private static func hasScreenshotAttribute(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW) > 0
        }
    }
}
