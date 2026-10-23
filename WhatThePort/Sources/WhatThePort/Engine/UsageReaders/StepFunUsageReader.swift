import Foundation

/// Reads StepFun Step Plan quota from platform.stepfun.com.
///
/// Flow and endpoints follow CodexBar 0.68 `StepFunUsageFetcher` (the helper this replaces):
/// an Oasis-Token comes from the manual token or from Passport `RegisterDevice` + `SignInByPassword`,
/// then `QueryStepPlanRateLimit` returns remaining fractions. Tokens live only in memory.
struct StepFunUsageReader: DirectUsageReader {
    private static let provider = "StepFun"
    private static let platformURL = URL(string: "https://platform.stepfun.com")!
    private static let rateLimitURL = URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit")!
    private static let planStatusURL = URL(string: "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus")!
    private static let registerDeviceURL = URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RegisterDevice")!
    private static let signInURL = URL(string: "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/SignInByPassword")!
    /// Web id used before a token exists; afterwards the token's `device_id` claim must match it.
    private static let defaultWebID = "c8a1002d2c457e758785a9979832217c7c0b884c"
    private static let headers: [String: String] = [
        "Content-Type": "application/json",
        "oasis-appid": "10300",
        "oasis-platform": "web",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
    ]

    func read(record: [String: Any]?) async throws -> DirectReading {
        guard let record else { throw DirectFailure.notConfigured("StepFun: not configured") }
        let manualToken = Self.normalize(record["region"] as? String ?? "")
        var username = "", password = ""
        if record["cookieSource"] as? String != "manual" {
            username = (record["apiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            password = record["cookieHeader"] as? String ?? ""
        }
        let canLogin = !username.isEmpty && !password.isEmpty
        guard !manualToken.isEmpty || canLogin else {
            throw DirectFailure.notConfigured("StepFun: add a token or username and password")
        }

        // A token recovered by signing in outlives a stale manual token for this process.
        var token = await StepFunTokenCache.shared.token(for: username) ?? (manualToken.isEmpty ? nil : manualToken)
        var freshLogin = false
        if token == nil {
            token = try await Self.login(username: username, password: password)
            freshLogin = true
            await StepFunTokenCache.shared.store(token, for: username)
        }
        do {
            return try await Self.query(token: token!)
        } catch DirectFailure.loginRequired(let reason) {
            // A stale cached or manual token: sign in once more when credentials allow it.
            guard canLogin, !freshLogin else {
                await StepFunTokenCache.shared.store(nil, for: username)
                throw DirectFailure.loginRequired(reason)
            }
            let renewed = try await Self.login(username: username, password: password)
            await StepFunTokenCache.shared.store(renewed, for: username)
            return try await Self.query(token: renewed)
        }
    }

    // MARK: - Query

    private static func query(token: String) async throws -> DirectReading {
        let object = try await DirectHTTP.json(apiRequest(rateLimitURL, token: token), provider: provider)
        guard let body = object as? [String: Any] else { throw DirectFailure.invalid("StepFun: unexpected response") }
        try checkStatus(body)

        let now = Date()
        func reset(_ key: String) -> Date? {
            guard let date = DirectParse.date(body[key]), date > now else { return nil }
            return date
        }
        func used(fromLeft value: Any?) -> Double? { DirectParse.double(value).map { (1 - $0) * 100 } }

        let fiveHourReset = DirectParse.double(body["five_hour_usage_reset_time"]) ?? 0
        let weeklyReset = DirectParse.double(body["weekly_usage_reset_time"]) ?? 0
        let credit = body["plan_credit_rate_limit"] as? [String: Any]
        let hasCreditPool = DirectParse.double(credit?["subscription_credit_left_rate"]) != nil
            || DirectParse.double(credit?["topup_credit_left_rate"]) != nil
            || !((credit?["credit_buckets"] as? [Any])?.isEmpty ?? true)
        // Token Plan accounts return the rolling windows as 0 with reset "0" (no window, not "used up").
        let isCreditPlan = fiveHourReset <= 0 && weeklyReset <= 0
            && (hasCreditPool || DirectParse.double(body["plan_family"]) == 2)

        let plan = await planStatus(token: token)
        let fiveHourLeft = DirectParse.double(body["five_hour_usage_left_rate"]) ?? 0
        let weeklyLeft = DirectParse.double(body["weekly_usage_left_rate"]) ?? 0
        if !isCreditPlan, fiveHourReset <= 0, weeklyReset <= 0, fiveHourLeft <= 0, weeklyLeft <= 0 {
            // Accounts without a Step Plan get all-zero windows with reset 0, which would read as 100% used.
            if plan.answered, plan.name == nil { throw DirectFailure.notConfigured("StepFun: no active Step Plan") }
            throw DirectFailure.invalid("StepFun: plan reports no usage windows")
        }

        var reading = DirectReading(source: "web")
        if isCreditPlan {
            guard let left = creditLeftRate(credit) else { throw DirectFailure.invalid("StepFun: no credit balance") }
            let creditReset = DirectParse.date(credit?["subscription_credit_reset_time"]).flatMap { $0 > now ? $0 : nil }
            reading.primary = DirectParse.window(usedPercent: (1 - left) * 100,
                                                 minutes: creditReset == nil ? nil : 43200, resetsAt: creditReset)
            reading.labels = ["primary": "Credits"]
        } else {
            reading.primary = DirectParse.window(usedPercent: used(fromLeft: body["five_hour_usage_left_rate"]),
                                                 minutes: 300, resetsAt: reset("five_hour_usage_reset_time"))
            reading.secondary = DirectParse.window(usedPercent: used(fromLeft: body["weekly_usage_left_rate"]),
                                                   minutes: 10080, resetsAt: reset("weekly_usage_reset_time"))
            reading.labels = ["primary": "5h Window", "secondary": "Weekly Window"]
        }
        guard reading.primary != nil || reading.secondary != nil else {
            throw DirectFailure.invalid("StepFun: no usage windows in response")
        }
        if let name = plan.name {
            reading.details = [AIUsageDetail(title: "Plan", rows: [.init(label: "Step Plan", value: name, secondaryValue: nil)])]
        }
        return reading
    }

    /// `answered` is true when GetStepPlanStatus returned JSON; `name` is nil when it lists no subscription.
    /// Optional: a failure here never fails the reading.
    private static func planStatus(token: String) async -> (answered: Bool, name: String?) {
        guard let object = try? await DirectHTTP.json(apiRequest(planStatusURL, token: token), provider: provider),
              let body = object as? [String: Any] else { return (false, nil) }
        guard let subscription = body["subscription"] as? [String: Any] else { return (true, nil) }
        let name = (subscription["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (true, name.isEmpty ? "Step Plan" : name)
    }

    /// Prefers absolute bucket balances; otherwise the subscription rate, then top-up.
    private static func creditLeftRate(_ credit: [String: Any]?) -> Double? {
        guard let credit else { return nil }
        if let buckets = credit["credit_buckets"] as? [[String: Any]], !buckets.isEmpty {
            let pairs = buckets.compactMap { bucket -> (Double, Double)? in
                guard let total = DirectParse.double(bucket["credit_total"]),
                      let residual = DirectParse.double(bucket["credit_residual"]),
                      total > 0, residual >= 0, residual <= total else { return nil }
                return (total, residual)
            }
            if pairs.count == buckets.count {
                return pairs.reduce(0) { $0 + $1.1 } / pairs.reduce(0) { $0 + $1.0 }
            }
        }
        return DirectParse.double(credit["subscription_credit_left_rate"]) ?? DirectParse.double(credit["topup_credit_left_rate"])
    }

    /// StepFun answers HTTP 200 with `status != 1` for API errors. Server text is not shown to users.
    private static func checkStatus(_ body: [String: Any]) throws {
        guard DirectParse.double(body["status"]) != 1 else { return }
        let message = [body["message"], body["desc"]].compactMap { $0 as? String }.joined(separator: " ").lowercased()
        if ["auth", "token", "login", "unauthenticated", "embezzled"].contains(where: message.contains) {
            throw DirectFailure.loginRequired("StepFun: session expired")
        }
        let code = DirectParse.double(body["code"]).map { " \(Int($0))" } ?? ""
        throw DirectFailure.invalid("StepFun: API error\(code)")
    }

    private static func apiRequest(_ url: URL, token: String) -> URLRequest {
        let webID = webID(forToken: token)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(webID, forHTTPHeaderField: "oasis-webid")
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webID)", forHTTPHeaderField: "Cookie")
        return request
    }

    // MARK: - Login

    private static func login(username: String, password: String) async throws -> String {
        let ingress = try await ingressCookie()

        var register = URLRequest(url: registerDeviceURL)
        register.httpMethod = "POST"
        register.httpBody = Data("{}".utf8)
        for (key, value) in headers { register.setValue(value, forHTTPHeaderField: key) }
        register.setValue(defaultWebID, forHTTPHeaderField: "oasis-webid")
        register.setValue("INGRESSCOOKIE=\(ingress)", forHTTPHeaderField: "Cookie")
        let registerBody = try await DirectHTTP.json(register, provider: provider)
        guard let anonymous = tokenPair(registerBody) else { throw DirectFailure.transient("StepFun: device registration failed") }

        let webID = webID(forToken: anonymous)
        var signIn = URLRequest(url: signInURL)
        signIn.httpMethod = "POST"
        signIn.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        for (key, value) in headers { signIn.setValue(value, forHTTPHeaderField: key) }
        signIn.setValue(webID, forHTTPHeaderField: "oasis-webid")
        signIn.setValue("Oasis-Token=\(anonymous); Oasis-Webid=\(webID); INGRESSCOOKIE=\(ingress)", forHTTPHeaderField: "Cookie")
        let signInBody: Any
        do { signInBody = try await DirectHTTP.json(signIn, provider: provider) }
        catch DirectFailure.invalid { throw DirectFailure.loginRequired("StepFun: sign-in rejected") }
        guard let token = tokenPair(signInBody) else { throw DirectFailure.loginRequired("StepFun: sign-in rejected") }
        return token
    }

    /// The gateway sets `INGRESSCOOKIE` on the home page; Passport calls need it.
    private static func ingressCookie() async throws -> String {
        var request = URLRequest(url: platformURL)
        request.timeoutInterval = 15
        for (key, value) in headers where key != "Content-Type" { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(defaultWebID, forHTTPHeaderField: "oasis-webid")
        let response: URLResponse
        do { (_, response) = try await DirectHTTP.session.data(for: request) }
        catch { throw DirectFailure.transient("StepFun: network error") }
        guard let http = response as? HTTPURLResponse else { throw DirectFailure.transient("StepFun: no HTTP response") }
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String, let value = item.value as? String { result[key] = value }
        }
        let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: platformURL).first { $0.name == "INGRESSCOOKIE" }
        guard let value = cookie?.value, !value.isEmpty else { throw DirectFailure.transient("StepFun: login gateway unavailable") }
        return value
    }

    /// `{accessToken: {raw}, refreshToken: {raw}}` → "access...refresh", the cookie form StepFun expects.
    private static func tokenPair(_ object: Any) -> String? {
        guard let body = object as? [String: Any],
              let access = (body["accessToken"] as? [String: Any])?["raw"] as? String, !access.isEmpty else { return nil }
        guard let refresh = (body["refreshToken"] as? [String: Any])?["raw"] as? String, !refresh.isEmpty else { return access }
        return "\(access)...\(refresh)"
    }

    /// Accepts a bare token or a pasted cookie header and returns the Oasis-Token value.
    private static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "Oasis-Token=") else { return trimmed }
        return trimmed[range.upperBound...].split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The `device_id` claim of the token (refresh half first) must match `Oasis-Webid`,
    /// otherwise StepFun rejects the token as "embezzled".
    private static func webID(forToken token: String) -> String {
        for half in token.components(separatedBy: "...").reversed() {
            let parts = half.components(separatedBy: ".")
            guard parts.count >= 2 else { continue }
            var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while payload.count % 4 != 0 { payload.append("=") }
            if let data = Data(base64Encoded: payload),
               let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let deviceID = claims["device_id"] as? String, !deviceID.isEmpty { return deviceID }
        }
        return defaultWebID
    }
}

/// Signed-in tokens kept for the life of the process so each refresh does not sign in again.
/// Never written to disk.
private actor StepFunTokenCache {
    static let shared = StepFunTokenCache()
    private var tokens: [String: String] = [:]

    func token(for username: String) -> String? { tokens[username] }
    func store(_ token: String?, for username: String) { tokens[username] = token }
}
