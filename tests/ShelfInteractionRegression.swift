import AppKit
import Darwin
import Foundation

@main
struct ShelfInteractionRegression {
    @MainActor
    static func main() async throws {
        // A closed island may be hosted in an NSWindow hundreds of points tall.
        // The approach area must remain below the camera, including on displays
        // with negative origins. It must not depend on that window's bottom.
        for screen in [CGRect(x: 0, y: 0, width: 1512, height: 982),
                       CGRect(x: -1920, y: -200, width: 1920, height: 1080)] {
            let zone = ShelfDragApproachGeometry.zone(
                screenFrame: screen, centerX: screen.midX,
                closedSize: CGSize(width: 200, height: 32)
            )
            precondition(zone.height == 158)
            precondition(zone.contains(CGPoint(x: screen.midX, y: screen.maxY - 100)))
            precondition(!zone.contains(CGPoint(x: screen.midX, y: screen.maxY - 300)))
            precondition(screen.contains(zone))
        }

        // The control must win hit testing inside the very same native surface
        // used for dragging, in flipped and right-to-left layouts as well.
        for flipped in [false, true] {
            for rtl in [false, true] {
                let cell = NSView(frame: CGRect(x: 0, y: 0, width: 115, height: 110))
                var removals = 0
                let button = ShelfRemoveControl { removals += 1 }
                button.frame = ShelfRemoveControl.frame(in: cell.bounds, isFlipped: flipped, isRightToLeft: rtl)
                cell.addSubview(button)
                let point = CGPoint(x: button.frame.midX, y: button.frame.midY)
                precondition(cell.hitTest(point) === button)
                precondition(button.acceptsFirstMouse(for: nil))
                button.performClick(nil)
                precondition(removals == 1)
                precondition(cell.hitTest(CGPoint(x: 50, y: 50)) === cell)
            }
        }

        // macOS can write the image before attaching its screenshot metadata.
        // Keep scanning after the directory mtime stops changing, import once,
        // and ignore ordinary images and captures from before launch.
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date().addingTimeInterval(-10)
        let scanner = SavedScreenshotScanner(startedAt: started)
        let capture = directory.appendingPathComponent("capture.png")
        let ordinary = directory.appendingPathComponent("ordinary.png")
        let old = directory.appendingPathComponent("old.png")
        for file in [capture, ordinary, old] {
            try Data([1, 2, 3]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1)], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes([.creationDate: started.addingTimeInterval(-100)], ofItemAtPath: old.path)
        var imports = await scanner.newScreenshots(in: directory)
        precondition(imports.isEmpty)
        for file in [capture, old] {
            let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
            let result = data.withUnsafeBytes { bytes in
                setxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, data.count, 0, 0)
            }
            precondition(result == 0)
        }
        imports = await scanner.newScreenshots(in: directory, now: Date().addingTimeInterval(1))
        precondition(imports.map { $0.resolvingSymlinksInPath().path } == [capture.resolvingSymlinksInPath().path], "imports=\(imports) capture=\(capture)")
        imports = await scanner.newScreenshots(in: directory)
        precondition(imports.isEmpty)
        print("Shelf interaction regressions passed")
    }
}
