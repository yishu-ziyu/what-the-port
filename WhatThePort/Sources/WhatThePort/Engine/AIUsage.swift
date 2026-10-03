import Foundation
import Combine
import CryptoKit
import Darwin

struct AIUsageWindow: Codable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    var remainingPercent: Double { 100 - usedPercent }

    func expectedUsedPercent(at now: Date) -> Double? {
        guard let minutes = windowMinutes, minutes > 0, let reset = resetsAt else { return nil }
        let duration = Double(minutes) * 60
        let remaining = reset.timeIntervalSince(now)
        guard remaining > 0, remaining <= duration else { return nil }
        return (duration - remaining) / duration * 100
    }
}

struct AIUsageSnapshot: Codable, Sendable {
    let owner: String
    let source: String
    let updatedAt: Date
    let primary: AIUsageWindow?
    let secondary: AIUsageWindow?

    var tertiary: AIUsageWindow? = nil
    var labels: [String: String]? = nil
    var extraWindows: [AIUsageLabeledWindow]? = nil
    var dataConfidence: String? = nil
    var details: [AIUsageDetail]? = nil
    var isEstimated: Bool { dataConfidence == "estimated" || source == "local" }

    /// Names and periods belong to the returned business data, not slot positions.
    var windows: [(id: String, title: String, value: AIUsageWindow)] {
        var result: [(String, String, AIUsageWindow)] = []
        for (slot, window) in [("primary", primary), ("secondary", secondary), ("tertiary", tertiary)] {
            guard let window else { continue }
            let period: String
            switch window.windowMinutes {
            case 300: period = "5-hour"
            case 10080: period = "Weekly quota"
            case 43200: period = "Monthly quota"
            case 1440: period = "Daily quota"
            case let minutes?: period = "\(minutes) min"
            case nil: period = "Quota"
            }
            let periodAliases: Set<String>
            switch window.windowMinutes {
            case 300: periodAliases = ["5-hour", "5-hour usage", "5 hours"]
            case 10080: periodAliases = ["weekly", "weekly quota", "7-day usage"]
            case 43200: periodAliases = ["monthly", "monthly quota"]
            case 1440: periodAliases = ["daily", "daily quota"]
            default: periodAliases = []
            }
            let label = labels?[slot]?.components(separatedBy: " · ")
                .filter { !periodAliases.contains($0.lowercased()) }.joined(separator: " · ")
            let title: String
            if let label, !label.isEmpty { title = window.windowMinutes == nil ? label : "\(label) · \(period)" }
            else { title = period }
            result.append((slot, title, window))
        }
        for (index, extra) in (extraWindows ?? []).enumerated() {
            result.append(("extra-\(index)", extra.title, extra.window))
        }
        return result
    }

}

struct AIUsageLabeledWindow: Codable, Sendable {
    let title: String
    let window: AIUsageWindow
}

struct AIUsageDetail: Codable, Sendable {
    struct Row: Codable, Sendable { let label: String; let value: String; let secondaryValue: String? }
    let title: String
    let rows: [Row]
}

enum AIUsageError: Error {
    case helperMissing, loginRequired, unavailable, ownerChanged, timedOut, configurationMissing
}

/// Reads the bundled, version-pinned helper. No shell interpolation or GUI-app fallback.
struct ProviderUsageClient: Sendable {
    let helper: URL
    let owner: String
    var checkSystemOwner = false
    var provider: AIUsageProvider = .codex
    var configURL: URL? = nil
    var restoresCache = true
    var timeout: TimeInterval = 30

    static func system(provider: AIUsageProvider = .codex) -> Self {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexBarCLI")
        let config = AIUsageConfiguration.url
        let owner = provider == .codex ? systemOwner() : AIUsageConfiguration.fingerprint(provider, at: config)
        // Browser/native credentials can change outside this app. Do not restore their disk caches
        // until their active identity can be established without a remote query.
        return Self(helper: helper, owner: owner ?? "unidentified:\(UUID().uuidString)", checkSystemOwner: true,
                    provider: provider, configURL: config, restoresCache: provider == .codex)
    }

    private func currentOwner() -> String? {
        if provider == .codex { return Self.systemOwner() }
        return configURL.flatMap { AIUsageConfiguration.fingerprint(provider, at: $0) }
    }

