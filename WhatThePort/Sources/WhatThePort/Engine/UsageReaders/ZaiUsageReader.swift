import Foundation

/// Z.ai / BigModel Coding Plan quota via `GET <host>/api/monitor/usage/quota/limit`.
/// The key goes in `Authorization` without a `Bearer` prefix (CodeBurn ZaiSubscriptionService).
/// The endpoint answers HTTP 200 even for failures and reports them as `success: false` with a
/// business `code` and `msg`, so those are turned into a specific reason.
struct ZaiUsageReader: DirectUsageReader {
    func read(record: [String: Any]?) async throws -> DirectReading {
        guard let key = (record?["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw DirectFailure.notConfigured("Z.ai: API key not set")
        }
        let host = (record?["region"] as? String) == "bigmodel-cn" ? "https://open.bigmodel.cn" : "https://api.z.ai"
        var request = URLRequest(url: URL(string: "\(host)/api/monitor/usage/quota/limit")!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        guard let root = try await DirectHTTP.json(request, provider: "Z.ai") as? [String: Any] else {
            throw DirectFailure.invalid("Z.ai: unexpected response shape")
        }
        return try Self.parse(root, secret: key)
    }

    static func parse(_ root: [String: Any], secret: String = "") throws -> DirectReading {
        let code = DirectParse.double(root["code"]).map { Int($0) }
        let message = Self.clean(root["msg"] as? String ?? root["message"] as? String, secret: secret)
        if code == 401 || code == 403 {
            throw DirectFailure.loginRequired("Z.ai: API code \(code!)\(message.map { ": \($0)" } ?? "")")
        }
        if root["success"] as? Bool == false || (code != nil && code != 200 && code != 0) {
            if let raw = root["msg"] as? String, raw.lowercased().contains("coding plan"), raw.contains("不存在") {
                throw DirectFailure.notConfigured("Z.ai: no active Coding Plan on this account (API code \(code.map(String.init) ?? "?"))")
            }
            throw DirectFailure.invalid("Z.ai: API code \(code.map(String.init) ?? "?")\(message.map { ": \($0)" } ?? "")")
        }

        let payload = (root["data"] as? [String: Any]) ?? root
        guard let limits = payload["limits"] as? [[String: Any]] else { throw DirectFailure.invalid("Z.ai: response has no limits") }

        var fiveHour: AIUsageWindow?
        var weekly: AIUsageWindow?
        var rows: [AIUsageDetail.Row] = []
        for limit in limits {
            guard let type = limit["type"] as? String, type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT",
                  let unit = DirectParse.double(limit["unit"]), let count = DirectParse.double(limit["number"]) else { continue }
            let minutes: Int
            if unit == 3, count == 5 { minutes = 300 } else if unit == 6, count == 1 { minutes = 10080 } else { continue }

            let total = DirectParse.double(limit["usage"])
            var used = DirectParse.double(limit["percentage"])
            if used == nil, let current = DirectParse.double(limit["currentValue"]), let total, total > 0 { used = current / total * 100 }
            guard let window = DirectParse.window(usedPercent: used, minutes: minutes, resetsAt: Self.resetDate(limit["nextResetTime"])) else { continue }
            if minutes == 300 { fiveHour = fiveHour ?? window } else { weekly = weekly ?? window }

            let kind = type == "CREDIT_LIMIT" ? "credit" : "token"
            let label = minutes == 300 ? "Session \(kind) quota" : "\(kind.capitalized) quota"
            var secondary: String?
            if let total {
                let remaining = DirectParse.double(limit["remaining"])
                secondary = "\(Self.number(total)) limit" + (remaining.map { " · \(Self.number($0)) remaining" } ?? "")
            }
            rows.append(AIUsageDetail.Row(label: label, value: "\(Self.percent(window.usedPercent))% used", secondaryValue: secondary))
        }
        guard fiveHour != nil || weekly != nil else { throw DirectFailure.invalid("Z.ai: response has no 5-hour or weekly limit") }
        return DirectReading(source: "api", primary: fiveHour, secondary: weekly,
                             labels: ["primary": "5-hour", "secondary": "Weekly"],
                             details: rows.isEmpty ? [] : [AIUsageDetail(title: "Quota details", rows: rows)])
    }

    /// Keeps an API message short and drops anything that looks like a key, token or id.
    private static func clean(_ text: String?, secret: String) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "…") }
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "…", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[A-Za-z0-9._\-]{20,}"#, with: "…", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\S+@\S+"#, with: "…", options: .regularExpression)
        return String(text.prefix(80))
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let number = DirectParse.double(value), number.isFinite, number > 0 {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.rounded() == rounded ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
