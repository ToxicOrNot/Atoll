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
import os
import SwiftUI

struct CodexApprovalRequest: Decodable, Equatable {
    let id: UUID
    let createdAt: TimeInterval
    let expiresAt: TimeInterval
    let tool: String
    let directory: String
    let input: String
}

enum CodexApprovalDecision: String {
    case allow, deny, deferToCodex
}

@MainActor
final class CodexApprovalMonitor {
    static let shared = CodexApprovalMonitor()

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Atoll/CodexApprovals", isDirectory: true)
    private static let log = os.Logger(subsystem: "com.atoll.DynamicIsland", category: "CodexApproval")
    private var timer: Timer?
    private weak var presentationModel: DynamicIslandViewModel?
    private weak var presentationWindow: NSWindow?
    private var visibleRequestID: UUID?
    private var displayed: CodexApprovalRequest?

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
        show(next)
        acknowledgeVisibleRequest()
    }

    func didPresent(_ id: UUID, in model: DynamicIslandViewModel) {
        guard displayed?.id == id, presentationModel === model else { return }
        visibleRequestID = id
        acknowledgeVisibleRequest()
    }

    func didDisappear(_ id: UUID) {
        if visibleRequestID == id { visibleRequestID = nil }
    }

    private func acknowledgeVisibleRequest() {
        guard let displayed, visibleRequestID == displayed.id,
              presentationModel?.islandActivity?.id == displayed.id,
              presentationWindow?.isVisible == true,
              (presentationWindow?.alphaValue ?? 0) > 0 else { return }
        let seen = requestDirectory(displayed.id).appendingPathComponent("seen")
        if !FileManager.default.fileExists(atPath: seen.path) {
            try? Data().write(to: seen, options: [.atomic])
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

    func resolve(_ decision: CodexApprovalDecision, request proposed: CodexApprovalRequest) {
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

    private func show(_ request: CodexApprovalRequest) {
        if displayed == request,
           presentationModel?.islandActivity?.id == request.id,
           presentationWindow?.isVisible == true { return }
        guard !DynamicIslandViewCoordinator.shared.firstLaunch,
              let target = AppDelegate.shared?.islandActivityTarget() else {
            hide()
            return
        }
        if presentationModel !== target.model { hide() }
        displayed = request
        presentationModel = target.model
        presentationWindow = target.window
        target.window.alphaValue = 1
        target.window.orderFrontRegardless()
        target.model.presentIslandActivity(.codexApproval(request))
        Self.log.notice("Presented a local Codex permission request inside the island")
    }

    private func hide() {
        if let displayed {
            presentationModel?.dismissIslandActivity(id: displayed.id)
        }
        displayed = nil
        presentationModel = nil
        presentationWindow = nil
        visibleRequestID = nil
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

struct CodexApprovalView: View {
    let request: CodexApprovalRequest
    let resolve: (CodexApprovalDecision) -> Void
    @StateObject private var quotaModel = CodexApprovalQuotaModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex").font(.system(size: 14, weight: .semibold))
                    Text("Permission requested").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(request.tool == "Bash" ? "Command" : "File changes")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.white.opacity(0.1), in: Capsule())
            }

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
        .frame(maxWidth: .infinity)
        .frame(height: 292)
        .foregroundStyle(.white)
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
