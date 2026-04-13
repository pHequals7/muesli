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
        let expected: Set<String> = ["fluidaudio", "whisper", "qwen", "nemotron", "canary", "cohere"]
        #expect(backends == expected, "BackendOption.all backends should match expected set")
    }
}

@Suite("CohereTranscribeUtils")
struct CohereTranscribeUtilsTests {

    @Test("single transcript returns unchanged")
    func singleTranscript() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts(["Hello world"])
        #expect(result == "Hello world")
    }

    @Test("empty list returns empty string")
    func emptyList() {
        #expect(CohereTranscribeUtils.mergeOverlappingTranscripts([]) == "")
    }

    @Test("no overlap joins with space")
    func noOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The quick brown fox",
            "jumped over the lazy dog",
        ])
        #expect(result == "The quick brown fox jumped over the lazy dog")
    }

    @Test("exact trigram overlap deduplicates")
    func exactOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "I went to the store and bought some milk",
            "and bought some milk then came home",
        ])
        #expect(result == "I went to the store and bought some milk then came home")
    }

    @Test("case-insensitive trigram matching")
    func caseInsensitive() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The Model Works well",
            "the model works well on device",
        ])
        #expect(result == "The Model Works well on device")
    }

    @Test("cleanTranscript strips endoftext token")
    func stripsEndOfText() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello world<|endoftext|>garbage after")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript strips special tokens")
    func stripsSpecialTokens() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello<|nospeech|> world<|pnc|>")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript trims repeated suffix")
    func trimsRepeatedSuffix() {
        // Split on ". " produces: ["First", "Second", "Third", "Fourth", "Second", "more"]
        // Position 4 "Second" matches position 1 "Second", i-j=3 ≤ 3 → truncate at position 4
        let result = CohereTranscribeUtils.cleanTranscript(
            "First. Second. Third. Fourth. Second. more text"
        )
        #expect(result == "First. Second. Third. Fourth.")
    }

    @Test("cleanTranscript passes normal text unchanged")
    func normalTextUnchanged() {
        #expect(CohereTranscribeUtils.cleanTranscript("Normal transcription text.") == "Normal transcription text.")
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

@Suite("Qwen3 post-processing output cleanup")
struct Qwen3PostProcessingOutputCleanerTests {

    @Test("removes think tags")
    func stripsThinkTags() {
        let raw = "<think>reasoning</think>Clean transcript"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "Clean transcript")
    }

    @Test("removes chat markup")
    func stripsChatMarkup() {
        let raw = "<|im_start|>assistant Hello world <|im_end|>"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "assistant Hello world")
    }

    @Test("removes leaked list-formatting instruction")
    func stripsLeakedPromptInstruction() {
        let raw = """
        If the speaker is dictating a list, such as saying "first point", "second point", or "bullet point", format each item on its own line.
        First point is ship it
        """
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "First point is ship it")
    }

    @Test("rejects assistant-style analysis output")
    func rejectsAssistantStyleAnalysisOutput() {
        let cleaned = """
        The user is asking about the system prompt.

        Analysis:
        This is a question.

        Action Plan:
        1. Answer the question.
        """
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects runaway output")
    func rejectsRunawayOutput() {
        let cleaned = String(repeating: "Remove the filler word like. ", count: 40)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }
}
