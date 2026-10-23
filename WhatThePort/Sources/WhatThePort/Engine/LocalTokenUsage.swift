import Darwin
import Foundation

/// Token usage read only from local Claude Code / Codex session logs on this Mac.
/// No network, no credentials. Files are parsed incrementally: each call reads only
/// bytes appended since the previous call.

enum TokenAgent: String, CaseIterable, Sendable { case claude, codex }

/// `daily` uses this struct instead of a tuple so `TokenUsageSummary` stays Equatable.
struct TokenDay: Sendable, Equatable {
    let day: Date
    let tokens: [TokenAgent: Int]
}

struct TokenUsageSummary: Sendable, Equatable {
    var hourly: [[TokenAgent: Int]]   // 24 entries, index = local hour of today
    var daily: [TokenDay]             // 7 entries, oldest first, day = local start of day
    var today: [TokenAgent: Int]
    var week: [TokenAgent: Int]
    var updatedAt: Date
}

actor LocalTokenUsage {
    static let shared = LocalTokenUsage()

    /// Buckets are quarter hours since the epoch, so every real time-zone offset
    /// (including +5:45) maps cleanly onto local hours at summary time.
    private static let bucketSeconds = 900
    private static let chunkSize = 4 << 20

    private struct FileState {
        let id: Int
        let agent: TokenAgent
        var inode: UInt64
        var offset: Int64
        var size: Int64
        var mtime: TimeInterval
        var buckets: [Int: Int] = [:]
    }

    private struct DedupeEntry {
        let owner: Int
        let bucket: Int
    }

    private var files: [String: FileState] = [:]
    private var nextFileID = 0
    /// Claude (message.id, requestId) keys seen inside the window, with the file that counted them.
    private var claudeSeen: [String: DedupeEntry] = [:]

    init() {}

    func summary(now: Date = Date()) async -> TokenUsageSummary {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart.addingTimeInterval(-6 * 86_400)
        let windowBucket = Int((windowStart.timeIntervalSince1970 / Double(Self.bucketSeconds)).rounded(.down))

        refresh(windowStart: windowStart, windowBucket: windowBucket)

        // Merge per-file partial sums.
        var totals: [TokenAgent: [Int: Int]] = [:]
        for state in files.values {
            var agentTotals = totals[state.agent] ?? [:]
            for (bucket, tokens) in state.buckets where bucket >= windowBucket {
                agentTotals[bucket, default: 0] += tokens
            }
            totals[state.agent] = agentTotals
        }

        let zero = Dictionary(uniqueKeysWithValues: TokenAgent.allCases.map { ($0, 0) })
        var hourly = Array(repeating: zero, count: 24)
        var dayStarts: [Date] = []
        for offset in stride(from: -6, through: 0, by: 1) {
            dayStarts.append(calendar.date(byAdding: .day, value: offset, to: todayStart) ?? todayStart)
        }
        var dailyTokens = Array(repeating: zero, count: 7)
        var today = zero
        var week = zero

        for (agent, buckets) in totals {
            for (bucket, tokens) in buckets where tokens > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(bucket * Self.bucketSeconds))
                guard date >= windowStart, date <= now else { continue }
                let dayStart = calendar.startOfDay(for: date)
                guard let dayIndex = dayStarts.firstIndex(of: dayStart) else { continue }
                dailyTokens[dayIndex][agent, default: 0] += tokens
                week[agent, default: 0] += tokens
                if dayIndex == 6 {
                    today[agent, default: 0] += tokens
                    let hour = calendar.component(.hour, from: date)
                    if hour >= 0, hour < 24 { hourly[hour][agent, default: 0] += tokens }
                }
            }
        }

        let daily = zip(dayStarts, dailyTokens).map { TokenDay(day: $0, tokens: $1) }
        return TokenUsageSummary(hourly: hourly, daily: daily, today: today, week: week, updatedAt: now)
    }

    // MARK: - File discovery and incremental reads

    private func refresh(windowStart: Date, windowBucket: Int) {
        let windowStartSeconds = windowStart.timeIntervalSince1970
        var candidates: [(path: String, agent: TokenAgent)] = []
        for root in Self.claudeProjectRoots() {
            for project in Self.listDirectory(root) {
                let projectPath = root + "/" + project
                for name in Self.listDirectory(projectPath) where name.hasSuffix(".jsonl") {
                    candidates.append((projectPath + "/" + name, .claude))
                }
            }
        }
        let codexRoot = Self.codexSessionsRoot()
        for year in Self.listDirectory(codexRoot) where Int(year) != nil {
            let yearPath = codexRoot + "/" + year
            for month in Self.listDirectory(yearPath) where Int(month) != nil {
                let monthPath = yearPath + "/" + month
                for day in Self.listDirectory(monthPath) where Int(day) != nil {
                    let dayPath = monthPath + "/" + day
                    for name in Self.listDirectory(dayPath) where name.hasSuffix(".jsonl") {
                        candidates.append((dayPath + "/" + name, .codex))
                    }
                }
            }
        }

        var alive = Set<String>()
        for (path, agent) in candidates {
            var info = stat()
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let mtime = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
            guard mtime >= windowStartSeconds else { continue }
            alive.insert(path)
            let inode = UInt64(info.st_ino)
            let size = Int64(info.st_size)

            var state: FileState
            if let existing = files[path], existing.agent == agent {
                state = existing
                if inode != state.inode || size < state.offset {
                    resetFile(&state)
                    state.inode = inode
                } else if size == state.size, mtime == state.mtime {
                    state.buckets = state.buckets.filter { $0.key >= windowBucket }
                    files[path] = state
                    continue
                }
            } else {
                state = FileState(id: nextFileID, agent: agent, inode: inode, offset: 0, size: 0, mtime: 0)
                nextFileID += 1
            }

            if size > state.offset {
                readAppended(path: path, state: &state, upTo: size, windowBucket: windowBucket)
            }
            state.size = size
            state.mtime = mtime
            state.buckets = state.buckets.filter { $0.key >= windowBucket }
            files[path] = state
        }

        // Forget files that disappeared or fell out of the window.
        for path in files.keys where !alive.contains(path) {
            if var state = files[path] { resetFile(&state) }
            files[path] = nil
        }
        claudeSeen = claudeSeen.filter { $0.value.bucket >= windowBucket }
    }

    private func resetFile(_ state: inout FileState) {
        let owner = state.id
        if state.agent == .claude {
            claudeSeen = claudeSeen.filter { $0.value.owner != owner }
        }
        state.offset = 0
        state.size = 0
        state.mtime = 0
        state.buckets = [:]
    }

    private func readAppended(path: String, state: inout FileState, upTo size: Int64, windowBucket: Int) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard lseek(fd, off_t(state.offset), SEEK_SET) == off_t(state.offset) else { return }

        var pending = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
        var position = state.offset
        var consumed = state.offset

        while position < size {
            let want = Int(min(Int64(Self.chunkSize), size - position))
            let got = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            guard got > 0 else { break }
            position += Int64(got)
            pending.append(contentsOf: chunk[0..<got])

            let used = pending.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                var start = 0
                let count = raw.count
                while start < count,
                      let nl = memchr(base + start, 0x0A, count - start) {
                    let end = base.distance(to: UnsafeRawPointer(nl))
                    if end > start {
                        processLine(UnsafeRawBufferPointer(start: base + start, count: end - start),
                                    state: &state, windowBucket: windowBucket)
                    }
                    start = end + 1
                }
                return start
            }
            if used > 0 {
                consumed += Int64(used)
                pending.removeFirst(used)
            }
        }
        // An unterminated trailing line stays unconsumed and is re-read next time.
        state.offset = consumed
    }

    // MARK: - Line parsing

    private static let usageNeedle = Array("\"usage\"".utf8)
    private static let assistantNeedle = Array("assistant".utf8)
    private static let tokenCountNeedle = Array("token_count".utf8)

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = line.baseAddress else { return false }
        return needle.withUnsafeBytes { memmem(base, line.count, $0.baseAddress, $0.count) != nil }
    }

    private func processLine(_ line: UnsafeRawBufferPointer, state: inout FileState, windowBucket: Int) {
        switch state.agent {
        case .claude:
            guard Self.contains(line, Self.usageNeedle), Self.contains(line, Self.assistantNeedle) else { return }
            guard let obj = Self.decode(line),
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = obj["timestamp"] as? String,
                  let seconds = Self.parseTimestamp(stamp) else { return }
            let bucket = Self.bucket(for: seconds)
            guard bucket >= windowBucket else { return }
            let tokens = Self.int(usage["input_tokens"]) + Self.int(usage["output_tokens"])
                + Self.int(usage["cache_creation_input_tokens"]) + Self.int(usage["cache_read_input_tokens"])
            if let messageID = message["id"] as? String, !messageID.isEmpty {
                let requestID = obj["requestId"] as? String ?? ""
                let key = messageID + "\u{1F}" + requestID
                if claudeSeen[key] != nil { return }
                claudeSeen[key] = DedupeEntry(owner: state.id, bucket: bucket)
            }
            if tokens > 0 { state.buckets[bucket, default: 0] += tokens }

        case .codex:
            guard Self.contains(line, Self.tokenCountNeedle) else { return }
            guard let obj = Self.decode(line),
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let stamp = obj["timestamp"] as? String,
                  let seconds = Self.parseTimestamp(stamp) else { return }
            let bucket = Self.bucket(for: seconds)
            guard bucket >= windowBucket else { return }
            let tokens = Self.int(last["input_tokens"]) + Self.int(last["output_tokens"])
            if tokens > 0 { state.buckets[bucket, default: 0] += tokens }
        }
    }

    private static func decode(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        return max(0, number.intValue)
    }

    private static func bucket(for seconds: Double) -> Int {
        Int((seconds / Double(bucketSeconds)).rounded(.down))
    }

    /// Fast ISO 8601 parse (`YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]`), falling back to Foundation.
    static func parseTimestamp(_ text: String) -> Double? {
        let bytes = Array(text.utf8)
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for i in start..<(start + count) {
                let b = bytes[i]
                guard b >= 48, b <= 57 else { return nil }
                value = value * 10 + Int(b - 48)
            }
            return value
        }
        if bytes.count >= 19, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84 || bytes[10] == 32,
           bytes[13] == 58, bytes[16] == 58,
           let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
           let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2) {
            var index = 19
            var fraction = 0.0
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                var scale = 0.1
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                    fraction += Double(bytes[index] - 48) * scale
                    scale /= 10
                    index += 1
                }
            }
            var zoneOffset = 0
            if index < bytes.count {
                let sign = bytes[index]
                if sign == 90 || sign == 122 {
                    index += 1
                } else if sign == 43 || sign == 45, let zh = digits(index + 1, 2) {
                    var zm = 0
                    if index + 3 < bytes.count, bytes[index + 3] == 58 { zm = digits(index + 4, 2) ?? 0 }
                    else { zm = digits(index + 3, 2) ?? 0 }
                    zoneOffset = (zh * 3600 + zm * 60) * (sign == 43 ? 1 : -1)
                    index = bytes.count
                } else {
                    return fallbackParse(text)
                }
            }
            // Days from civil (Howard Hinnant).
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mp = (month + 9) % 12
            let doy = (153 * mp + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - zoneOffset
            return Double(seconds) + fraction
        }
        return fallbackParse(text)
    }

    private static func fallbackParse(_ text: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)?.timeIntervalSince1970
    }

    // MARK: - Paths

    private static func claudeProjectRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots = [home + "/.claude/projects"]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            for part in custom.split(separator: ",") {
                let dir = (String(part).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                let projects = (dir as NSString).appendingPathComponent("projects")
                if !roots.contains(projects) { roots.append(projects) }
            }
        }
        return roots.map { ($0 as NSString).standardizingPath }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
    }

    private static func codexSessionsRoot() -> String {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return ((custom as NSString).expandingTildeInPath as NSString).appendingPathComponent("sessions")
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.codex/sessions"
    }

    private static func listDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
