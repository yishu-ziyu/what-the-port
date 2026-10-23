import Foundation

/// Reads Claude subscription quota with Claude Code's own OAuth token, only after the user enabled it.
/// Never refreshes the token: its refresh token is single-use and refreshing would sign Claude Code out.
struct ClaudeUsageReader: DirectUsageReader {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let expiredReason = "Claude: Claude Code login expired; open Claude Code to refresh it"

    func read(record: [String: Any]?) async throws -> DirectReading {
        guard record?["source"] as? String == "oauth", record?["nativeOAuthAllowed"] as? Bool == true else {
            throw DirectFailure.notConfigured("Claude: OAuth reading not enabled")
        }
        let oauth: ClaudeNativeOAuth
        do { oauth = try ClaudeNativeOAuth.read() }
        catch AIUsageError.loginRequired { throw DirectFailure.loginRequired(Self.expiredReason) }
        catch AIUsageError.timedOut { throw DirectFailure.transient("Claude: reading Claude Code credentials timed out") }
        catch { throw DirectFailure.transient("Claude: could not read Claude Code credentials") }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: Any
        do { body = try await DirectHTTP.json(request, provider: "Claude") }
        catch DirectFailure.loginRequired { throw DirectFailure.loginRequired(Self.expiredReason) }
        var reading = try Self.reading(from: body)
        if let plan = oauth.subscriptionType?.trimmingCharacters(in: .whitespaces), !plan.isEmpty {
            reading.labels["plan"] = "Claude " + plan.capitalized
        }
        return reading
    }

    static func reading(from body: Any) throws -> DirectReading {
        guard let root = body as? [String: Any] else { throw DirectFailure.invalid("Claude: unexpected response shape") }
        // `utilization` is already a 0–100 percentage.
        func window(_ key: String, minutes: Int) -> AIUsageWindow? {
            guard let object = root[key] as? [String: Any] else { return nil }
            return DirectParse.window(usedPercent: DirectParse.double(object["utilization"]),
                                      minutes: minutes, resetsAt: DirectParse.date(object["resets_at"]))
        }

        var reading = DirectReading(source: "oauth", primary: window("five_hour", minutes: 300),
                                    secondary: window("seven_day", minutes: 10_080))
        if reading.primary != nil { reading.labels["primary"] = "Session" }
        if reading.secondary != nil { reading.labels["secondary"] = "Weekly" }

        var models = Set<String>()
        for (key, model) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            guard let value = window(key, minutes: 10_080) else { continue }
            reading.extras.append(AIUsageLabeledWindow(title: "\(model) only", window: value))
            models.insert(model.lowercased())
        }
        // Model-scoped weekly windows (e.g. Fable) only appear in the generic `limits` array.
        for case let entry as [String: Any] in root["limits"] as? [Any] ?? [] {
            guard entry["kind"] as? String == "weekly_scoped",
                  let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any] else { continue }
            let name = [model["display_name"], model["id"]].lazy
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            guard let name, !models.contains(name.lowercased()),
                  let value = DirectParse.window(usedPercent: DirectParse.double(entry["percent"]), minutes: 10_080,
                                                 resetsAt: DirectParse.date(entry["resets_at"])) else { continue }
            reading.extras.append(AIUsageLabeledWindow(title: "\(name) only", window: value))
            models.insert(name.lowercased())
        }

        guard reading.primary != nil || reading.secondary != nil || !reading.extras.isEmpty else {
            throw DirectFailure.invalid("Claude: response has no usage windows")
        }
        return reading
    }
}
