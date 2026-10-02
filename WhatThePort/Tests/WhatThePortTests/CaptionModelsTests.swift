import Foundation
import Testing
@testable import WhatThePort

struct CaptionModelsTests {
    @Test func readsExistingProviderStoreWithoutShellExecution() {
        let values = CaptionModels.parseEnvironment("# ignored\nexport STEPFUN_API_KEY='test=key'\nMODEL=step-3.7-flash\nIGNORED\nQUOTED=\"hello world\"\n")
        #expect(values["STEPFUN_API_KEY"] == "test=key")
        #expect(values["QUOTED"] == "hello world")
        #expect(values["MODEL"] == "step-3.7-flash")
    }
    @Test func usesOnlyTokenPlanEndpoint() throws {
        let request = try CaptionModels.request("audio/asr/sse", body: [:], key: "test")
        #expect(request.url?.absoluteString == "https://api.stepfun.com/step_plan/v1/audio/asr/sse")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
    }
    @Test func acceptsFinalTranscriptOnlyAndDoesNotDuplicateDeltas() throws {
        #expect(try CaptionModels.finalTranscript("data: {\"type\":\"transcript.text.delta\",\"delta\":\"Hello\"}") == nil)
        #expect(try CaptionModels.finalTranscript("data: {\"type\":\"transcript.text.done\",\"text\":\"Hello world.\"}") == "Hello world.")
        #expect(try CaptionModels.finalTranscript("data: [DONE]") == nil)
        #expect(try CaptionModels.finalTranscript(": heartbeat") == nil)
        #expect(throws: (any Error).self) { try CaptionModels.finalTranscript("data: {\"type\":\"error\"}") }
    }
    @Test func waveHeaderMatchesMono16kPCM() {
        let pcm = Data(repeating: 0, count: 32000)
        let wav = CaptionModels.wav(pcm)
        #expect(wav.count == 32044)
        #expect(String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .utf8) == "WAVE")
        #expect(Array(wav[24..<28]) == [0x80, 0x3e, 0, 0])
        #expect(wav.suffix(32000) == pcm)
    }
    @Test func responseErrorsRemainVisible() {
        let response = HTTPURLResponse(url: CaptionModels.base, statusCode: 402, httpVersion: nil, headerFields: nil)!
        #expect(throws: (any Error).self) { try CaptionModels.validate(response) }
    }
}
