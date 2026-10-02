import AppKit
import AVFoundation
import ScreenCaptureKit

/// Bounded utterances: flush at a speech pause or six seconds; never emit silence alone.
struct CaptionAudioSegments {
    private var pending = Data()
    private var voiced = false
    private var silence: Double = 0

    mutating func append(_ pcm: Data, audible: Bool) -> Data? {
        pending.append(pcm)
        voiced = voiced || audible
        silence = audible ? 0 : silence + Double(pcm.count) / 32000
        guard pending.count >= 192000 || (voiced && silence >= 0.6 && pending.count >= 32000) else { return nil }
        let result = voiced ? pending : nil
        pending = Data(); voiced = false; silence = 0
        return result
    }
}

struct CaptionSegment: Identifiable {
    let id = UUID()
    let original: String
    var language: LiveCaptions.Language = .english
    var translated: String?
    var translationError: String?
}

@MainActor
final class LiveCaptions: ObservableObject {
    static let shared = LiveCaptions()
    enum Phase { case idle, preparing, listening, stopping, failed }
    enum Language: String, CaseIterable {
        case chinese = "zh", english = "en"
        var label: String { self == .chinese ? "简体中文" : "English" }
    }
    enum Source: String, CaseIterable {
        case cloud, local
        var label: String { self == .cloud ? "StepAudio 2.5 · Step Plan" : "SenseVoice-Small · Local" }
    }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var segments: [CaptionSegment] = []
    @Published private(set) var error: String?
    @Published private(set) var permissionURL: URL?
    @Published private(set) var receivesAudio = false
    @Published private(set) var recognizing = false
    @Published var language: Language = .english
    @Published var source: Source = .cloud

    /// Offline UI snapshots use fixed text; this never starts capture or model requests.
    init(snapshotSegments: [CaptionSegment] = []) {
        segments = snapshotSegments
    }

    var isActive: Bool { phase == .preparing || phase == .listening }
    private var session: UUID?
    private var stream: SCStream?
    private var output: CaptionAudioOutput?
    private var startTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var translations: [UUID: Task<Void, Never>] = [:]

