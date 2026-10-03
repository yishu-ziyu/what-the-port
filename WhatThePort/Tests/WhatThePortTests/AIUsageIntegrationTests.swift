import Foundation
import Testing
@testable import WhatThePort

/// Exercise the same executable reader and state used by the native usage page.
/// All credentials and failures here are explicit local fixtures.
@MainActor
struct AIUsageIntegrationTests {
    private func fixture(_ response: String, status: Int = 0) throws -> (ProviderUsageClient, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = root.appendingPathComponent("response.json")
        try Data(response.utf8).write(to: payload)
        let helper = root.appendingPathComponent("query")
        try "#!/bin/sh\ncat '\(payload.path)'\nexit \(status)\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (ProviderUsageClient(helper: helper, owner: "fixture-account"), root)
    }

    private let valid = """
    [{"provider":"codex","source":"oauth","usage":{"primary":null,"secondary":{"usedPercent":4,"windowMinutes":10080,"resetsAt":"2030-10-09T22:01:26Z"},"updatedAt":"2030-10-03T07:26:34Z"}}]
    """

    @Test func readsRealProcessOutputWithoutInventingMissingWindows() async throws {
        let (client, root) = try fixture(valid)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIUsageStore(client: client, cacheURL: root.appendingPathComponent("cache.json"))
        await store.refresh()
        #expect(store.snapshot?.primary == nil)
        #expect(store.snapshot?.secondary?.remainingPercent == 96)
        #expect(store.state == .ready)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache.json").path))
    }

    @Test func networkFailureKeepsOriginalMeasurementTime() async throws {
        let (client, root) = try fixture(valid)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIUsageStore(client: client, cacheURL: root.appendingPathComponent("cache.json"))
        await store.refresh()
        let date = store.snapshot?.updatedAt
        try "[]".write(to: root.appendingPathComponent("response.json"), atomically: true, encoding: .utf8)
        await store.refresh()
        #expect(store.state == .stale)
        #expect(store.snapshot?.updatedAt == date)
        #expect(store.snapshot?.secondary?.remainingPercent == 96)
    }

    @Test func authenticationFailureHidesQuotaButPreservesHistory() async throws {
        let (client, root) = try fixture(valid)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        let store = AIUsageStore(client: client, cacheURL: cache)
        await store.refresh()
        try "[{\"provider\":\"codex\",\"error\":{\"code\":401,\"message\":\"Unauthorized\"}}]"
            .write(to: root.appendingPathComponent("response.json"), atomically: true, encoding: .utf8)
        await store.refresh()
        #expect(store.state == .loginRequired)
        #expect(store.snapshot == nil)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func failedFirstReadingDoesNotBecomeZero() async throws {
        let (client, root) = try fixture("[]")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIUsageStore(client: client, cacheURL: root.appendingPathComponent("cache.json"))
        await store.refresh()
        #expect(store.state == .unavailable)
        #expect(store.snapshot == nil)
    }

    @Test func zeroIsValidAndCacheDoesNotCrossAccounts() async throws {
        let (client, root) = try fixture(valid.replacingOccurrences(of: "\"usedPercent\":4", with: "\"usedPercent\":100"))
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        let store = AIUsageStore(client: client, cacheURL: cache)
        await store.refresh()
        #expect(store.snapshot?.secondary?.remainingPercent == 0)
        let different = AIUsageStore(client: ProviderUsageClient(helper: client.helper, owner: "another-account"), cacheURL: cache)
        #expect(different.snapshot == nil)
    }
}
