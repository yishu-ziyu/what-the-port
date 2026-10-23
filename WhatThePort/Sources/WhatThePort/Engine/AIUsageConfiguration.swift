import Foundation
import Combine
import CryptoKit

/// The selected nine providers, not CodexBar's entire catalog.
enum AIUsageProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex, claude, cursor, opencodego, antigravity, zai, minimax, kimi, stepfun
    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .opencodego: return "OpenCode Go"
        case .antigravity: return "Antigravity"
        case .zai: return "z.ai"
        case .minimax: return "MiniMax"
        case .kimi: return "Kimi Code"
        case .stepfun: return "StepFun"
        }
    }
}

enum AIUsageConfiguration {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.whattheport.app.local.zh/ai-usage")
    }
    static var url: URL { directory.appendingPathComponent("providers.json") }

    /// One-time private copy. Never overwrites either the original or an existing destination.
    static func migrate(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        let original: [String: Any]
        if fm.fileExists(atPath: source.path) {
            original = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any] ?? [:]
        } else { original = [:] }
        let providers = original["providers"] as? [[String: Any]] ?? []
        // Copy only credential/source fields understood by the selected reader. No external hooks.
        let allowed = Set(["id", "source", "apiKey", "secretKey", "cookieHeader", "cookieSource", "region", "workspaceID", "enterpriseHost", "tokenAccounts"])
        let selected: [[String: Any]] = AIUsageProvider.allCases.map { provider in
            var record = (providers.first { $0["id"] as? String == provider.rawValue } ?? ["id": provider.rawValue])
                .filter { allowed.contains($0.key) }
            record["enabled"] = true
            return record
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "providers": selected], options: [.sortedKeys])
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: [.withoutOverwriting])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func prepare() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let current = home.appendingPathComponent(".config/codexbar/config.json")
        let legacy = home.appendingPathComponent(".codexbar/config.json")
        try migrate(from: FileManager.default.fileExists(atPath: current.path) ? current : legacy, to: url)
    }

    static func readerEnvironment(provider: AIUsageProvider, config: URL) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEXBAR_CONFIG"] = config.path
        if provider == .claude {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
            let record = (object?["providers"] as? [[String: Any]])?.first { $0["id"] as? String == provider.rawValue }
            if record?["source"] as? String == "oauth" {
                guard record?["nativeOAuthAllowed"] as? Bool == true else { throw AIUsageError.loginRequired }
                environment = try ClaudeNativeOAuth.read().queryEnvironment(base: environment)
            }
        }
        if provider == .stepfun {
            let data = try Data(contentsOf: config)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let record = (object?["providers"] as? [[String: Any]])?.first { $0["id"] as? String == provider.rawValue }
            // v0.68 GUI stores username in apiKey, password in cookieHeader, manual token in region.
            // Its CLI sets password to empty. Pass the existing login fields only to this child process.
            if record?["cookieSource"] as? String != "manual" {
                if let username = record?["apiKey"] as? String { environment["STEPFUN_USERNAME"] = username }
                if let password = record?["cookieHeader"] as? String { environment["STEPFUN_PASSWORD"] = password }
            }
            if let token = record?["region"] as? String, !token.isEmpty { environment["STEPFUN_TOKEN"] = token }
        }
        return environment
    }

    static func fingerprint(_ provider: AIUsageProvider, at config: URL) -> String? {
        guard let data = try? Data(contentsOf: config),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["providers"] as? [[String: Any]],
              let row = rows.first(where: { $0["id"] as? String == provider.rawValue }),
              let encoded = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class AIUsageCatalog: ObservableObject {
    let stores: [AIUsageStore] = AIUsageProvider.allCases.map { AIUsageStore(client: .system(provider: $0)) }
    private var forwarding: [AnyCancellable] = []

    init() {
        // The page groups providers by their state, so any store change must redraw it.
        forwarding = stores.map { $0.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
    }
    func store(for provider: AIUsageProvider) -> AIUsageStore { stores.first { $0.provider == provider }! }
    @Published private(set) var refreshingAll = false
    /// The usage page sets this while it is on screen; readings refresh faster then.
    var isVisible = false { didSet { if isVisible && !oldValue { Task { await refreshDue() } } } }
    private var schedule: Task<Void, Never>?

    /// Background cadence: every 2 minutes while the page is open, every 15 minutes otherwise,
    /// doubled in Low Power Mode. Only stale readings are queried.
    func startSchedule() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDue()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var interval: TimeInterval {
        let base: TimeInterval = isVisible ? 120 : 900
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? base * 2 : base
    }

    func refreshDue() async {
        let now = Date()
        let due = stores.filter { store in
            guard store.state != .refreshing else { return false }
            let last = max(store.snapshot?.updatedAt ?? .distantPast, store.lastAttempt ?? .distantPast)
            // A window that reset since the last query makes the reading out of date right away.
            let rolledOver = store.snapshot?.windows.contains { $0.value.resetsAt.map { $0 > last && $0 <= now } ?? false } ?? false
            return rolledOver || now.timeIntervalSince(last) > interval
        }
        await refresh(due)
    }

    /// Keep at most three readers active; a slow provider must not hold up the next one.
    func refreshAll() async {
        guard !refreshingAll else { return }
        refreshingAll = true
        await refresh(stores)
        refreshingAll = false
    }

    private func refresh(_ selected: [AIUsageStore]) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = selected.makeIterator()
            for _ in 0..<3 {
                if let store = iterator.next() { group.addTask { await store.refresh() } }
            }
            while await group.next() != nil {
                if let store = iterator.next() { group.addTask { await store.refresh() } }
            }
        }
    }
}
