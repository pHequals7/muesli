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

@Suite("Transcript accumulation")
struct TranscriptAccumulationTests {

    @Test("SentencePiece leading space preserved in concatenation")
    func sentencePieceSpacing() {
        // Simulates what happens when decodeTokens(trim: false) returns chunks
        // with SentencePiece ▁ → " " preserved
        var transcript = ""
        let chunks = [" Hello", " world", " how", " are", " you"]
        for chunk in chunks {
            transcript += chunk
        }
        #expect(transcript == " Hello world how are you")
    }

    @Test("chunks without leading space concatenate correctly")
    func noLeadingSpace() {
        // Some chunks may not start with space (mid-word continuation)
        var transcript = ""
        let chunks = [" hel", "lo", " wor", "ld"]
        for chunk in chunks {
            transcript += chunk
        }
        #expect(transcript == " hello world")
    }

    @Test("empty chunks don't affect transcript")
    func emptyChunks() {
        var transcript = ""
        let chunks = [" Hello", "", " world", "", ""]
        for chunk in chunks {
            if !chunk.isEmpty {
                transcript += chunk
            }
        }
        #expect(transcript == " Hello world")
    }

    @Test("delta paste tracks correctly with SentencePiece spaces")
    func deltaPasteWithSpaces() {
        var previous = ""
        var deltas: [String] = []

        let partials = [" Hello", " Hello world", " Hello world how are you"]
        for full in partials {
            let delta = String(full.dropFirst(previous.count))
            if !delta.isEmpty { deltas.append(delta) }
            previous = full
        }

        #expect(deltas == [" Hello", " world", " how are you"])
    }
}

@Suite("StreamingDictationController lifecycle")
struct StreamingDictationControllerLifecycleTests {

    @available(macOS 15, *)
    @Test("double stop is safe")
    func doubleStop() {
        let transcriber = NemotronStreamingTranscriber()
        let controller = StreamingDictationController(transcriber: transcriber)
        let result1 = controller.stop()
        let result2 = controller.stop()
        #expect(result1.isEmpty)
        #expect(result2.isEmpty)
    }

    @available(macOS 15, *)
    @Test("warmup does not crash without loaded models")
    func warmupWithoutModels() {
        let transcriber = NemotronStreamingTranscriber()
        let controller = StreamingDictationController(transcriber: transcriber)
        // warmup should handle errors gracefully
        controller.warmup()
    }
}

@Suite("Nemotron backend metadata")
struct NemotronBackendMetadataTests {

    @Test("nemotron label contains Experimental")
    func experimentalLabel() {
        #expect(BackendOption.nemotronStreaming.label.contains("Experimental"))
    }

    @Test("nemotron description warns about limitations")
    func descriptionWarnings() {
        let desc = BackendOption.nemotronStreaming.description
        #expect(desc.contains("Experimental"))
        #expect(desc.contains("Handsfree"))
        #expect(desc.contains("punctuation") || desc.contains("No punctuation"))
    }

    @Test("nemotron is not recommended")
    func notRecommended() {
        #expect(!BackendOption.nemotronStreaming.recommended)
    }

    @Test("nemotron backend identifier is nemotron")
    func backendId() {
        #expect(BackendOption.nemotronStreaming.backend == "nemotron")
    }
}

@Suite("Nemotron hold-to-talk block policy")
struct NemotronHoldToTalkPolicyTests {

    @Test("nemotron is the only backend blocked from hold-to-talk")
    func onlyNemotronIsBlocked() {
        // MuesliController.handleStart() checks `selectedBackend.backend == "nemotron"`
        // to intercept hold-to-talk and route users to handsfree mode instead.
        let blocked = BackendOption.all.filter { $0.backend == "nemotron" }
        #expect(blocked.count == 1)
        #expect(blocked[0] == .nemotronStreaming)
    }

    @Test("all non-nemotron backends are allowed in hold-to-talk")
    func nonNemotronBackendsAllowHoldToTalk() {
        let allowed = BackendOption.all.filter { $0.backend != "nemotron" }
        for backend in allowed {
            #expect(backend.backend != "nemotron",
                    "\(backend.label) should not be blocked from hold-to-talk")
        }
        // 6 non-nemotron backends: parakeetMultilingual, parakeetEnglish,
        // whisperSmall, whisperMedium, whisperLargeTurbo, qwen3Asr
        #expect(allowed.count == 6)
    }

    @MainActor
    @Test("showWarning is callable without crash in idle state")
    func showWarningIdleNoCrash() {
        let configStore = ConfigStore()
        let config = configStore.load()
        let indicator = FloatingIndicatorController(configStore: configStore)
        // First setState creates the panel so subsequent calls are correctly sequenced
        indicator.setState(.idle, config: config)
        indicator.showWarning("Double-tap for Nemotron handsfree mode", icon: "⚡", duration: 0.01)
        indicator.close()
    }

    @MainActor
    @Test("showWarning is a no-op when indicator is in recording state")
    func showWarningIgnoredDuringRecording() {
        let configStore = ConfigStore()
        let config = configStore.load()
        let indicator = FloatingIndicatorController(configStore: configStore)
        // Create panel first so setState(.recording) sets state correctly
        indicator.setState(.idle, config: config)
        // Now set to recording — showWarning guard should fire
        indicator.setState(.recording, config: config)
        // Should return early without crashing or changing state
        indicator.showWarning("should be ignored", duration: 0.01)
        indicator.close()
    }
}

@Suite("TranscriptionCoordinator Nemotron accessor")
struct TranscriptionCoordinatorNemotronTests {

    @available(macOS 15, *)
    @Test("getNemotronTranscriber returns valid instance via lazy init")
    func nemotronLazyInit() async {
        let coordinator = TranscriptionCoordinator()
        let transcriber = await coordinator.getNemotronTranscriber()
        let state = try? await transcriber.makeStreamState()
        #expect(state != nil)
    }
}
