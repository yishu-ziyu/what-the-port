import Foundation

/// MiniMax Token/Coding Plan quota via `GET <host>/v1/token_plan/remains` (Bearer API key), falling
/// back to `/v1/api/openplatform/coding_plan/remains` when the first path is not served. Both paths
/// appear in the bundled CodexBar helper; both return `model_remains` with the same percentages.
/// Each service (`general`, `video`, …) has an interval window (5 h for general, 24 h for video)
/// and a weekly window. Percent comes from `*_remaining_percent`; counts are not trusted because
/// their meaning differs between the two paths.
struct MiniMaxUsageReader: DirectUsageReader {
    static let paths = ["/v1/token_plan/remains", "/v1/api/openplatform/coding_plan/remains"]

    func read(record: [String: Any]?) async throws -> DirectReading {
        guard let key = (record?["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw DirectFailure.notConfigured("MiniMax: API key not set")
        }
        let host = (record?["region"] as? String) == "cn" ? "https://api.minimaxi.com" : "https://api.minimax.io"
        var lastFailure: DirectFailure?
        for path in Self.paths {
            var request = URLRequest(url: URL(string: host + path)!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            do {
                guard let root = try await DirectHTTP.json(request, provider: "MiniMax") as? [String: Any] else {
                    throw DirectFailure.invalid("MiniMax: unexpected response shape")
                }
                return try Self.parse(root)
            } catch let failure as DirectFailure {
                // Only an unserved path (HTTP 404 and similar) is worth trying the other path for.
                guard case .invalid(let reason) = failure, reason.hasPrefix("MiniMax: HTTP 4") else { throw failure }
                lastFailure = failure
            }
        }
        throw lastFailure ?? DirectFailure.invalid("MiniMax: no quota endpoint answered")
    }

    static func parse(_ root: [String: Any], now: Date = Date()) throws -> DirectReading {
        if let base = root["base_resp"] as? [String: Any], let status = DirectParse.double(base["status_code"]), status != 0 {
            let code = Int(status)
            // 1004 is MiniMax's authentication failure; 1008 insufficient balance / no plan.
            if code == 1004 { throw DirectFailure.loginRequired("MiniMax: API status \(code) (authentication failed)") }
            throw DirectFailure.invalid("MiniMax: API status \(code)\(Self.clean(base["status_msg"] as? String).map { ": \($0)" } ?? "")")
        }
        guard let services = (root["model_remains"] ?? (root["data"] as? [String: Any])?["model_remains"]) as? [[String: Any]],
              !services.isEmpty else { throw DirectFailure.invalid("MiniMax: response has no model_remains") }

        struct Slot { let label: String; let window: AIUsageWindow; let scale: Double }
        var slots: [Slot] = []
        for (index, service) in services.enumerated() {
            let name = Self.displayName(service["model_name"] as? String) ?? "Service \(index + 1)"
            if let interval = Self.window(service, remaining: "current_interval_remaining_percent",
                                          start: "start_time", end: "end_time", fallbackMinutes: nil) {
                let label: String
                if index == 0 { label = "\(name) · \(Self.periodText(interval.windowMinutes))" } else { label = name }
                slots.append(Slot(label: label, window: interval, scale: 100))
            }
            // Only the first service's weekly window is a display slot, matching the previous helper output.
            if index == 0, let weekly = Self.window(service, remaining: "current_weekly_remaining_percent",
                                                     start: "weekly_start_time", end: "weekly_end_time", fallbackMinutes: 10080) {
                let boost = DirectParse.double(service["weekly_boost_permille"]).map { $0 / 1000 } ?? 1
                slots.append(Slot(label: "\(name) · Weekly", window: weekly, scale: 100 * boost))
            }
        }
        guard !slots.isEmpty else { throw DirectFailure.invalid("MiniMax: response has no usable quota windows") }

        let rows = slots.map { slot in
            AIUsageDetail.Row(label: slot.label,
                              value: "\(Int((slot.window.usedPercent / 100 * slot.scale).rounded())) / \(Int(slot.scale.rounded()))",
                              secondaryValue: "\(Int(slot.window.usedPercent.rounded()))% used")
        }
        var reading = DirectReading(source: "api", details: [AIUsageDetail(title: "Quota services", rows: rows)])
        for (slotName, slot) in zip(["primary", "secondary", "tertiary"], slots) {
            reading.labels[slotName] = slot.label
            switch slotName {
            case "primary": reading.primary = slot.window
            case "secondary": reading.secondary = slot.window
            default: reading.tertiary = slot.window
            }
        }
        reading.extras = slots.dropFirst(3).map { AIUsageLabeledWindow(title: $0.label, window: $0.window) }
        return reading
    }

    private static func window(_ service: [String: Any], remaining: String, start: String, end: String, fallbackMinutes: Int?) -> AIUsageWindow? {
        guard let left = DirectParse.double(service[remaining]) else { return nil }
        let startDate = Self.epochDate(service[start])
        let endDate = Self.epochDate(service[end])
        var minutes = fallbackMinutes
        if let startDate, let endDate, endDate > startDate { minutes = Int((endDate.timeIntervalSince(startDate) / 60).rounded()) }
        return DirectParse.window(usedPercent: 100 - left, minutes: minutes, resetsAt: endDate)
    }

    private static func periodText(_ minutes: Int?) -> String {
        guard let minutes else { return "Quota" }
        switch minutes {
        case 1440: return "Daily"
        case 10080: return "Weekly"
        default:
            if minutes % 60 == 0 { let hours = minutes / 60; return hours == 1 ? "1 hour" : "\(hours) hours" }
            return "\(minutes) min"
        }
    }

    private static func displayName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return String(raw.replacingOccurrences(of: "_", with: " ").prefix(40)).capitalized
    }

    private static func epochDate(_ value: Any?) -> Date? {
        guard let number = DirectParse.double(value), number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
    }

    private static func clean(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "…", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[A-Za-z0-9._\-]{20,}"#, with: "…", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\S+@\S+"#, with: "…", options: .regularExpression)
        return String(text.prefix(80))
    }
}
