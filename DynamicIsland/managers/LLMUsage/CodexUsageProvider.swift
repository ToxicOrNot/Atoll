import Foundation

struct CodexUsageProvider: UsageProvider {
    let id: ProviderID = .codex
    let root: URL
    let quotaClient: CodexQuotaClient

    static var sessionsDirectory: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("sessions")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    init(root: URL = Self.sessionsDirectory, quotaClient: CodexQuotaClient = CodexQuotaClient()) {
        self.root = root
        self.quotaClient = quotaClient
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.notFound("No ~/.codex/sessions — Codex not detected")
        }
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw UsageError.notFound("No Codex usage logs found")
        }
        let files = en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        guard !files.isEmpty else { throw UsageError.notFound("No Codex usage logs found") }
        var snapshot = JSONLUsageParser.aggregate(files: files, now: now)
        let quota = await quotaClient.fetchLimits()
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        if snapshot.sessionLimit == nil || snapshot.weekLimit == nil,
           let logged = JSONLUsageParser.latestCodexQuota(in: root, now: now) {
            if snapshot.sessionLimit == nil, let window = logged.fiveHour {
                snapshot.sessionLimit = UsageLimit(used: window.usedPercent, limit: 100, resetsAt: window.resetsAt)
            }
            if snapshot.weekLimit == nil, let window = logged.weekly {
                snapshot.weekLimit = UsageLimit(used: window.usedPercent, limit: 100, resetsAt: window.resetsAt)
            }
        }
        return snapshot
    }
}
