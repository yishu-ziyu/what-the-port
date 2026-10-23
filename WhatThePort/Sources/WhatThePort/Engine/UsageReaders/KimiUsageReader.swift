import Foundation

/// Kimi Code quota via `GET https://api.kimi.com/coding/v1/usages` with the stored API key.
/// The response carries `usages.limit_7d` / `usages.limit_5h` as used ratios; older shapes only
/// have the `usage` envelope (7-day) and a `limits` array (5-hour), which are used as fallback.
struct KimiUsageReader: DirectUsageReader {
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    func read(record: [String: Any]?) async throws -> DirectReading {
        guard let key = (record?["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw DirectFailure.notConfigured("Kimi: API key not set")
        }
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let root = try await DirectHTTP.json(request, provider: "Kimi") as? [String: Any] else {
            throw DirectFailure.invalid("Kimi: unexpected response shape")
        }
        return try Self.parse(root)
    }

    static func parse(_ root: [String: Any]) throws -> DirectReading {
        let usages = root["usages"] as? [String: Any]
        var weekly = ratioWindow(usages?["limit_7d"], minutes: 10080)
        var fiveHour = ratioWindow(usages?["limit_5h"], minutes: 300)

        if weekly == nil { weekly = envelopeWindow(root["usage"], minutes: 10080) }
        if fiveHour == nil, let limits = root["limits"] as? [[String: Any]] {
            for limit in limits where windowMinutes(limit["window"]) == 300 {
                if let window = envelopeWindow(limit["detail"], minutes: 300) { fiveHour = window; break }
            }
        }
        guard weekly != nil || fiveHour != nil else { throw DirectFailure.invalid("Kimi: response has no usage windows") }
        return DirectReading(source: "Kimi Code API key", primary: weekly, secondary: fiveHour,
                             labels: ["primary": "7-day usage", "secondary": "5-hour usage"])
    }

    /// `{ used_ratio: 0.0017, reset_time: "…" }` — ratio is a 0…1 fraction.
    private static func ratioWindow(_ value: Any?, minutes: Int) -> AIUsageWindow? {
        guard let object = value as? [String: Any], let ratio = DirectParse.double(object["used_ratio"]) else { return nil }
        return DirectParse.window(usedPercent: ratio * 100, minutes: minutes,
                                  resetsAt: resetDate(object["reset_time"] ?? object["resetTime"]))
    }

    /// `{ limit, used?, remaining?, resetTime }` with numbers sent as strings or numbers.
    private static func envelopeWindow(_ value: Any?, minutes: Int) -> AIUsageWindow? {
        guard let object = value as? [String: Any], let limit = DirectParse.double(object["limit"]), limit > 0 else { return nil }
        let used = DirectParse.double(object["used"]) ?? max(0, limit - (DirectParse.double(object["remaining"]) ?? limit))
        let reset = object["resetTime"] ?? object["resetAt"] ?? object["reset_time"] ?? object["reset_at"]
        return DirectParse.window(usedPercent: used / limit * 100, minutes: minutes, resetsAt: resetDate(reset))
    }

    /// `{ duration: 300, timeUnit: "TIME_UNIT_MINUTE" }` → minutes.
    private static func windowMinutes(_ value: Any?) -> Int? {
        guard let object = value as? [String: Any], let duration = DirectParse.double(object["duration"]),
              var unit = (object["timeUnit"] as? String)?.lowercased() else { return nil }
        if unit.hasPrefix("time_unit_") { unit = String(unit.dropFirst("time_unit_".count)) }
        switch unit {
        case "minute", "minutes": return Int(duration)
        case "hour", "hours": return Int(duration * 60)
        case "day", "days": return Int(duration * 1440)
        default: return nil
        }
    }

    /// ISO 8601 (fractional seconds optional) or epoch seconds/milliseconds.
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
}