    func start() {
        guard phase == .idle || phase == .failed else { return }
        let id = UUID()
        session = id
        phase = .preparing
        error = nil
        permissionURL = nil
        segments = []
        let selectedLanguage = language
        let selectedSource = source
        startTask = Task {
            do {
                // English translation uses Step Plan even when recognition is local.
                let key = selectedSource == .cloud || selectedLanguage == .english ? try CaptionModels.credentials() : ""
                if selectedSource == .local {
                    let directory = CaptionModels.localDirectory
                    guard ["llama-funasr-sensevoice", "gguf/sensevoice-small-q8.gguf", "gguf/fsmn-vad.gguf"].allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else {
                        throw CaptionModelError.message("SenseVoice-Small is not installed at the configured local path.")
                    }
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard session == id else { return }
                guard let display = content.displays.first else { throw CaptionModelError.message("No display is available for capturing computer audio.") }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 1
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
                if #available(macOS 15, *) { config.captureMicrophone = false }
                let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(2))
                let output = CaptionAudioOutput(continuation: continuation)
                output.onAudio = { [weak self] audible in
                    Task { @MainActor in
                        guard let self, self.session == id else { return }
                        self.receivesAudio = audible
                    }
                }
                output.onError = { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.session == id else { return }
                        self.stop(message: message)
                    }
                }
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.whattheport.captions.audio"))
                self.output = output
                recognitionTask = Task {
                    do {
                        for await pcm in chunks {
                            try Task.checkCancellation()
                            guard session == id else { return }
                            recognizing = true
                            let text = selectedSource == .cloud
                                ? try await CaptionModels.transcription(pcm, language: selectedLanguage.rawValue, key: key)
                                : try await CaptionModels.localTranscription(pcm)
                            guard session == id else { return }
                            recognizing = false
                            guard !text.isEmpty else { continue }
                            let segment = CaptionSegment(original: text, language: selectedLanguage)
                            let context = segments.suffix(2).map { $0.original }.joined(separator: "\n")
                            segments.append(segment)
                            if segments.count > 6 { segments.removeFirst() }
                            if selectedLanguage == .english {
                                translations[segment.id] = Task {
                                    defer { translations[segment.id] = nil }
                                    do {
                                        let translated = try await CaptionModels.translation(text, context: context, key: key)
                                        guard session == id, let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
                                        segments[index].translated = translated
                                    } catch {
                                        guard session == id, !Task.isCancelled, let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
                                        segments[index].translationError = L10n.text(error.localizedDescription)
                                    }
                                }
                            }
                        }
                    } catch {
                        guard session == id, !Task.isCancelled else { return }
                        stop(message: L10n.text(error.localizedDescription))
                    }
                }
                try await stream.startCapture()
                guard session == id else { try? await stream.stopCapture(); return }
                self.stream = stream
                phase = .listening
            } catch {
                guard session == id else { return }
                let captureError = error as NSError
                if captureError.domain == SCStreamErrorDomain, captureError.code == -3801 {
                    permissionURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                    stop(message: L10n.text("Allow Screen & System Audio Recording in System Settings, then restart WhatThePort."))
                } else { stop(message: L10n.text(error.localizedDescription)) }
            }
        }
    }

    func stop(message: String? = nil) {
        guard phase != .stopping else { return }
        session = nil
        phase = .stopping
        receivesAudio = false
        recognizing = false
        output?.finish()
        recognitionTask?.cancel()
        let worker = recognitionTask
        recognitionTask = nil
        let translationTasks = Array(translations.values)
        translationTasks.forEach { $0.cancel() }
        let pendingStart = startTask
        startTask = nil
        let capturedStream = stream
        stream = nil
        Task {
            await pendingStart?.value
            await worker?.value
            for task in translationTasks { await task.value }
            var stopError = message
            if let capturedStream {
                do { try await capturedStream.stopCapture() }
                catch { stopError = stopError ?? error.localizedDescription }
            }
            output = nil
            error = stopError
            phase = stopError == nil ? .idle : .failed
        }
    }
}

/// Converts capture audio to 16 kHz mono PCM and emits bounded, non-overlapping utterances.
private final class CaptionAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var ended = false
    private var segments = CaptionAudioSegments()
    private var converter: AVAudioConverter?
    private var lastMeterUpdate: TimeInterval = 0
    var onAudio: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    init(continuation: AsyncStream<Data>.Continuation) { self.continuation = continuation }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        ended = true
        segments = CaptionAudioSegments()
        continuation.finish()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error.localizedDescription) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                      let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate, channels: description.mChannelsPerFrame),
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers.unsafePointer),
                      let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else { return }
                if converter?.inputFormat != format { converter = AVAudioConverter(from: format, to: target) }
                guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * 16000 / format.sampleRate + 32)) else { return }
                var supplied = false
                var conversionError: NSError?
                converter.convert(to: converted, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return pcm
                }
                if let conversionError { throw conversionError }
                guard let samples = converted.int16ChannelData?[0], converted.frameLength > 0 else { return }
                let count = Int(converted.frameLength)
                let audible = (0..<count).contains { abs(Int(samples[$0])) > 160 }
                let chunk = Data(bytes: samples, count: count * 2)
                let now = ProcessInfo.processInfo.systemUptime
                lock.lock()
                guard !ended else { lock.unlock(); return }
                if let segment = segments.append(chunk, audible: audible), case .dropped = continuation.yield(segment) {
                    onError?(L10n.text("Recognition is falling behind. Stop and restart captions; no audio was silently skipped."))
                }
                lock.unlock()
                if now - lastMeterUpdate >= 0.3 {
                    lastMeterUpdate = now
                    onAudio?(audible)
                }
            }
        } catch { onError?(error.localizedDescription) }
    }
}
