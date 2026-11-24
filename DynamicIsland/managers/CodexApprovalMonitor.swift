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
import Darwin
import SwiftUI

private struct CodexApprovalRequest: Decodable, Equatable {
    let id: UUID
    let createdAt: TimeInterval
    let expiresAt: TimeInterval
    let tool: String
    let directory: String
    let input: String
}

private enum CodexApprovalDecision: String {
    case allow, deny, deferToCodex
}

@MainActor
final class CodexApprovalMonitor {
    static let shared = CodexApprovalMonitor()

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Atoll/CodexApprovals", isDirectory: true)
    private let size = CGSize(width: 430, height: 306)
    private var timer: Timer?
    private var panel: NSPanel?
    private var displayed: CodexApprovalRequest?

    var activeApprovalWindow: NSWindow? { panel?.isVisible == true ? panel : nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { Self.shared.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hide()
    }

    private func refresh() {
        guard !LockScreenManager.shared.isLocked, Self.isPrivateDirectory(root),
              let window = notchWindow(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else {
            hide()
            return
        }

        let pending = names.compactMap { name -> CodexApprovalRequest? in
            guard let id = UUID(uuidString: name), name == id.uuidString.lowercased() else { return nil }
            return request(for: id)
        }.sorted { $0.createdAt < $1.createdAt }

        guard let next = pending.first else {
            hide()
            return
        }
        show(next, under: window)
        guard panel?.isVisible == true else { return }
        for request in pending {
            let seen = requestDirectory(request.id).appendingPathComponent("seen")
            if !FileManager.default.fileExists(atPath: seen.path) {
                try? Data().write(to: seen, options: [.atomic])
            }
        }
    }

    private func requestDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func request(for id: UUID) -> CodexApprovalRequest? {
        let directory = requestDirectory(id)
        guard Self.isPrivateDirectory(directory),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("reply").path),
              let data = Self.readRequest(directory.appendingPathComponent("request.json")),
              let request = try? JSONDecoder().decode(CodexApprovalRequest.self, from: data),
              request.id == id, ["Bash", "apply_patch"].contains(request.tool),
              !request.input.isEmpty, request.expiresAt > Date().timeIntervalSince1970
        else { return nil }
        return request
    }

    private func resolve(_ decision: CodexApprovalDecision, request proposed: CodexApprovalRequest) {
        guard !LockScreenManager.shared.isLocked,
              displayed == proposed, request(for: proposed.id) == proposed else { return }
        let reply = requestDirectory(proposed.id).appendingPathComponent("reply")
        do {
            try Data(decision.rawValue.utf8).write(to: reply, options: [.atomic])
            hide()
            if decision == .deferToCodex {
                let apps = ["com.openai.codex", "com.openai.chat"]
                apps.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
                    .first?.activate(options: [])
            }
        } catch {
            hide()
        }
    }

    private func notchWindow() -> NSWindow? {
        guard let app = AppDelegate.shared else { return nil }
        if let window = app.window, window.isVisible, window.alphaValue > 0 { return window }
        let point = NSEvent.mouseLocation
        let windows = app.windows.values.filter { $0.isVisible && $0.alphaValue > 0 }
        return windows.first { $0.screen?.frame.contains(point) == true } ?? windows.first
    }

    private func show(_ request: CodexApprovalRequest, under notch: NSWindow) {
        guard let screen = notch.screen else {
            hide()
            return
        }
        let bounds = screen.frame.insetBy(dx: 8, dy: 8)
        let frame = CGRect(
            x: min(max(notch.atollIslandFrame.midX - size.width / 2, bounds.minX), bounds.maxX - size.width),
            y: max(bounds.minY, notch.atollIslandFrame.minY - size.height - 6),
            width: size.width, height: size.height
        )
        let window: NSPanel
        if let panel {
            window = panel
        } else {
            window = NSPanel(
                contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hidesOnDeactivate = false
            window.hasShadow = true
            window.collectionBehavior = DynamicIslandWindow.pinnedCollectionBehavior
            ScreenCaptureVisibilityManager.shared.register(window, scope: .entireInterface)
            panel = window
        }

        if displayed != request {
            displayed = request
            window.contentView = FirstMouseHostingView(rootView: CodexApprovalView(request: request) { [weak self] decision in
                self?.resolve(decision, request: request)
            })
        }
        window.level = NSWindow.Level(rawValue: notch.level.rawValue + 1)
        if window.frame != frame {
            window.setFrame(frame, display: true)
        }
        if !window.isVisible {
            window.orderFrontRegardless()
            NotchSpaceManager.shared.notchSpace.windows.insert(window)
        }
    }

    private func hide() {
        if let panel, displayed != nil {
            NotchSpaceManager.shared.notchSpace.windows.remove(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        displayed = nil
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
    }

    private static func readRequest(_ url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        let limit = 96 * 1024
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= limit
        else { return nil }
        return try? file.read(upToCount: limit)
    }
}

@MainActor
private final class CodexApprovalQuotaModel: ObservableObject {
    @Published private(set) var quota: JSONLUsageParser.CodexQuota?

    func load() async {
        let root = CodexUsageProvider.sessionsDirectory
        let latest = await Task.detached(priority: .utility) {
            JSONLUsageParser.latestCodexQuota(in: root)
        }.value
        if !Task.isCancelled { quota = latest }
    }
}

private struct CodexApprovalView: View {
    let request: CodexApprovalRequest
    let resolve: (CodexApprovalDecision) -> Void
    @StateObject private var quotaModel = CodexApprovalQuotaModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Codex approval", systemImage: "lock.shield")
                .font(.headline)

            if let quota = quotaModel.quota {
                HStack(spacing: 14) {
                    if let window = quota.fiveHour {
                        quotaWindow("5-hour", window)
                    }
                    if let window = quota.weekly {
                        quotaWindow("Weekly", window)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(Text("Last recorded: \(quota.observedAt, style: .relative)"))
            }

            Text(request.tool == "Bash" ? "Shell command" : "File changes")
                .font(.subheadline.weight(.medium))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: request.directory)
                        .foregroundStyle(.secondary)
                    Text(verbatim: request.input)
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Respond in Codex") { resolve(.deferToCodex) }
                Spacer()
                Button("Deny", role: .destructive) { resolve(.deny) }
                Button("Allow once") { resolve(.allow) }
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(.black, in: RoundedRectangle(cornerRadius: 20))
        .preferredColorScheme(.dark)
        .task { await quotaModel.load() }
    }

    private func quotaWindow(_ label: LocalizedStringKey, _ window: JSONLUsageParser.CodexQuota.Window) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                Text("\(Int((100 - window.usedPercent).rounded()))% left")
                    .fontWeight(.semibold)
            }
            if let reset = window.resetsAt {
                Text("Resets in \(reset, style: .relative)")
            }
        }
    }
}
