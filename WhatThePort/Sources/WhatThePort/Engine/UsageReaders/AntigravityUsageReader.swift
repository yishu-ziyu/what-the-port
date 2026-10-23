import Darwin
import Foundation

/// Reads Antigravity quota from its locally running language server.
///
/// Same approach as CodeBurn `AntigravitySubscriptionService` and CodexBar 0.68 `AntigravityStatusProbe`:
/// find the language server in `ps`, take `--csrf_token` from its arguments, find its listening ports,
/// then POST `RetrieveUserQuotaSummary` on 127.0.0.1. Runs one `ps` per read; ports come from libproc.
struct AntigravityUsageReader: DirectUsageReader {
    private static let provider = "Antigravity"
    private static let summaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"

    func read(record: [String: Any]?) async throws -> DirectReading {
        let servers = try Self.discoverServers()
        guard !servers.isEmpty else { throw DirectFailure.notConfigured("Antigravity: app is not running") }

        var lastFailure: DirectFailure?
        for server in servers {
            var ports = Self.listeningPorts(pid: server.pid)
            if let extensionPort = server.extensionPort, !ports.contains(extensionPort) { ports.append(extensionPort) }
            for port in ports {
                for scheme in ["https", "http"] {
                    do {
                        let body = try await Self.post(scheme: scheme, port: port, csrf: server.csrf)
                        return try Self.reading(from: body)
                    } catch let failure as DirectFailure {
                        lastFailure = failure
                    } catch {
                        continue
                    }
                }
            }
        }
        if case .invalid? = lastFailure { throw lastFailure! }
        throw DirectFailure.transient("Antigravity: local server did not answer")
    }

    // MARK: - Mapping

    /// Builds extras titled "Gemini 5-hour", "Gemini weekly", "Claude/GPT 5-hour", "Claude/GPT weekly",
    /// matching the helper's output. Primary is the most-used Gemini bucket, secondary the most-used Claude/GPT one.
    static func reading(from body: [String: Any]) throws -> DirectReading {
        if let code = body["code"], !isOK(code) { throw DirectFailure.invalid("Antigravity: server returned an error") }
        let payload = (body["response"] as? [String: Any]) ?? (body["summary"] as? [String: Any]) ?? body
        let groups = (payload["groups"] as? [[String: Any]] ?? []).enumerated().sorted {
            (groupRank($0.element), $0.offset) < (groupRank($1.element), $1.offset)
        }.map(\.element)

        let now = Date()
        var extras: [AIUsageLabeledWindow] = []
        for group in groups {
            let groupTitle = groupTitle(group)
            let buckets = (group["buckets"] as? [[String: Any]] ?? []).enumerated().sorted {
                (kind(of: $0.element).rank, $0.offset) < (kind(of: $1.element).rank, $1.offset)
            }.map(\.element)
            for bucket in buckets {
                guard bucket["disabled"] as? Bool != true,
                      let remaining = DirectParse.double(bucket["remainingFraction"])
                        ?? DirectParse.double((bucket["remaining"] as? [String: Any])?["remainingFraction"]) else { continue }
                let kind = kind(of: bucket)
                let reset = DirectParse.date(bucket["resetTime"]).flatMap { $0 > now ? $0 : nil }
                guard let window = DirectParse.window(usedPercent: (1 - remaining) * 100,
                                                      minutes: kind.minutes, resetsAt: reset) else { continue }
                extras.append(AIUsageLabeledWindow(title: "\(groupTitle) \(kind.title ?? bucketName(bucket))", window: window))
            }
        }
        guard !extras.isEmpty else { throw DirectFailure.invalid("Antigravity: no quota buckets in response") }

        func mostUsed(_ match: (String) -> Bool) -> AIUsageWindow? {
            extras.filter { match($0.title.lowercased()) }.max { $0.window.usedPercent < $1.window.usedPercent }?.window
        }
        var reading = DirectReading(source: "local server")
        reading.primary = mostUsed { $0.hasPrefix("gemini") }
        reading.secondary = mostUsed { $0.hasPrefix("claude") || $0.contains("gpt") }
        reading.labels = ["primary": "Gemini Models", "secondary": "Claude and GPT"]
        reading.extras = extras
        return reading
    }

    private struct BucketKind {
        let title: String?
        let minutes: Int?
        let rank: Int
    }

