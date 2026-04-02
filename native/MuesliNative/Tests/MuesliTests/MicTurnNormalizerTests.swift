import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("MicTurnNormalizer")
struct MicTurnNormalizerTests {

    @Test("falls back to one chunk-level turn when backend timings are not meaningful")
    func fallbackChunkLevelTurn() {
        let result = SpeechTranscriptionResult(
            text: "hello world",
            segments: [SpeechSegment(start: 0, end: 0, text: "hello world")]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 4.0,
            endTime: 7.0
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 4.0)
        #expect(segments[0].end == 7.0)
        #expect(segments[0].text == "hello world")
    }

    @Test("preserves phrase-like timings after normalization")
    func preservesPhraseLikeTimings() {
        let result = SpeechTranscriptionResult(
            text: "hello world again",
            segments: [
                SpeechSegment(start: 0.8, end: 1.4, text: "hello world"),
                SpeechSegment(start: 2.0, end: 2.6, text: "again later")
            ]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 10.0,
            endTime: 14.0
        )

        #expect(segments.count == 2)
        #expect(segments[0].start == 10.8)
        #expect(segments[0].end == 11.4)
        #expect(segments[0].text == "hello world")
        #expect(segments[1].start == 12.0)
        #expect(segments[1].end == 12.6)
        #expect(segments[1].text == "again later")
    }

    @Test("collapses fragmented backend shards into one chunk-level turn")
    func collapsesFragmentedShards() {
        let result = SpeechTranscriptionResult(
            text: "this is actually one interruption",
            segments: [
                SpeechSegment(start: 0.10, end: 0.15, text: "th"),
                SpeechSegment(start: 0.16, end: 0.20, text: "is"),
                SpeechSegment(start: 0.30, end: 0.33, text: "is"),
                SpeechSegment(start: 0.40, end: 0.44, text: "ac"),
                SpeechSegment(start: 0.45, end: 0.50, text: "tual"),
                SpeechSegment(start: 0.70, end: 0.74, text: "ly")
            ]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 20.0,
            endTime: 21.0
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 20.0)
        #expect(segments[0].end == 21.0)
        #expect(segments[0].text == "this is actually one interruption")
    }
}
