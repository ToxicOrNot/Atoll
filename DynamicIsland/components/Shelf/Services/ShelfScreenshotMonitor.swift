import AppKit
import Combine
import CoreServices
import Defaults
import SwiftUI
import ImageIO

@MainActor
final class ShelfScreenshotMonitor {
    private var changes: AnyCancellable?
    private var monitoring: Task<Void, Never>?
    private let onImport: () -> Void

    init(onImport: @escaping () -> Void) {
        self.onImport = onImport
        changes = Publishers.Merge3(
            Defaults.publisher(.autoImportScreenshotsToShelf).map { _ in () },
            Defaults.publisher(.dynamicShelf).map { _ in () },
            Defaults.publisher(.enableMinimalisticUI).map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.updateMonitoring() }
    }

    private var shelfAvailable: Bool { Defaults[.dynamicShelf] && !Defaults[.enableMinimalisticUI] }

    func captureArea() {
        guard shelfAvailable, !LockScreenManager.shared.isLocked else { return }
        let destination = ShelfPersistenceService.capturesDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(String(localized: "Screenshot") + ".png")
        ScreenshotSnippingTool.shared.startSnipping(destination: destination) { [weak self] url in
            Task { @MainActor in
                guard let self, self.shelfAvailable,
                      let item = await ShelfDropService.fileItem(for: url, isTemporary: true),
                      self.shelfAvailable else {
                    ShelfPersistenceService.removeManagedCapture(at: url)
                    return
                }
                self.add([item])
            }
        }
    }

    func stop() {
        changes?.cancel()
        monitoring?.cancel()
        monitoring = nil
    }

    private func updateMonitoring() {
        guard shelfAvailable, Defaults[.autoImportScreenshotsToShelf] else {
            monitoring?.cancel()
            monitoring = nil
            return
        }
        guard monitoring == nil else { return }
        let enabledAt = Date()
        monitoring = Task { @MainActor [weak self] in
            var imported: [URL: Date] = [:]
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                let cutoff = max(enabledAt, Date().addingTimeInterval(-45))
                imported = imported.filter { $0.value >= cutoff }
                let known = Set(imported.keys)
                let screenshots = await Task.detached(priority: .utility) {
                    Self.recentScreenshots(since: cutoff, excluding: known)
                }.value
                guard !Task.isCancelled else { return }

                let items = await ShelfDropService.items(from: screenshots.map(\.url))
                guard !Task.isCancelled, let self else { return }
                self.add(items)
                let addedPaths = Set(items.compactMap(\.cachedPath))
                for screenshot in screenshots where addedPaths.contains(screenshot.url.standardizedFileURL.path) {
                    imported[screenshot.url] = screenshot.created
                }
            }
        }
    }

    private func add(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        let added = withAnimation(.smooth(duration: 0.3)) {
            ShelfStateViewModel.shared.addScreenshots(items)
        }
        if added, !LockScreenManager.shared.isLocked { onImport() }
    }

    private nonisolated static func recentScreenshots(since cutoff: Date, excluding known: Set<URL>)
        -> [(url: URL, created: Date)] {
        let fileManager = FileManager.default
        let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let folder = location.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .creationDateKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey
        ]
        guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                options: .skipsHiddenFiles) else { return [] }
        let settledAt = Date().addingTimeInterval(-0.3)
        return contents.compactMap { url -> (URL, Date)? in
            guard !known.contains(url), let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let created = values.creationDate, created >= cutoff,
                  let modified = values.contentModificationDate, modified <= settledAt,
                  isScreenCapture(url),
                  isStillImage(url) else { return nil }
            return (url, created)
        }.sorted { $0.1 < $1.1 }
    }

    private nonisolated static func isStillImage(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetType(source) != nil
    }

    private nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        // The system writes this metadata before Spotlight has indexed the capture.
        let length = getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, XATTR_NOFOLLOW)
        if (1...256).contains(length) {
            var bytes = Data(count: length)
            let read = bytes.withUnsafeMutableBytes {
                getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, length, 0, XATTR_NOFOLLOW)
            }
            if read == length,
               let value = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? NSNumber {
                return value.boolValue
            }
        }
        guard let metadata = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return false }
        return (MDItemCopyAttribute(metadata, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue == true
    }
}