    static func systemOwner() -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any], let account = tokens["account_id"] as? String else { return nil }
        let identity = Data((home.standardizedFileURL.path + ":" + account).utf8)
        return "system:" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    func fetch() throws -> AIUsageSnapshot {
        if checkSystemOwner {
            guard let current = currentOwner() else { throw provider == .codex ? AIUsageError.loginRequired : AIUsageError.configurationMissing }
            guard current == owner else { throw AIUsageError.ownerChanged }
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw AIUsageError.helperMissing }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output"), errors = root.appendingPathComponent("errors")
        for url in [output, errors] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AIUsageError.unavailable
            }
        }
        let stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = helper
        var arguments = ["usage", "--provider", provider.rawValue, "--format", "json", "--no-credits", "--web-timeout", "15"]
        if provider == .codex { arguments += ["--source", "oauth"] }
        process.arguments = arguments
        if let configURL {
            process.environment = try AIUsageConfiguration.readerEnvironment(provider: provider, config: configURL)
        }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let size = [output, errors].reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            if Date() >= deadline || size > 1_048_576 {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw AIUsageError.timedOut
            }
            usleep(20_000)
        }
        process.waitUntilExit()
        if checkSystemOwner, currentOwner() != owner { throw AIUsageError.ownerChanged }
        let data = try Data(contentsOf: output)
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let row = rows.first(where: { $0["provider"] as? String == provider.rawValue }) else { throw AIUsageError.unavailable }
        if let error = row["error"] {
            let description = String(describing: error).lowercased()
            if description.contains("timed out") || description.contains("timeout") { throw AIUsageError.timedOut }
            if ["401", "unauthorized", "invalid_grant", "not logged", "credentials", "authentication", "expired", "cookie missing"]
                .contains(where: description.contains) { throw AIUsageError.loginRequired }
            throw AIUsageError.unavailable
        }
        // Antigravity's offline fallback uses a zero-valued rate window for conversation count.
        // It is deliberately a non-quota snapshot and must not replace a measured quota.
        if row["source"] as? String == "offline" { throw AIUsageError.unavailable }
        guard process.terminationStatus == 0, let usage = row["usage"] as? [String: Any],
              let timestamp = usage["updatedAt"] as? String, let date = Self.date(timestamp) else { throw AIUsageError.unavailable }
        let primary = try Self.window(usage["primary"]), secondary = try Self.window(usage["secondary"])
        let tertiary = try Self.window(usage["tertiary"])
        let extras = try (usage["extraRateWindows"] as? [[String: Any]] ?? []).map { row -> AIUsageLabeledWindow in
            guard let title = row["title"] as? String, let window = try Self.window(row["window"]) else { throw AIUsageError.unavailable }
            return AIUsageLabeledWindow(title: String(title.prefix(120)), window: window)
        }
        guard primary != nil || secondary != nil || tertiary != nil || !extras.isEmpty else { throw AIUsageError.unavailable }
        let details = (usage["details"] as? [[String: Any]] ?? []).compactMap { item -> AIUsageDetail? in
            guard let title = item["title"] as? String, let rows = item["rows"] as? [[String: Any]] else { return nil }
            let values = rows.compactMap { row -> AIUsageDetail.Row? in
                guard let label = row["label"] as? String, let value = row["value"] as? String else { return nil }
                return AIUsageDetail.Row(label: String(label.prefix(120)), value: String(value.prefix(240)),
                                         secondaryValue: (row["secondaryValue"] as? String).map { String($0.prefix(240)) })
            }
            return AIUsageDetail(title: String(title.prefix(120)), rows: Array(values.prefix(30)))
        }
        var labels = (row["rateWindowLabels"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        // MiniMax maps ordered services into the three generic rate slots. The CLI's metadata
        // tertiary label defaults to Sonnet; the ordered service rows carry the actual names.
        if provider == .minimax, let services = details.first(where: { $0.title == "Quota services" }) {
            for (slot, service) in zip(["primary", "secondary", "tertiary"], services.rows) { labels[slot] = service.label }
        }
        return AIUsageSnapshot(owner: owner, source: row["source"] as? String ?? "auto", updatedAt: date,
                               primary: primary, secondary: secondary, tertiary: tertiary,
                               labels: labels, extraWindows: extras,
                               dataConfidence: usage["dataConfidence"] as? String, details: details)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private static func window(_ value: Any?) throws -> AIUsageWindow? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any], let percent = object["usedPercent"] as? Double,
              percent.isFinite, (0...100).contains(percent) else { throw AIUsageError.unavailable }
        return AIUsageWindow(usedPercent: percent, windowMinutes: object["windowMinutes"] as? Int,
                             resetsAt: (object["resetsAt"] as? String).flatMap(date))
    }
}

@MainActor
final class AIUsageStore: ObservableObject {
    enum State: Equatable { case unavailable, refreshing, ready, stale, loginRequired }
    @Published private(set) var snapshot: AIUsageSnapshot?
    @Published private(set) var state: State = .unavailable
    @Published private(set) var issue: AIUsageError?
    private var client: ProviderUsageClient
    var provider: AIUsageProvider { client.provider }
    private let cacheURL: URL

    init(client: ProviderUsageClient = .system(), cacheURL: URL? = nil) {
        self.client = client
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.whattheport.app.local.zh/ai-usage/\(client.provider.rawValue).json")
        if client.restoresCache, let data = try? Data(contentsOf: self.cacheURL), let cached = try? JSONDecoder().decode(AIUsageSnapshot.self, from: data),
           cached.owner == client.owner {
            snapshot = cached
            state = .stale
        }
    }

    func refresh() async {
        guard state != .refreshing else { return }
        if client.checkSystemOwner {
            let current = ProviderUsageClient.system(provider: client.provider)
            if current.owner != client.owner { snapshot = nil; client = current }
        }
        state = .refreshing
        issue = nil
        let client = client
        do {
            let result = try await Task.detached(priority: .utility) { try client.fetch() }.value
            if client.checkSystemOwner, ProviderUsageClient.system(provider: client.provider).owner != client.owner {
                throw AIUsageError.ownerChanged
            }
            snapshot = result
            state = .ready
            let directory = cacheURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: cacheURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            }
        } catch {
            let failure = error as? AIUsageError ?? .unavailable
            issue = failure
            switch failure {
            case .loginRequired:
                snapshot = nil
                state = .loginRequired
            case .ownerChanged:
                snapshot = nil
                state = .unavailable
            default:
                state = snapshot == nil ? .unavailable : .stale
            }
        }
    }
}
