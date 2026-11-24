import Foundation

struct UsageRecord {
    let timestamp: Date
    let model: String
    /// All prompt tokens, cache hits and cache writes included (what the UI shows).
    let inputTokens: Int
    let outputTokens: Int
    /// Prompt tokens served from the provider cache (subset of `inputTokens`).
    let cacheReadTokens: Int
    /// Prompt tokens written into the provider cache (subset of `inputTokens`).
    let cacheWriteTokens: Int
    let dedupKey: String?

    init(timestamp: Date, model: String, inputTokens: Int, outputTokens: Int,
         cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, dedupKey: String?) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.dedupKey = dedupKey
    }

    /// Prompt tokens billed at the full prompt rate.
    var uncachedInputTokens: Int { max(0, inputTokens - cacheReadTokens - cacheWriteTokens) }
}

struct JSONLUsageParser {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    struct CodexQuota: Sendable {
        struct Window: Sendable {
            let usedPercent: Double
            let resetsAt: Date?
        }

        let observedAt: Date
        let fiveHour: Window?
        let weekly: Window?
    }

    static func latestCodexQuota(in root: URL, now: Date = Date()) -> CodexQuota? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }

        let recent = entries.compactMap { entry -> (URL, Date)? in
            guard let url = entry as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, let modified = values.contentModificationDate
            else { return nil }
            return (url, modified)
        }.sorted { $0.1 > $1.1 }.prefix(12)

        return recent.compactMap { newestCodexQuota(inFile: $0.0, now: now) }
            .max { $0.observedAt < $1.observedAt }
    }

    private static func newestCodexQuota(inFile url: URL, now: Date) -> CodexQuota? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        let limit: UInt64 = 256 * 1024
        guard let end = try? file.seekToEnd(),
              (try? file.seek(toOffset: end > limit ? end - limit : 0)) != nil,
              let data = try? file.read(upToCount: Int(limit))
        else { return nil }

        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
        return lines.lazy.filter { $0.contains("\"rate_limits\"") }
            .compactMap { parseCodexQuota($0, now: now) }.first
    }

    private static func parseCodexQuota(_ line: Substring, now: Date) -> CodexQuota? {
        guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              event["type"] as? String == "event_msg",
              let timestamp = event["timestamp"] as? String, let observedAt = parseDate(timestamp),
              let payload = event["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              (limits["limit_id"] as? String ?? "codex") == "codex"
        else { return nil }

        var windows: [Int: CodexQuota.Window] = [:]
        for name in ["primary", "secondary"] {
            guard let raw = limits[name] as? [String: Any],
                  let minutes = raw["window_minutes"] as? Int, minutes > 0,
                  let percent = raw["used_percent"] as? Double, percent.isFinite, percent >= 0
            else { continue }
            let reset = (raw["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            guard reset.map({ $0 > now }) ?? (now.timeIntervalSince(observedAt) < 300) else { continue }
            windows[minutes] = .init(usedPercent: min(percent, 100), resetsAt: reset)
        }
        guard windows[300] != nil || windows[10_080] != nil else { return nil }
        return CodexQuota(observedAt: observedAt, fiveHour: windows[300], weekly: windows[10_080])
    }

    static func parseLine(_ line: String) -> UsageRecord? {
        var codexModel: String? = nil
        return parseLine(line, codexModel: &codexModel)
    }

    /// `codexModel` carries the model named by the most recent Codex `turn_context`
    /// record in the same file; `token_count` records do not repeat it, so without
    /// this state every Codex record would be tagged with an unpriceable placeholder.
    static func parseLine(_ line: String, codexModel: inout String?) -> UsageRecord? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if obj["type"] as? String == "turn_context",
           let payload = obj["payload"] as? [String: Any],
           let model = payload["model"] as? String, !model.isEmpty {
            codexModel = model
            return nil
        }

        if let codexRecord = parseCodexTokenCount(obj, model: codexModel ?? "codex") {
            return codexRecord
        }

        let message = obj["message"] as? [String: Any]
        let usage = (message?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any])
        guard let usage else { return nil }
        // Claude Code reports uncached input, cache writes and cache reads as three
        // separate, non-overlapping counters.
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let input = (usage["input_tokens"] as? Int ?? 0) + cacheWrite + cacheRead
        let output = usage["output_tokens"] as? Int ?? 0
        guard input + output > 0 else { return nil }
        let model = (message?["model"] as? String) ?? (obj["model"] as? String) ?? "unknown"
        let tsString = (obj["timestamp"] as? String) ?? (message?["timestamp"] as? String) ?? ""
        guard let ts = parseDate(tsString) else { return nil }
        let messageId = message?["id"] as? String
        let requestId = (obj["requestId"] as? String) ?? (obj["request_id"] as? String)
        let dedupKey = (messageId != nil || requestId != nil) ? "\(messageId ?? "")-\(requestId ?? "")" : nil
        return UsageRecord(timestamp: ts, model: model, inputTokens: input, outputTokens: output,
                           cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, dedupKey: dedupKey)
    }

    private static func parseCodexTokenCount(_ obj: [String: Any], model: String) -> UsageRecord? {
        guard obj["type"] as? String == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any],
              let timestamp = obj["timestamp"] as? String,
              let date = parseDate(timestamp) else { return nil }

        // Codex (OpenAI usage semantics): `input_tokens` already includes the cached
        // portion reported in `cached_input_tokens`; cache writes are separate.
        let input = usage["input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let cacheRead = min(input, usage["cached_input_tokens"] as? Int ?? 0)
        let cacheWrite = usage["cache_write_input_tokens"] as? Int ?? 0
        guard input >= 0, output >= 0, (input > 0 || output > 0) else { return nil }

        return UsageRecord(
            timestamp: date,
            model: model,
            inputTokens: input + cacheWrite,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            dedupKey: nil
        )
    }

    /// Session logs are append-only, so a file whose last write predates the
    /// window cannot contain a record inside it. Returns `true` when the date is
    /// unreadable, so an unexpected filesystem keeps the file rather than
    /// silently dropping its records.
    private static func mayContainRecords(after cutoff: Date, _ file: URL) -> Bool {
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        else { return true }
        return modified >= cutoff
    }

    /// Stream a JSONL file line by line, calling `process` for each valid record.
    /// Avoids loading the entire file into memory.
    private static func streamLines(
        from file: URL,
        weekStart: Date,
        sessionStart: Date,
        now: Date,
        seen: inout Set<String>,
        perModel: inout [String: UsageTotals],
        snapshot: inout UsageSnapshot
    ) {
        let cal = Calendar.current
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        let chunkSize = 64 * 1024 // 64 KB chunks
        let maxRecordSize = 1024 * 1024 // 1 MB max per record
        var discardingOversized = false

        func processRecord(_ rec: UsageRecord) {
            guard rec.timestamp >= weekStart else { return }
            if let key = rec.dedupKey {
                if seen.contains(key) { return }
                seen.insert(key)
            }
            let cost = ModelPricing.cost(model: rec.model, inputTokens: rec.uncachedInputTokens, outputTokens: rec.outputTokens,
                                         cacheReadTokens: rec.cacheReadTokens, cacheWriteTokens: rec.cacheWriteTokens)
            func add(_ t: inout UsageTotals) {
                t.inputTokens += rec.inputTokens
                t.outputTokens += rec.outputTokens
                if let cost { t.costUSD += cost } else { t.hasUnpricedModel = true }
            }
            add(&snapshot.week)
            if cal.isDate(rec.timestamp, inSameDayAs: now) { add(&snapshot.today) }
            if rec.timestamp >= sessionStart { add(&snapshot.session) }
            var mt = perModel[rec.model] ?? UsageTotals()
            add(&mt)
            perModel[rec.model] = mt
        }

        var codexModel: String? = nil
        func processLine(_ line: String) {
            guard !line.isEmpty, let rec = parseLine(line, codexModel: &codexModel) else { return }
            processRecord(rec)
        }

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            // Process complete lines from buffer
            while let newlineRange = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange)
                buffer.removeSubrange(buffer.startIndex...newlineRange)

                if discardingOversized {
                    // We were discarding an oversized record; this newline ends it.
                    discardingOversized = false
                    continue
                }

                // Skip oversized terminated records before decoding
                if lineData.count > maxRecordSize {
                    continue
                }

                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                processLine(line)
            }

            // Bound buffer growth: if buffer exceeds maxRecordSize without a newline,
            // discard data up to the next newline when it arrives
            if buffer.count > maxRecordSize {
                discardingOversized = true
                buffer.removeFirst(buffer.count - maxRecordSize)
            }
        }

        // Process any remaining data in buffer (last line without trailing newline)
        // but only if it's within the size limit and we're not discarding
        if !buffer.isEmpty && buffer.count <= maxRecordSize && !discardingOversized,
           let line = String(data: buffer, encoding: .utf8) {
            processLine(line)
        }
    }

    static func aggregate(files: [URL], now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        var perModel: [String: UsageTotals] = [:]
        var seen = Set<String>()
        let sessionStart = now.addingTimeInterval(-5 * 3600)
        let weekStart = now.addingTimeInterval(-7 * 86400)

        for file in files where mayContainRecords(after: weekStart, file) {
            streamLines(
                from: file,
                weekStart: weekStart,
                sessionStart: sessionStart,
                now: now,
                seen: &seen,
                perModel: &perModel,
                snapshot: &snapshot
            )
        }
        snapshot.models = perModel
            .map { ModelUsage(model: $0.key, totals: $0.value, pool: nil) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
        snapshot.lastUpdated = now
        return snapshot
    }
}
