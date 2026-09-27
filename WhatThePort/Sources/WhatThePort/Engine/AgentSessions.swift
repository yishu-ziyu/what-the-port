import Foundation

enum AgentKind: String {
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var resumeCommand: String {
        switch self {
        case .claudeCode: return "claude --resume"
        case .codex: return "codex resume"
        }
    }
}

struct AgentSession: Equatable {
    let kind: AgentKind
    let id: String
    let title: String?
    let transcript: URL?
    let startedAt: Date?
    /// The directory the agent was started in, used to resume it.
    let directory: String?

    var shortID: String { String(id.prefix(8)) }
}

/// Links a server to the coding-agent session that started it.
///
/// Claude Code exports `CLAUDE_CODE_SESSION_ID` to every command it runs, so a
/// server's environment identifies its session exactly. Codex sessions are
/// matched by working directory against `~/.codex/sessions`.
final class AgentSessionResolver {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var claudeCache: [String: (session: AgentSession, checkedAt: Date)] = [:]
    private var claudeTranscripts: [String: ClaudeTranscript] = [:]
    private var codexIndex: [String: AgentSession] = [:]
    private var codexIndexedAt: Date = .distantPast

    func resolve(environment: [String: String], cwd: String?, claude: Bool = true, codex: Bool = true) -> AgentSession? {
        if claude, let id = environment["CLAUDE_CODE_SESSION_ID"], !id.isEmpty {
            return claudeSession(id: id)
        }
        // A server started by Claude Code shouldn't be claimed by a Codex session in the same folder.
        guard codex, environment["CLAUDE_CODE_SESSION_ID"] == nil, let cwd else { return nil }
        refreshCodexIndexIfNeeded()
        // Walk up from the server's directory, but never match a session that was
        // started in the home folder or above; that would claim every server.
        var directory = cwd
        while directory.count > home.path.count {
            if let session = codexIndex[directory] { return session }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return nil
    }

    // MARK: - Claude Code

    private func claudeSession(id: String) -> AgentSession {
        if let cached = claudeCache[id], Date().timeIntervalSince(cached.checkedAt) < 30 {
            return cached.session
        }
        if claudeTranscripts[id] == nil, let transcript = findClaudeTranscript(id: id) {
            claudeTranscripts[id] = ClaudeTranscript(url: transcript)
        }
        claudeTranscripts[id]?.update()
        let transcript = claudeTranscripts[id]
        let session = AgentSession(kind: .claudeCode, id: id, title: transcript?.title, transcript: transcript?.url,
                                   startedAt: transcript?.created, directory: transcript?.directory)
        claudeCache[id] = (session, Date())
        return session
    }

    private func findClaudeTranscript(id: String) -> URL? {
        let projects = home.appendingPathComponent(".claude/projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let candidate = folder.appendingPathComponent("\(id).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    fileprivate static func firstPrompt(in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\"type\":\"user\"") {
            guard let object = json(line),
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? String else { continue }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("<") { continue }
            let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
            return String(firstLine.prefix(60))
        }
        return nil
    }

    fileprivate static func firstValue(of key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\"\(key)\"") {
            if let value = json(line)?[key] as? String { return value }
        }
        return nil
    }

    // MARK: - Codex

    private func refreshCodexIndexIfNeeded() {
        guard Date().timeIntervalSince(codexIndexedAt) > 60 else { return }
        codexIndexedAt = Date()

        let codex = home.appendingPathComponent(".codex")
        var titles: [String: String] = [:]
        let indexText = Self.readTail(of: codex.appendingPathComponent("session_index.jsonl"), bytes: 1024 * 1024)
        for line in indexText.split(separator: "\n") {
            if let object = Self.json(line), let id = object["id"] as? String, let name = object["thread_name"] as? String {
                titles[id] = name
            }
        }

        var index: [String: (session: AgentSession, modified: Date)] = [:]
        let sessionsRoot = codex.appendingPathComponent("sessions")
        let cutoff = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        guard let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > cutoff else { continue }
            let head = Self.readHead(of: url, bytes: 64 * 1024)
            guard let first = head.split(separator: "\n").first,
                  let object = Self.json(first),
                  let payload = object["payload"] as? [String: Any],
                  let id = payload["id"] as? String,
                  let cwd = payload["cwd"] as? String else { continue }
            if let existing = index[cwd], existing.modified > modified { continue }
            let started = (payload["timestamp"] as? String).flatMap { Self.isoFormatter.date(from: $0) }
            let session = AgentSession(kind: .codex, id: id, title: titles[id], transcript: url, startedAt: started, directory: cwd)
            index[cwd] = (session, modified)
        }
        codexIndex = index.mapValues(\.session)
    }

    // MARK: - File helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    fileprivate static func json<S: StringProtocol>(_ line: S) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    fileprivate static func readHead(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func readTail(of url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        // Drop the partial first line when we started mid-file.
        if offset > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }
}

/// Titles and details from a Claude Code transcript. Transcripts only grow, and
/// titles are appended as a session goes, so after the first read only the
/// newly appended lines are read.
struct ClaudeTranscript {
    let url: URL
    private(set) var directory: String?
    private(set) var created: Date?
    private var firstPrompt: String?
    private var customTitle: String?
    private var aiTitle: String?
    /// Bytes read so far, always ending after a complete line.
    private var offset: UInt64 = 0

    static let headBytes = 256 * 1024
    static let tailBytes = 512 * 1024

    init(url: URL) {
        self.url = url
    }

    /// The newest title the user set, else the newest generated one, else the first prompt.
    var title: String? { customTitle ?? aiTitle ?? firstPrompt }

    mutating func update() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { self = ClaudeTranscript(url: url) }
        if offset == 0 {
            let head = AgentSessionResolver.readHead(of: url, bytes: Self.headBytes)
            firstPrompt = AgentSessionResolver.firstPrompt(in: head)
            directory = AgentSessionResolver.firstValue(of: "cwd", in: head)
            created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            // Titles set early in a long session may sit in the head, before the tail window.
            if size > UInt64(Self.tailBytes) { readTitles(in: Data(head.utf8), from: 0) }
        }
        guard size > offset else { return }
        let start = max(offset, size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0)
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return }
        readTitles(in: data, from: start)
    }

    /// Reads titles from complete lines and moves `offset` past the last one, so
    /// a line still being written is read whole next time.
    private mutating func readTitles(in data: Data, from start: UInt64) {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        var lines = data[data.startIndex..<lastNewline].split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // Starting past `offset` means starting mid-line; drop that partial line.
        if start > offset, !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            let text = String(decoding: line, as: UTF8.self)
            guard text.contains("\"type\":\"custom-title\"") || text.contains("\"type\":\"ai-title\""),
                  let object = AgentSessionResolver.json(text) else { continue }
            if let custom = object["customTitle"] as? String, !custom.isEmpty { customTitle = custom }
            if let ai = object["aiTitle"] as? String, !ai.isEmpty { aiTitle = ai }
        }
        offset = max(offset, start + UInt64(lastNewline - data.startIndex + 1))
    }
}
