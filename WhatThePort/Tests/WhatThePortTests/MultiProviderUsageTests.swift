import Foundation
import Testing
@testable import WhatThePort

// Failure cases before implementation: wrong-provider result, invented weekly labels,
// omitted third/extra windows, estimated data treated as measured, one failure hiding peers,
// config mutation, account cache reuse and more windows than fit on one row.
@MainActor
struct MultiProviderUsageTests {
    private func fixture(provider: AIUsageProvider, response: String) throws -> (ProviderUsageClient, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("reader")
        try Data(response.utf8).write(to: root.appendingPathComponent("payload"))
        try "#!/bin/sh\ncat '\(root.path)/payload'\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (ProviderUsageClient(helper: helper, owner: "fixture", provider: provider), root)
    }

    @Test func allNineHaveIndependentEntries() {
        #expect(AIUsageProvider.allCases.count == 9)
        #expect(Set(AIUsageProvider.allCases.map(\.rawValue)).count == 9)
    }

    @Test func cursorKeepsThirdPartyAndExtraWindows() async throws {
        let payload = """
        [{"provider":"cursor","source":"web","rateWindowLabels":{"primary":"Total","secondary":"Cursor","tertiary":"Third Party"},"usage":{"updatedAt":"2030-01-01T00:00:00Z","primary":{"usedPercent":15,"windowMinutes":43200},"secondary":{"usedPercent":12,"windowMinutes":43200},"tertiary":{"usedPercent":100,"windowMinutes":43200},"extraRateWindows":[{"id":"grok","title":"Grok Bot","window":{"usedPercent":1}}]}}]
        """
        let (client, root) = try fixture(provider: .cursor, response: payload)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIUsageStore(client: client, cacheURL: root.appendingPathComponent("cache"))
        await store.refresh()
        #expect(store.state == .ready)
        #expect(store.snapshot?.windows.count == 4)
        #expect(store.snapshot?.windows[2].title.contains("Third Party") == true)
        #expect(store.snapshot?.windows[2].value.remainingPercent == 0)
        #expect(store.snapshot?.windows.last?.title == "Grok Bot")
        #expect(store.snapshot?.windows.contains(where: { $0.title == "Weekly quota" }) == false)
    }

    @Test func miniMaxUsesServiceNamesInsteadOfGenericSonnetSlot() throws {
        let (client, root) = try fixture(provider: .minimax, response: """
        [{"provider":"minimax","rateWindowLabels":{"primary":"Prompts","secondary":"Window","tertiary":"Sonnet"},"usage":{"updatedAt":"2030-01-01T00:00:00Z","primary":{"usedPercent":2,"windowMinutes":300},"secondary":{"usedPercent":6,"windowMinutes":10080},"tertiary":{"usedPercent":0,"windowMinutes":1440},"details":[{"title":"Quota services","rows":[{"label":"General · 5 hours","value":"2 / 100"},{"label":"General · Weekly","value":"9 / 150"},{"label":"Video","value":"0 / 100"}]}]}}]
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try client.fetch().windows[2].title.contains("Video"))
    }

    @Test func antigravityOfflineConversationCountCannotReplaceLiveQuota() async throws {
        let (client, root) = try fixture(provider: .antigravity, response: """
        [{"provider":"antigravity","source":"cli","usage":{"updatedAt":"2030-01-01T00:00:00Z","primary":{"usedPercent":20,"windowMinutes":10080}}}]
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AIUsageStore(client: client, cacheURL: root.appendingPathComponent("cache"))
        await store.refresh()
        let date = store.snapshot?.updatedAt
        try Data("""
        [{"provider":"antigravity","source":"offline","usage":{"updatedAt":"2030-01-02T00:00:00Z","extraRateWindows":[{"id":"antigravity-offline-conversations","title":"Offline · 71 conversations","window":{"usedPercent":0}}]}}]
        """.utf8).write(to: root.appendingPathComponent("payload"))
        await store.refresh()
        #expect(store.state == .stale)
        #expect(store.snapshot?.updatedAt == date)
        #expect(store.snapshot?.windows.first?.value.remainingPercent == 80)
    }

    @Test func localEstimateRemainsExplicit() async throws {
        let (client, root) = try fixture(provider: .opencodego, response: """
        [{"provider":"opencodego","source":"local","usage":{"updatedAt":"2030-01-01T00:00:00Z","dataConfidence":"estimated","primary":{"usedPercent":0,"windowMinutes":300}}}]
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try client.fetch()
        #expect(snapshot.dataConfidence == "estimated")
        #expect(snapshot.windows[0].value.remainingPercent == 100)
        #expect(snapshot.windows[0].title.contains("5-hour"))
    }

    @Test func wrongProviderCannotBecomeAnotherProvidersReading() throws {
        let (client, root) = try fixture(provider: .stepfun, response: """
        [{"provider":"codex","usage":{"updatedAt":"2030-01-01T00:00:00Z","primary":{"usedPercent":0}}}]
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: AIUsageError.self) { try client.fetch() }
    }

    @Test func stepFunLoginUsesItsCredentialFieldsWithoutShellInterpolation() throws {
        let (base, root) = try fixture(provider: .stepfun, response: "[]")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.json")
        try Data("{\"providers\":[{\"id\":\"stepfun\",\"apiKey\":\"fixture-user\",\"cookieHeader\":\"fixture-password\",\"cookieSource\":\"auto\"}]}".utf8).write(to: config)
        let response = "[{\"provider\":\"stepfun\",\"usage\":{\"updatedAt\":\"2030-01-01T00:00:00Z\",\"primary\":{\"usedPercent\":25,\"windowMinutes\":300}}}]"
        try "#!/bin/sh\n[ \"$STEPFUN_USERNAME\" = fixture-user ] && [ \"$STEPFUN_PASSWORD\" = fixture-password ] || exit 1\nprintf '%s' '\(response)'\n".write(to: base.helper, atomically: true, encoding: .utf8)
        let client = ProviderUsageClient(helper: base.helper, owner: "fixture", provider: .stepfun, configURL: config)
        #expect(try client.fetch().primary?.usedPercent == 25)
    }

    @Test func migrationCopiesOnlySelectedProvidersWithoutChangingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old.json"), destination = root.appendingPathComponent("new/config.json")
        let data = Data("{\"version\":1,\"providers\":[{\"id\":\"zai\",\"apiKey\":\"fixture-secret\",\"region\":\"bigmodel-cn\",\"enabled\":true},{\"id\":\"unrelated\",\"apiKey\":\"do-not-copy\"}]}".utf8)
        try data.write(to: source)
        try AIUsageConfiguration.migrate(from: source, to: destination)
        #expect(try Data(contentsOf: source) == data)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [String: Any]
        let rows = result["providers"] as! [[String: Any]]
        #expect(rows.count == 9)
        #expect(rows.contains { $0["id"] as? String == "unrelated" } == false)
        #expect(rows.first { $0["id"] as? String == "zai" }?["apiKey"] as? String == "fixture-secret")
        let original = try Data(contentsOf: destination)
        try AIUsageConfiguration.migrate(from: source, to: destination)
        #expect(try Data(contentsOf: destination) == original)
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}
