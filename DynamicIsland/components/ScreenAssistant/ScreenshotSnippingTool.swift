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
import SwiftUI
import Foundation

@MainActor
final class ScreenshotSnippingTool: ObservableObject {
    static let shared = ScreenshotSnippingTool()

    @Published private(set) var isSnipping = false
    private var process: Process?

    enum ScreenshotType {
        case full
        case window
        case area

        var processArguments: [String] {
            switch self {
            case .full: ["-x", "-m"]
            case .window: ["-x", "-i", "-w"]
            case .area: ["-x", "-i", "-s"]
            }
        }

        var displayName: String {
            switch self {
            case .full: "Full Screen"
            case .window: "Window"
            case .area: "Area"
            }
        }

        var iconName: String {
            switch self {
            case .full: "rectangle.dashed"
            case .window: "macwindow"
            case .area: "viewfinder.rectangular"
            }
        }
    }

    @discardableResult
    func startSnipping(
        type: ScreenshotType = .area,
        destination: URL? = nil,
        completion: @escaping (URL) -> Void
    ) -> Bool {
        guard !isSnipping else { return false }
        let url = destination ?? ScreenAssistantManager.screenshotDataDirectory
            .appendingPathComponent("screenshot_\(UUID().uuidString).png")
        let directory = url.deletingLastPathComponent()
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = type.processArguments + ["-t", "png", url.path]
        capture.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.process = nil
                self.isSnipping = false
                if finished.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) {
                    completion(url)
                } else if destination != nil {
                    try? FileManager.default.removeItem(at: directory)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try capture.run()
            process = capture
            isSnipping = true
            return true
        } catch {
            if destination != nil { try? FileManager.default.removeItem(at: directory) }
            NSLog("Screen capture could not start: %@", error.localizedDescription)
            return false
        }
    }
}
