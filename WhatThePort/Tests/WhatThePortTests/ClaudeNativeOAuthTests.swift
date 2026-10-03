import Foundation
import Testing
@testable import WhatThePort

// Failures specified first: absent/malformed/expired credential, missing profile scope,
// inherited third-party route, unconstrained keychain lookup, and tokens persisted to disk.
struct ClaudeNativeOAuthTests {
    private func fixture(_ payload: String, status: Int = 0) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: root.appendingPathComponent("payload"))
        let helper = root.appendingPathComponent("security")
        try "#!/bin/sh\n[ \"$1\" = find-generic-password ] && [ \"$2\" = -s ] && [ \"$3\" = Claude\\ Code-credentials ] && [ \"$4\" = -w ] && [ \"$#\" = 4 ] || exit 99\ncat '\(root.path)/payload'\nexit \(status)\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (helper, root)
    }
    private let valid = """
    {"claudeAiOauth":{"accessToken":"sk-ant-oat-fixture","expiresAt":4102444800000,"scopes":["user:profile","user:inference"]}}
    """

    @Test func onlyTheNamedItemIsReadAndTheForeignRouteIsRemoved() throws {
        let (helper, root) = try fixture(valid)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try ClaudeNativeOAuth.read(using: helper)
        let env = credentials.queryEnvironment(base: ["ANTHROPIC_BASE_URL":"https://api.minimaxi.com", "ANTHROPIC_AUTH_TOKEN":"third-party", "ANTHROPIC_API_KEY":"third-party", "PATH":"fixture-path"])
        #expect(env["CODEXBAR_CLAUDE_OAUTH_TOKEN"] == "sk-ant-oat-fixture")
        #expect(env["CODEXBAR_CLAUDE_OAUTH_SCOPES"] == "user:profile,user:inference")
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["ANTHROPIC_BASE_URL"] == nil)
        #expect(env["PATH"] == "fixture-path")
    }

    @Test func absentOrMalformedCredentialsNeverBecomeAnEmptyToken() throws {
        for (payload, status) in [("", 44), ("{}", 0), ("not-json", 0)] {
            let (helper, root) = try fixture(payload, status: status)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(throws: AIUsageError.self) { try ClaudeNativeOAuth.read(using: helper) }
        }
    }

    @Test func expiredTokenAndMissingProfileScopeAreRejected() throws {
        for payload in [valid.replacingOccurrences(of: "4102444800000", with: "1000"), valid.replacingOccurrences(of: "user:profile", with: "user:other")] {
            let (helper, root) = try fixture(payload)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(throws: AIUsageError.self) { try ClaudeNativeOAuth.read(using: helper) }
        }
    }
}
