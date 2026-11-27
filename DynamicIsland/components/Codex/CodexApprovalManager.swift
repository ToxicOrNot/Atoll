import AppKit
import Combine
import Defaults

@MainActor
final class CodexApprovalManager: ObservableObject {
    static let shared = CodexApprovalManager()
    static let minimumNotchSize = CGSize(width: 420, height: 190)

    struct Request: Identifiable {
        let id: URL
        let tool: String
        let directory: String
        let detail: String
        let reason: String?
    }

    enum Decision: String {
        case allow
        case deny
        case deferToCodex
    }

    private struct Payload: Decodable {
        let hook_event_name: String
        let tool_name: String
        let cwd: String
    }

    @Published private(set) var current: Request?
    private weak var target: DynamicIslandViewModel?
    private var queue: [Request] = []
    private var settingObserver: AnyCancellable?
    private var timer: AnyCancellable?
    private var chooseTarget: (() -> DynamicIslandViewModel?)?
    private var onDismiss: (() -> Void)?
    var hasPendingRequests: Bool { !queue.isEmpty }

    private var bridgeDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("atoll-codex-approvals", isDirectory: true)
    }

    static var hookConfiguration: String? {
        guard let script = Bundle.main.url(forResource: "codex-permission-hook", withExtension: "txt") else { return nil }
        let escapedPath = script.path.replacingOccurrences(of: "'", with: "'\\''")
        let configuration: [String: Any] = ["hooks": ["PermissionRequest": [
            ["hooks": [["type": "command", "command": "/bin/sh '\(escapedPath)'", "timeout": 100]]]
        ]]]
        guard let data = try? JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func start(chooseTarget: @escaping () -> DynamicIslandViewModel?, onDismiss: @escaping () -> Void) {
        self.chooseTarget = chooseTarget
        self.onDismiss = onDismiss
        settingObserver = Defaults.publisher(.codexNotchApprovals)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMonitoring() }
    }

    func stop() {
        settingObserver = nil
        timer = nil
        for request in queue { _ = write(.deferToCodex, to: request) }
        queue.removeAll()
        current = nil
        target = nil
    }

    func request(for viewModel: DynamicIslandViewModel) -> Request? {
        target === viewModel ? current : nil
    }

    func decide(_ decision: Decision, for request: Request) {
        guard request.id == current?.id else { return }
        if write(decision, to: request) || !isPending(request.id) {
            queue.removeAll { $0.id == request.id }
            refreshPresentation()
        }
    }

    private func updateMonitoring() {
        if Defaults[.codexNotchApprovals] {
            guard timer == nil else { return }
            timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.poll() }
            poll()
        } else {
            timer = nil
            for request in queue { _ = write(.deferToCodex, to: request) }
            queue.removeAll()
            refreshPresentation()
        }
    }

    private func poll() {
        queue.removeAll { !isPending($0.id) }
        guard !LockScreenManager.shared.isLocked, chooseTarget != nil else {
            for request in queue { _ = write(.deferToCodex, to: request) }
            queue.removeAll()
            refreshPresentation()
            return
        }

        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(at: bridgeDirectory,
                                                         includingPropertiesForKeys: [.creationDateKey],
                                                         options: .skipsHiddenFiles)) ?? []
        let known = Set(queue.map(\.id))
        for url in urls.sorted(by: {
            let left = try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate
            let right = try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (left ?? .distantFuture) < (right ?? .distantFuture)
        }) where url.lastPathComponent.hasPrefix("request.") && !known.contains(url) {
            guard isPending(url), !fileManager.fileExists(atPath: url.appendingPathComponent("received").path),
                  let request = readRequest(in: url) else { continue }
            guard (try? Data().write(to: url.appendingPathComponent("received"), options: .withoutOverwriting)) != nil else {
                continue
            }
            queue.append(request)
        }
        refreshPresentation()
    }

    private func refreshPresentation() {
        guard let next = queue.first else {
            guard current != nil else { return }
            current = nil
            target = nil
            onDismiss?()
            return
        }
        if current?.id == next.id, let target, target.notchState == .open { return }
        guard let viewModel = chooseTarget?() else {
            for request in queue { _ = write(.deferToCodex, to: request) }
            queue.removeAll()
            refreshPresentation()
            return
        }
        target = viewModel
        current = next
    }

    private func readRequest(in directory: URL) -> Request? {
        let url = directory.appendingPathComponent("request.json")
        guard let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              attrs.isRegularFile == true, attrs.isSymbolicLink == false,
              let size = attrs.fileSize, (1...262144).contains(size),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.hook_event_name == "PermissionRequest",
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let input = object["tool_input"],
              let formatted = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else {
            return nil
        }
        let fields = input as? [String: Any]
        let detail = String(decoding: formatted, as: UTF8.self)
        return Request(id: directory, tool: payload.tool_name, directory: payload.cwd,
                       detail: detail, reason: fields?["description"] as? String)
    }

    private func isPending(_ directory: URL) -> Bool {
        guard let attrs = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]),
              attrs.isDirectory == true, attrs.isSymbolicLink == false,
              let created = attrs.creationDate, Date().timeIntervalSince(created) < 94 else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: directory.appendingPathComponent("request.json").path)
            && !fm.fileExists(atPath: directory.appendingPathComponent("decision").path)
    }

    private func write(_ decision: Decision, to request: Request) -> Bool {
        guard isPending(request.id) else { return false }
        do {
            try Data(decision.rawValue.utf8).write(to: request.id.appendingPathComponent("decision"), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
