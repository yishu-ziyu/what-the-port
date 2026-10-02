import Foundation
import Testing
@testable import WhatThePort

struct CaptionAudioTests {
    @Test func silentAudioDoesNotCreateRequests() {
        var chunks = CaptionAudioSegments()
        #expect(chunks.append(Data(repeating: 0, count: 192000), audible: false) == nil)
        #expect(chunks.append(Data(repeating: 0, count: 192000), audible: false) == nil)
    }
    @Test func pauseFlushesSpeechOnceAndPreservesBytes() {
        var chunks = CaptionAudioSegments()
        let speech = Data(repeating: 1, count: 16000)
        let pause = Data(repeating: 0, count: 19200)
        #expect(chunks.append(speech, audible: true) == nil)
        #expect(chunks.append(pause, audible: false) == speech + pause)
        #expect(chunks.append(pause, audible: false) == nil)
    }
    @Test func continuousSpeechIsBoundedAndDoesNotRepeatPreviousAudio() {
        var chunks = CaptionAudioSegments()
        let first = Data(repeating: 1, count: 192000)
        let next = Data(repeating: 2, count: 192000)
        #expect(chunks.append(first, audible: true) == first)
        #expect(chunks.append(next, audible: true) == next)
    }
    @Test func translationsBelongToTheirOriginalSegment() {
        var first = CaptionSegment(original: "First sentence.")
        let second = CaptionSegment(original: "Second sentence.")
        first.translated = "第一句。"
        #expect(first.id != second.id)
        #expect(second.translated == nil)
        #expect(first.original == "First sentence.")
    }
    @Test @MainActor func changingLanguageDoesNotReinterpretOldCaptions() {
        let segment = CaptionSegment(original: "Hello.", language: .english, translated: "你好。")
        let captions = LiveCaptions(snapshotSegments: [segment])
        captions.language = .chinese
        #expect(captions.segments[0].language == .english)
        #expect(captions.segments[0].translated == "你好。")
        #expect(captions.phase == .idle)
    }

}
