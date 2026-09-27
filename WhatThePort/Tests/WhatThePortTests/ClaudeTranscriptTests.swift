import Foundation
import Testing
@testable import WhatThePort

struct ClaudeTranscriptTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func makeTranscript(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func readsFirstPromptThenNewestTitles() throws {
        let url = try makeTranscript(line(["type": "user", "cwd": "/tmp/project", "message": ["content": "Fix the login page"]]))
        defer { try? FileManager.default.removeItem(at: url) }
        var transcript = ClaudeTranscript(url: url)
        transcript.update()
        #expect(transcript.title == "Fix the login page")
        #expect(transcript.directory == "/tmp/project")

        try append(line(["type": "ai-title", "aiTitle": "Login fix"]) + line(["type": "ai-title", "aiTitle": "Login and signup fix"]), to: url)
        transcript.update()
        #expect(transcript.title == "Login and signup fix")

        try append(line(["type": "custom-title", "customTitle": "Auth"]) + line(["type": "ai-title", "aiTitle": "Later AI title"]), to: url)
        transcript.update()
        #expect(transcript.title == "Auth")

        try append(line(["type": "custom-title", "customTitle": "Auth v2"]), to: url)
        transcript.update()
        #expect(transcript.title == "Auth v2")
    }

    @Test func waitsForALineBeingWritten() throws {
        let url = try makeTranscript(line(["type": "user", "message": ["content": "Start"]]))
        defer { try? FileManager.default.removeItem(at: url) }
        var transcript = ClaudeTranscript(url: url)
        transcript.update()

        let title = line(["type": "custom-title", "customTitle": "Half written"])
        let cut = title.index(title.startIndex, offsetBy: 20)
        try append(String(title[..<cut]), to: url)
        transcript.update()
        #expect(transcript.title == "Start")

        try append(String(title[cut...]), to: url)
        transcript.update()
        #expect(transcript.title == "Half written")
    }

    @Test func findsEarlyTitlesInLongTranscripts() throws {
        let filler = line(["type": "assistant", "text": String(repeating: "x", count: 1000)])
        let text = line(["type": "user", "message": ["content": "Long session"]])
            + line(["type": "custom-title", "customTitle": "Early title"])
            + String(repeating: filler, count: (ClaudeTranscript.tailBytes / filler.utf8.count) + 50)
        let url = try makeTranscript(text)
        defer { try? FileManager.default.removeItem(at: url) }
        var transcript = ClaudeTranscript(url: url)
        transcript.update()
        #expect(transcript.title == "Early title")
    }
}
