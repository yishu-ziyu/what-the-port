import Foundation

/// An explicit acceptance command that uses the real reader/store without creating windows
/// or calling any screen-capture API. It does not export tokens or account identifiers.
@MainActor
enum AIUsageProbe {
    static func run(directory: String, provider: AIUsageProvider) -> Never {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { fputs("Cannot create usage evidence directory\n", stderr); exit(1) }
        let store = AIUsageStore(client: .system(provider: provider), cacheURL: output.appendingPathComponent("query-cache.json"))
        var completed = false
        Task { await store.refresh(); completed = true }
        let deadline = Date().addingTimeInterval(65)
        while !completed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard completed else { fputs("Usage query timed out\n", stderr); exit(1) }
        let record: [String: Any] = [
            "provider": provider.rawValue, "state": String(describing: store.state),
            "source": store.snapshot?.source ?? "none", "screenCaptureRequested": false,
            "windows": store.snapshot?.windows.map { window -> [String: Any] in
                var row: [String: Any] = ["title": window.title, "usedPercent": window.value.usedPercent,
                                          "remainingPercent": window.value.remainingPercent]
                if let minutes = window.value.windowMinutes { row["windowMinutes"] = minutes }
                if let date = window.value.resetsAt { row["resetsAt"] = ISO8601DateFormatter().string(from: date) }
                return row
            } ?? []
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]) {
            let url = output.appendingPathComponent("result.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        print("\(provider.name) query: \(store.state); windows: \(store.snapshot?.windows.count ?? 0); no screen capture")
        exit(store.state == .ready ? 0 : 1)
    }
}
