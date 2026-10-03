import Foundation
import Darwin

/// Reads one user-authorized Claude Code item. Never enumerates Keychain, refreshes credentials,
/// writes tokens to disk, or exposes raw process errors to the UI.
struct ClaudeNativeOAuth {
    let accessToken: String
    let scopes: [String]

    static func read(using executable: URL = URL(fileURLWithPath: "/usr/bin/security"), timeout: TimeInterval = 25) throws -> Self {
        let process = Process()
        let output = Pipe()
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        process.executableURL = executable
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw AIUsageError.unavailable }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: bytes.prefix(count))
                if data.count > 65_536 { stop(process); throw AIUsageError.unavailable }
                continue
            }
            if !process.isRunning { break }
            if Date() >= deadline { stop(process); throw AIUsageError.timedOut }
            usleep(20_000)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, token.hasPrefix("sk-ant-oat"),
              let scopes = oauth["scopes"] as? [String], scopes.contains("user:profile"),
              let expires = oauth["expiresAt"] as? Double, expires / 1000 > Date().timeIntervalSince1970
        else { throw AIUsageError.loginRequired }
        return Self(accessToken: token, scopes: scopes)
    }

    func queryEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        for key in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        environment["CODEXBAR_CLAUDE_OAUTH_TOKEN"] = accessToken
        environment["CODEXBAR_CLAUDE_OAUTH_SCOPES"] = scopes.joined(separator: ",")
        return environment
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
