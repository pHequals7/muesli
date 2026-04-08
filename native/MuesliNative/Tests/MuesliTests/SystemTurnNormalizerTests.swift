import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("SystemTurnNormalizer")
struct SystemTurnNormalizerTests {

    @Test("uses chunk text as the primary readable system transcript")
    func usesChunkText() {
        let result = SpeechTranscriptionResult(
            text: "This is a private limited entity. There would be three entities.",
            segments: [
                SpeechSegment(start: 0.0, end: 0.1, text: "This"),
                SpeechSegment(start: 0.1, end: 0.2, text: "is"),
                SpeechSegment(start: 0.2, end: 0.3, text: "a"),
                SpeechSegment(start: 0.3, end: 0.4, text: "private"),
            ]
        )

        let normalized = SystemTurnNormalizer.normalize(
            result: result,
            startTime: 10.0,
            endTime: 14.0
        )

        #expect(normalized.count == 2)
        #expect(normalized[0].text == "This is a private limited entity.")
        #expect(normalized[1].text == "There would be three entities.")
    }

    @Test("falls back to one chunk when no sentence boundaries exist")
    func fallsBackToChunkText() {
        let result = SpeechTranscriptionResult(
            text: "There would be one LLP in India right",
            segments: [
                SpeechSegment(start: 0.0, end: 0.1, text: "There"),
                SpeechSegment(start: 0.1, end: 0.2, text: "would"),
            ]
        )

        let normalized = SystemTurnNormalizer.normalize(
            result: result,
            startTime: 0,
            endTime: 3
        )

        #expect(normalized.count == 1)
        #expect(normalized[0].text == "There would be one LLP in India right")
        #expect(normalized[0].start == 0)
        #expect(normalized[0].end == 3)
    }
}
