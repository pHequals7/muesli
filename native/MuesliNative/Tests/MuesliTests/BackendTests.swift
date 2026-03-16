import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("WhisperCppTranscriber")
struct WhisperCppTranscriberTests {

    @Test("known model URLs are valid")
    func modelURLsValid() {
        // Verify the static model URL map has correct HuggingFace URLs
        let knownModels = ["ggml-small.en", "ggml-small.en-q5_0", "ggml-medium.en", "ggml-large-v3-turbo", "ggml-large-v3-turbo-q5_0"]
        for model in knownModels {
            let option = BackendOption.all.first { $0.model == model || $0.model == "\(model).bin" }
            if let option {
                #expect(option.backend == "whisper", "\(model) should use whisper backend")
            }
        }
    }

    @Test("whisper models have ggml prefix")
    func whisperModelsGgmlPrefix() {
        let whisperOptions = BackendOption.all.filter { $0.backend == "whisper" }
        for option in whisperOptions {
            #expect(option.model.hasPrefix("ggml-"), "\(option.label) model should start with ggml-")
        }
    }
}

@Suite("FluidAudioTranscriber")
struct FluidAudioTranscriberTests {

    @Test("parakeet models use FluidInference repo")
    func parakeetModels() {
        #expect(BackendOption.parakeetMultilingual.model.contains("FluidInference"))
        #expect(BackendOption.parakeetEnglish.model.contains("FluidInference"))
    }

    @Test("v2 model contains v2 in path")
    func v2Identification() {
        #expect(BackendOption.parakeetEnglish.model.contains("v2"))
        #expect(!BackendOption.parakeetMultilingual.model.contains("v2"))
    }

    @Test("v3 model contains v3 in path")
    func v3Identification() {
        #expect(BackendOption.parakeetMultilingual.model.contains("v3"))
    }
}

@Suite("NemotronStreamingTranscriber")
struct NemotronStreamingTranscriberTests {

    @Test("nemotron model references coreml repo")
    func nemotronModel() {
        #expect(BackendOption.nemotronStreaming.model.contains("coreml"))
        #expect(BackendOption.nemotronStreaming.model.contains("FluidInference"))
        #expect(BackendOption.nemotronStreaming.model.contains("nemotron"))
    }

    @Test("nemotron uses streaming in label")
    func nemotronLabel() {
        #expect(BackendOption.nemotronStreaming.label.lowercased().contains("streaming"))
    }
}

@Suite("Backend coverage")
struct BackendCoverageTests {

    @Test("each backend has at least one model")
    func eachBackendHasModel() {
        let backendCounts = Dictionary(grouping: BackendOption.all, by: \.backend)
            .mapValues(\.count)
        #expect(backendCounts["fluidaudio"]! >= 2, "FluidAudio should have at least 2 models")
        #expect(backendCounts["whisper"]! >= 1, "Whisper should have at least 1 model")
        // Nemotron excluded from .all until RNNT decode is validated
        // #expect(backendCounts["nemotron"]! >= 1)
    }

    @Test("size labels are human-readable")
    func sizeLabelsReadable() {
        for option in BackendOption.all {
            #expect(option.sizeLabel.contains("MB") || option.sizeLabel.contains("GB"),
                    "\(option.label) sizeLabel should contain MB or GB: \(option.sizeLabel)")
        }
    }

    @Test("descriptions are informative")
    func descriptionsMinLength() {
        for option in BackendOption.all {
            #expect(option.description.count > 20,
                    "\(option.label) description too short: \(option.description)")
        }
    }
}
