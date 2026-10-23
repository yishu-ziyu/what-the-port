import Foundation

/// Reads Codex (ChatGPT sign-in) quota from chatgpt.com with the Codex CLI's own token.
/// Never refreshes or writes tokens: the Codex CLI owns rotation.
struct CodexUsageReader: DirectUsageReader {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let sessionSeconds = 18_000
    private static let weeklySeconds = 604_800

    func read(record: [String: Any]?) async throws -> DirectReading {
        let credentials = try Self.credentials()
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WhatThePort", forHTTPHeaderField: "User-Agent")
        // Without the account id the response is often a guest-shape document with no rate_limit.
        if let accountId = credentials.accountId { request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }

        let body: Any
        do { body = try await DirectHTTP.json(request, provider: "Codex") }
        catch DirectFailure.loginRequired { throw DirectFailure.loginRequired("Codex: sign in again with the codex CLI") }
        return try Self.reading(from: body)
    }

    static func reading(from body: Any, now: Date = Date()) throws -> DirectReading {
        guard let root = body as? [String: Any] else { throw DirectFailure.invalid("Codex: unexpected response shape") }
        let rateLimit = root["rate_limit"] as? [String: Any]
        let slots = [rateLimit?["primary_window"], rateLimit?["secondary_window"]]
            .map { ($0 as? [String: Any]).flatMap { window($0, now: now) } }
        guard slots.contains(where: { $0 != nil }) else { throw DirectFailure.invalid("Codex: response has no rate limit windows") }

        // Classify by window length, not slot: some plans deliver only a weekly window in primary_window.
        var session: AIUsageWindow?
        var weekly: AIUsageWindow?
        for case let window? in slots {
            switch window.windowMinutes.map({ $0 * 60 }) {
            case sessionSeconds? where session == nil: session = window
            case weeklySeconds? where weekly == nil: weekly = window
            default: break
            }
        }
        if session == nil && weekly == nil { (session, weekly) = (slots[0], slots[1]) }

        var reading = DirectReading(source: "oauth", primary: session, secondary: weekly, dataConfidence: "exact")
        if weekly != nil { reading.labels["secondary"] = "Weekly" }
        if let plan = (root["plan_type"] as? String)?.lowercased(), !plan.isEmpty {
            let names = ["plus": "ChatGPT Plus", "pro": "ChatGPT Pro", "team": "ChatGPT Team", "business": "ChatGPT Business",
                         "enterprise": "ChatGPT Enterprise", "edu": "ChatGPT Edu", "free": "ChatGPT Free"]
            reading.labels["plan"] = names[plan] ?? "ChatGPT " + plan.capitalized
        }
        return reading
    }

    private static func window(_ object: [String: Any], now: Date) -> AIUsageWindow? {
        let seconds = DirectParse.double(object["limit_window_seconds"])
        // reset_at is Unix seconds; parsed here so numeric values never go through DirectParse.date.
        let resetsAt = DirectParse.double(object["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            ?? DirectParse.double(object["reset_after_seconds"]).map { now.addingTimeInterval($0) }
        return DirectParse.window(usedPercent: DirectParse.double(object["used_percent"]),
                                  minutes: seconds.map { Int(($0 / 60).rounded()) }, resetsAt: resetsAt)
    }

    private static func credentials() throws -> (accessToken: String, accountId: String?) {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { throw DirectFailure.loginRequired("Codex: not signed in") }
        let accountId = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (token, accountId)
    }
}