    /// Classifies a bucket by its id or name ("…-5h", "session", "weekly", …).
    private static func kind(of bucket: [String: Any]) -> BucketKind {
        let session: Set<String> = ["session", "5h", "5-hour", "five hour", "five-hour"]
        var candidates: Set<String> = []
        for raw in [bucket["bucketId"] ?? bucket["id"], bucket["displayName"] ?? bucket["name"]] {
            guard var value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .replacingOccurrences(of: "_", with: "-"), !value.isEmpty else { continue }
            candidates.insert(value)
            if value.hasSuffix(" limit") { value = String(value.dropLast(" limit".count)); candidates.insert(value) }
            for alias in session.union(["weekly"]) where value.hasSuffix("-\(alias)") { candidates.insert(alias) }
        }
        if !candidates.isDisjoint(with: session) { return BucketKind(title: "5-hour", minutes: 300, rank: 0) }
        if candidates.contains("weekly") { return BucketKind(title: "weekly", minutes: 10080, rank: 1) }
        return BucketKind(title: nil, minutes: nil, rank: 2)
    }

    private static func bucketName(_ bucket: [String: Any]) -> String {
        for key in ["displayName", "name", "bucketId", "id"] {
            if let value = (bucket[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return "Quota"
    }

    private static func groupTitle(_ group: [String: Any]) -> String {
        let name = ((group["displayName"] ?? group["name"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude/GPT" }
        return name.isEmpty ? "Quota" : name
    }

    private static func groupRank(_ group: [String: Any]) -> Int {
        switch groupTitle(group) {
        case "Gemini": return 0
        case "Claude/GPT": return 1
        default: return 2
        }
    }

    private static func isOK(_ code: Any) -> Bool {
        if let number = code as? NSNumber { return number.intValue == 0 }
        if let text = (code as? String)?.lowercased() { return text == "ok" || text == "success" || text == "0" }
        return false
    }

    // MARK: - Local request

    private static func post(scheme: String, port: Int, csrf: String?) async throws -> [String: Any] {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(summaryPath)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let csrf { request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
        let (data, response) = try await loopbackSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        return body
    }

    /// The language server serves a self-signed certificate. Trust is relaxed for 127.0.0.1 only.
    private final class LoopbackTrust: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  space.host == "127.0.0.1", let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private static let loopbackSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: LoopbackTrust(), delegateQueue: nil)
    }()

    // MARK: - Process discovery

    private struct Server {
        let pid: Int32
        let csrf: String?
        let extensionPort: Int?
        let isCLI: Bool
    }

    /// Desktop app language servers (need `--csrf_token`) first, then the `agy` CLI (needs none).
    /// IDE-extension servers are skipped: their payload lacks the weekly groups (CodeBurn).
    private static func discoverServers() throws -> [Server] {
        let output = try runPS()
        var servers: [Server] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[1])
            let lower = command.lowercased()
            let isServer = lower.range(of: #"(^|/)language[_-]server[a-z0-9_-]*(\s|$)"#, options: .regularExpression) != nil
            let isCLI = !isServer && lower.range(of: #"(^|/)(agy|antigravity[-_]cli)(\s|$)"#, options: .regularExpression) != nil
            guard isServer || isCLI else { continue }
            let csrf = flag("--csrf_token", in: command)
            if isServer {
                let isApp = lower.range(of: #"--app_data_dir[= ]"?antigravity(?![\w-])|/antigravity/|antigravity\.app/"#,
                                        options: .regularExpression) != nil
                let isIDE = lower.range(of: #"antigravity[-_ ]ide"#, options: .regularExpression) != nil
                    || lower.contains("/extensions/antigravity/bin/language_server")
                guard isApp, !isIDE, csrf != nil else { continue }
            }
            let extensionPort = flag("--extension_server_port", in: command).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            servers.append(Server(pid: pid, csrf: csrf, extensionPort: extensionPort, isCLI: isCLI))
        }
        return servers.filter { !$0.isCLI } + servers.filter(\.isCLI)
    }

    private static func runPS() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw DirectFailure.transient("Antigravity: process list unavailable") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func flag(_ name: String, in command: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: name) + #"[=\s]+(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let range = Range(match.range(at: 1), in: command) else { return nil }
        return String(command[range])
    }

    /// TCP ports the process listens on, read through libproc (no `lsof` subprocess).
    private static func listeningPorts(pid: Int32) -> [Int] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 8)
        let actual = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return [] }
        var ports: Set<Int> = []
        for descriptor in descriptors.prefix(Int(actual) / stride) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            ports.insert(Int(UInt16(bigEndian: port)))
        }
        return ports.sorted()
    }
}
