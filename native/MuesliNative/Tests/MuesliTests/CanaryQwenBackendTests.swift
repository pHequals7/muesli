import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Canary Qwen backend")
struct CanaryQwenBackendTests {

    @Test("local override directory is accepted when complete")
    func localOverrideDirectory() async throws {
        guard let raw = ProcessInfo.processInfo.environment["MUESLI_CANARY_MODEL_DIR"], !raw.isEmpty else {
            return
        }

        let expected = URL(fileURLWithPath: raw, isDirectory: true)
        #expect(CanaryQwenModelStore.isAvailableLocally())

        let resolved = try await CanaryQwenModelStore.resolvedDirectory()
        #expect(resolved.standardizedFileURL == expected.standardizedFileURL)
    }

    @available(macOS 15, *)
    @Test("transcriber can load models from local override")
    func loadModelsFromOverride() async throws {
        guard ProcessInfo.processInfo.environment["MUESLI_CANARY_MODEL_DIR"] != nil else {
            return
        }

        let transcriber = CanaryQwenTranscriber()
        try await transcriber.loadModels()
        await transcriber.shutdown()
    }
}
