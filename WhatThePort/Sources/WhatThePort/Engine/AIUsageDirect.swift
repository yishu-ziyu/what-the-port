import Foundation

/// What a direct reader returns. The client stamps owner and time and validates it before display.
struct DirectReading: Sendable {
    var source: String
    var primary: AIUsageWindow? = nil
    var secondary: AIUsageWindow? = nil
    var tertiary: AIUsageWindow? = nil
    var labels: [String: String] = [:]
    var extras: [AIUsageLabeledWindow] = []
    var details: [AIUsageDetail] = []
    var dataConfidence: String? = nil
}

/// Failures a reader can name. `reason` is shown to the user, so it must never contain tokens or keys.
enum DirectFailure: Error, Sendable {
    case notConfigured(String)
    case loginRequired(String)
    case rateLimited(until: Date?)
    case transient(String)
    case invalid(String)

    var reason: String {
        switch self {
        case .notConfigured(let text), .loginRequired(let text), .transient(let text), .invalid(let text): return text
        case .rateLimited: return "rate limited"
        }
    }
}

/// One provider's direct query. `record` is that provider's row from providers.json (may be nil).
protocol DirectUsageReader: Sendable {
    func read(record: [String: Any]?) async throws -> DirectReading
}

enum DirectHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Sends a request and returns the decoded JSON body. Maps HTTP failures to `DirectFailure`
    /// so every reader reports login, rate-limit and server errors the same way.
    static func json(_ request: URLRequest, provider: String) async throws -> Any {
        var request = request
        request.timeoutInterval = 15
        if request.value(forHTTPHeaderField: "Accept") == nil { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw DirectFailure.transient("\(provider): request timed out") }
        catch { throw DirectFailure.transient("\(provider): network error") }
        guard let http = response as? HTTPURLResponse else { throw DirectFailure.transient("\(provider): no HTTP response") }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw DirectFailure.loginRequired("\(provider): HTTP \(http.statusCode)")
        case 429: throw DirectFailure.rateLimited(until: retryAfter(http))
        case 500...: throw DirectFailure.transient("\(provider): HTTP \(http.statusCode)")
        default: throw DirectFailure.invalid("\(provider): HTTP \(http.statusCode)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw DirectFailure.invalid("\(provider): response is not JSON") }
        return object
    }

    static func retryAfter(_ response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespaces)) { return Date().addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

enum DirectParse {
    /// Accepts ISO 8601 strings, Unix seconds or Unix milliseconds.
    static func date(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            if let number = Double(string) { return epoch(number) }
            let formatter = ISO8601DateFormatter()
            if let result = formatter.date(from: string) { return result }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: string)
        case let number as NSNumber: return epoch(number.doubleValue)
        default: return nil
        }
    }

    private static func epoch(_ number: Double) -> Date? {
        guard number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// Builds a window from a used fraction in percent, clamping tiny float noise and rejecting nonsense.
    static func window(usedPercent: Double?, minutes: Int?, resetsAt: Date?) -> AIUsageWindow? {
        guard let used = usedPercent, used.isFinite, used > -0.5, used < 100.5 else { return nil }
        return AIUsageWindow(usedPercent: min(100, max(0, used)), windowMinutes: minutes, resetsAt: resetsAt)
    }
}

enum DirectReaders {
    /// Providers with a direct reader. Others still use the bundled CodexBar helper.
    static func reader(for provider: AIUsageProvider) -> DirectUsageReader? {
        switch provider {
        case .codex: return CodexUsageReader()
        case .claude: return ClaudeUsageReader()
        case .kimi: return KimiUsageReader()
        case .zai: return ZaiUsageReader()
        case .minimax: return MiniMaxUsageReader()
        case .opencodego: return OpenCodeGoUsageReader()
        case .stepfun: return StepFunUsageReader()
        case .antigravity: return AntigravityUsageReader()
        default: return nil
        }
    }
}
