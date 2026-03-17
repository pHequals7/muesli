import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("NemotronStreamState")
struct NemotronStreamStateTests {

    @available(macOS 15, *)
    @Test("makeStreamState creates zero-initialized state")
    func makeStreamStateZeroInit() async throws {
        let transcriber = NemotronStreamingTranscriber()
        // Models aren't loaded, so makeStreamState should still create valid arrays
        let state = try await transcriber.makeStreamState()

        // Verify shapes
        #expect(state.cacheChannel.shape == [1, 24, 70, 1024])
        #expect(state.cacheTime.shape == [1, 24, 1024, 8])
        #expect(state.cacheLen.shape == [1])
        #expect(state.hState.shape == [2, 1, 640])
        #expect(state.cState.shape == [2, 1, 640])

        // Verify initial token state
        #expect(state.lastToken == 0)
        #expect(state.allTokens.isEmpty)

        // Verify cache is zero
        #expect(state.cacheLen[0].intValue == 0)
    }

    @available(macOS 15, *)
    @Test("makeStreamState creates independent states")
    func independentStates() async throws {
        let transcriber = NemotronStreamingTranscriber()
        var state1 = try await transcriber.makeStreamState()
        let state2 = try await transcriber.makeStreamState()

        // Mutating one shouldn't affect the other
        state1.lastToken = 42
        state1.allTokens.append(99)

        #expect(state2.lastToken == 0)
        #expect(state2.allTokens.isEmpty)
    }

    @available(macOS 15, *)
    @Test("transcribeChunk throws when models not loaded")
    func chunkThrowsWithoutModels() async throws {
        let transcriber = NemotronStreamingTranscriber()
        var state = try await transcriber.makeStreamState()
        let samples = [Float](repeating: 0, count: 8960)

        await #expect(throws: (any Error).self) {
            try await transcriber.transcribeChunk(samples: samples, state: &state)
        }
    }
}

@Suite("StreamingDictationController")
struct StreamingDictationControllerTests {

    @available(macOS 15, *)
    @Test("controller initializes without crash")
    func initDoesNotCrash() {
        let transcriber = NemotronStreamingTranscriber()
        let _ = StreamingDictationController(transcriber: transcriber)
    }

    @available(macOS 15, *)
    @Test("stop returns empty string when not started")
    func stopWithoutStart() {
        let transcriber = NemotronStreamingTranscriber()
        let controller = StreamingDictationController(transcriber: transcriber)
        let result = controller.stop()
        #expect(result.isEmpty)
    }
}

@Suite("Delta paste logic")
struct DeltaPasteTests {

    @Test("delta from empty previous text")
    func deltaFromEmpty() {
        let fullText = "hello world"
        let previousText = ""
        let delta = String(fullText.dropFirst(previousText.count))
        #expect(delta == "hello world")
    }

    @Test("delta appends new words only")
    func deltaAppendsOnly() {
        let previousText = "hello "
        let fullText = "hello world"
        let delta = String(fullText.dropFirst(previousText.count))
        #expect(delta == "world")
    }

    @Test("delta is empty when text unchanged")
    func deltaEmptyNoChange() {
        let text = "same text"
        let delta = String(text.dropFirst(text.count))
        #expect(delta.isEmpty)
    }

    @Test("delta handles multi-chunk accumulation")
    func multiChunkDelta() {
        var previous = ""
        let chunks = ["Hello ", "Hello world ", "Hello world how ", "Hello world how are you"]

        var deltas: [String] = []
        for fullText in chunks {
            let delta = String(fullText.dropFirst(previous.count))
            if !delta.isEmpty {
                deltas.append(delta)
            }
            previous = fullText
        }

        #expect(deltas == ["Hello ", "world ", "how ", "are you"])
    }

    @Test("delta with unicode characters")
    func deltaUnicode() {
        let previousText = "café "
        let fullText = "café résumé"
        let delta = String(fullText.dropFirst(previousText.count))
        #expect(delta == "résumé")
    }
}

@Suite("TranscriptionCoordinator Nemotron accessor")
struct TranscriptionCoordinatorNemotronTests {

    @available(macOS 15, *)
    @Test("getNemotronTranscriber returns valid instance via lazy init")
    func nemotronLazyInit() async {
        let coordinator = TranscriptionCoordinator()
        let transcriber = await coordinator.getNemotronTranscriber()
        // Should always return a valid instance (lazy initialized)
        let state = try? await transcriber.makeStreamState()
        #expect(state != nil)
    }
}
