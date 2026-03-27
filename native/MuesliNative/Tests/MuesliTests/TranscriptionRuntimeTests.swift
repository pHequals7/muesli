import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("SpeechSegment")
struct SpeechSegmentTests {

    @Test("stores start, end, text")
    func basicConstruction() {
        let segment = SpeechSegment(start: 1.5, end: 3.0, text: "Hello world")
        #expect(segment.start == 1.5)
        #expect(segment.end == 3.0)
        #expect(segment.text == "Hello world")
    }
}

@Suite("SpeechTranscriptionResult")
struct SpeechTranscriptionResultTests {

    @Test("stores text and segments")
    func basicConstruction() {
        let result = SpeechTranscriptionResult(
            text: "Full text",
            segments: [
                SpeechSegment(start: 0, end: 1, text: "Full"),
                SpeechSegment(start: 1, end: 2, text: "text"),
            ]
        )
        #expect(result.text == "Full text")
        #expect(result.segments.count == 2)
    }

    @Test("empty result")
    func emptyResult() {
        let result = SpeechTranscriptionResult(text: "", segments: [])
        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
    }
}

@Suite("TranscriptionCoordinator routing")
struct TranscriptionCoordinatorTests {

    @Test("coordinator initializes without crash")
    func initDoesNotCrash() {
        let _ = TranscriptionCoordinator()
    }

    @Test("backend routing covers all known backends")
    func allBackendsCovered() {
        let backends = Set(BackendOption.all.map(\.backend))
        let expected: Set<String> = ["fluidaudio", "whisper", "qwen", "nemotron", "canary"]
        #expect(backends == expected, "BackendOption.all backends should match expected set")
    }
}

@Suite("TranscriptionEngineArtifactsFilter")
struct TranscriptionEngineArtifactsFilterTests {

    @Test("returns empty string for known artifact")
    func blankAudioArtifact() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[blank_audio]") == "")
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[BLANK_AUDIO]") == "")
    }

    @Test("trims surrounding whitespace before matching")
    func trailingWhitespace() {
        #expect(TranscriptionEngineArtifactsFilter.apply("  [blank_audio]  \n") == "")
    }

    @Test("passes through normal transcription unchanged")
    func normalTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("Hello world") == "Hello world")
    }

    @Test("passes through empty string unchanged")
    func emptyTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("") == "")
    }

    @Test("does not strip artifact when it appears mid-sentence")
    func midSentenceNotStripped() {
        let text = "Hello [blank_audio] world"
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == text)
    }

    @Test("strips leaked canary prompt suffix from transcript")
    func stripsCanaryPromptSuffix() {
        let text = """
        I'm actually now using the canary qwen model for dictation. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "I'm actually now using the canary qwen model for dictation."
        )
    }

    @Test("strips leaked canary prompt prefix from transcript")
    func stripsCanaryPromptPrefix() {
        let text = "Transcribe the spoken audio accurately. Testing whether this works or not."
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "Testing whether this works or not."
        )
    }

    @Test("removes pure prompt leakage entirely")
    func removesPurePromptLeakage() {
        let text = """
        Transcribe the spoken audio accurately. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == "")
    }
}
