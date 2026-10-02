import Foundation

/// Personal credentials stay in the existing local provider store, never in the app bundle.
struct CaptionModels {
    static let base = URL(string: "https://api.stepfun.com/step_plan/v1/")!
    static let localDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/项目与数据/agent_audio_funasr")

    static func credentials() throws -> String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ai-providers/env.local")
        let values = parseEnvironment((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        let key = ProcessInfo.processInfo.environment["STEPFUN_API_KEY"] ?? values["STEPFUN_API_KEY"] ?? ""
        guard !key.isEmpty else { throw CaptionModelError.message("Configure STEPFUN_API_KEY in ~/.config/ai-providers/env.local.") }
        return key
    }

    static func parseEnvironment(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard !line.hasPrefix("#"), let index = line.firstIndex(of: "=") else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                value.removeFirst(); value.removeLast()
            }
            values[key] = value
        }
        return values
    }

    static func request(_ path: String, body: [String: Any], key: String) throws -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CaptionModelError.message("Invalid model response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Provider error bodies can contain request data. Never expose them or credentials.
            throw CaptionModelError.message("Step Plan request failed (HTTP \(http.statusCode)). No other provider was used.")
        }
    }

    static func transcription(_ pcm: Data, language: String, key: String) async throws -> String {
        var request = try request("audio/asr/sse", body: ["audio": ["data": pcm.base64EncodedString(), "input": [
            "transcription": ["model": "stepaudio-2.5-asr", "language": language, "enable_itn": true],
            "format": ["type": "pcm", "codec": "pcm_s16le", "rate": 16000, "bits": 16, "channel": 1]
        ]]], key: key)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validate(response)
        var texts: [String] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let text = try finalTranscript(line) { texts.append(text) }
        }
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func finalTranscript(_ line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard data != "[DONE]", let bytes = data.data(using: .utf8) else { return nil }
        guard let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return nil }
        if event["type"] as? String == "error" { throw CaptionModelError.message("ASR returned an error. No other provider was used.") }
        guard event["type"] as? String == "transcript.text.done" else { return nil }
        return event["text"] as? String
    }

    static func translation(_ text: String, context: String, key: String) async throws -> String {
        let prompt = """
        Translate the current English subtitle into natural, concise Simplified Chinese.
        Preserve product names, model names, numbers and technical terms. Do not invent or correct facts.
        Previous subtitles are context only; do not repeat or translate them. Output only the current translation.
        Context: \(context)
        """
        let request = try request("chat/completions", body: ["model": "step-3.7-flash", "reasoning_effort": "low", "max_tokens": 800,
            "messages": [["role": "system", "content": prompt], ["role": "user", "content": text]]], key: key)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        try validate(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        guard let result = message?["content"] as? String, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptionModelError.message("The translation model returned no text.")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func localTranscription(_ pcm: Data) async throws -> String {
        let directory = localDirectory
        let binary = directory.appendingPathComponent("llama-funasr-sensevoice")
        let model = directory.appendingPathComponent("gguf/sensevoice-small-q8.gguf")
        let vad = directory.appendingPathComponent("gguf/fsmn-vad.gguf")
        guard [binary, model, vad].allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CaptionModelError.message("SenseVoice-Small is not installed at the configured local path.")
        }
        let job = LocalCaptionJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try job.run(binary: binary, model: model, vad: vad, pcm: pcm) })
                }
            }
        } onCancel: { job.cancel() }
    }

    static func wav(_ pcm: Data) -> Data {
        var data = Data()
        func number<T: FixedWidthInteger>(_ n: T) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); number(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16000)); number(UInt32(32000))
        number(UInt16(2)); number(UInt16(16)); data.append(Data("data".utf8)); number(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

enum CaptionModelError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// One cancellable process per audio segment. Temporary audio is private and removed on every exit.
private final class LocalCaptionJob: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }

    func run(binary: URL, model: URL, vad: URL, pcm: Data) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("segment.wav")
        try CaptionModels.wav(pcm).write(to: audio)
        let task = Process()
        task.executableURL = binary
        task.arguments = ["-m", model.path, "--vad", vad.path, "-a", audio.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = task
        do { try task.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        let result = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard task.terminationStatus == 0 else { throw CaptionModelError.message("The local ASR process failed.") }
        let lines = (String(data: result, encoding: .utf8) ?? "").split(separator: "\n")
        return lines.last(where: { !$0.hasPrefix("[") && !$0.hasPrefix("ggml") }).map(String.init) ?? ""
    }
}
