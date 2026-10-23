import Foundation

/// OpenCode Go quota via the official `GET https://opencode.ai/zen/go/v1/usage` with a Bearer API key.
/// Mirrors TokenTracker `src/lib/opencode-go-limits.js` (`fetchOpencodeGoApiLimits`): two response
/// shapes, rolling (5 h) / weekly / monthly windows, percent given either as 0–100 or as a 0–1 fraction.
/// No local estimate fallback: a failure here is reported as a failure.
struct OpenCodeGoUsageReader: DirectUsageReader {
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    func read(record: [String: Any]?) async throws -> DirectReading {
        guard let key = (record?["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw DirectFailure.notConfigured("OpenCode Go: API key not set")
        }
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Requested directly (not through DirectHTTP.json) so a 401/403 can report the server's reason,
        // e.g. an ended subscription, instead of a bare status code.
        let data: Data, response: URLResponse
        do { (data, response) = try await DirectHTTP.session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw DirectFailure.transient("OpenCode Go: request timed out") }
        catch { throw DirectFailure.transient("OpenCode Go: network error") }
        guard let http = response as? HTTPURLResponse else { throw DirectFailure.transient("OpenCode Go: no HTTP response") }
        switch http.statusCode {
        case 200..<300: break
        case 401:
            throw DirectFailure.loginRequired("OpenCode Go: API key missing, invalid, expired, or not entitled (HTTP 401)\(Self.serverReason(data, secret: key))")
        case 403:
            throw DirectFailure.loginRequired("OpenCode Go: subscription required for this API key (HTTP 403)\(Self.serverReason(data, secret: key))")
        case 429: throw DirectFailure.rateLimited(until: DirectHTTP.retryAfter(http))
        case 500...: throw DirectFailure.transient("OpenCode Go: HTTP \(http.statusCode)")
        default: throw DirectFailure.invalid("OpenCode Go: HTTP \(http.statusCode)")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DirectFailure.invalid("OpenCode Go: response is not JSON")
        }
        return try Self.parse(root)
    }

    static func parse(_ payload: [String: Any], now: Date = Date()) throws -> DirectReading {
        let usage = payload["usage"] as? [String: Any]
        let rolling = resolve(legacy: payload["rollingUsage"], modern: usage?["rolling"] ?? payload["rolling"], minutes: 300, now: now)
        let weekly = resolve(legacy: payload["weeklyUsage"], modern: usage?["weekly"] ?? payload["weekly"], minutes: 10080, now: now)
        let monthly = resolve(legacy: payload["monthlyUsage"], modern: usage?["monthly"] ?? payload["monthly"], minutes: 43200, now: now)
        guard rolling != nil || weekly != nil || monthly != nil else {
            throw DirectFailure.invalid("OpenCode Go: response did not include any known usage windows")
        }
        return DirectReading(source: "api", primary: rolling, secondary: weekly, tertiary: monthly,
                             labels: ["primary": "5-hour", "secondary": "Weekly", "tertiary": "Monthly"],
                             dataConfidence: "exact")
    }

    /// `resolveApiWindow`: prefer the modern `{ percent, resetsAt }` object when it parses,
    /// otherwise the legacy `{ usagePercent, resetInSec }` object.
    private static func resolve(legacy: Any?, modern: Any?, minutes: Int, now: Date) -> AIUsageWindow? {
        if let modern = modern as? [String: Any] {
            let percent = first(modern, ["percent", "usagePercent", "usage_percent"])
            let resetsAt = first(modern, ["resetsAt", "resets_at", "resetAt", "reset_at"])
            if percent != nil || resetsAt != nil {
                var resetInSec: Double?
                if let value = DirectParse.double(modern["resetInSec"]) { resetInSec = value }
                else if let value = DirectParse.double(modern["reset_in_sec"]) { resetInSec = value }
                else if let string = resetsAt as? String, !string.isEmpty, let date = isoDate(string) {
                    resetInSec = max(0, (date.timeIntervalSince(now)).rounded(.down))
                }
                if let window = build(percent: percent, resetInSec: resetInSec, minutes: minutes, now: now) { return window }
            }
        }
        if let legacy = legacy as? [String: Any] {
            return build(percent: first(legacy, ["usagePercent", "percent"]),
                         resetInSec: DirectParse.double(first(legacy, ["resetInSec", "reset_in_sec"])), minutes: minutes, now: now)
        }
        return nil
    }

    /// `buildWindow` + `clampPercent`: a value strictly between 0 and 1 is a fraction; a reset is required.
    private static func build(percent: Any?, resetInSec: Double?, minutes: Int, now: Date) -> AIUsageWindow? {
        guard var value = DirectParse.double(percent), value.isFinite else { return nil }
        if value > 0, value < 1 { value *= 100 }
        value = min(100, max(0, value))
        guard let seconds = resetInSec, seconds.isFinite, seconds >= 0 else { return nil }
        return DirectParse.window(usedPercent: value, minutes: minutes, resetsAt: now.addingTimeInterval(seconds.rounded(.down)))
    }

    /// First present, non-null value among the keys (JavaScript `??` chain).
    private static func first(_ object: [String: Any], _ keys: [String]) -> Any? {
        for key in keys { if let value = object[key], !(value is NSNull) { return value } }
        return nil
    }

    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// The first sentence of the server's `error.message`, with links, ids and the key removed.
    private static func serverReason(_ data: Data, secret: String) -> String {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = root["error"] as? [String: Any], var text = error["message"] as? String else { return "" }
        text = text.replacingOccurrences(of: secret, with: "…")
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[A-Za-z0-9._\-]{20,}"#, with: "…", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\S+@\S+"#, with: "…", options: .regularExpression)
        if let end = text.range(of: ". ") { text = String(text[..<end.lowerBound]) + "." }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : ": " + String(text.prefix(100))
    }
}
