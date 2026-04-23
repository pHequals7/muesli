import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("OnboardingProgress")
struct OnboardingProgressTests {

    @Test("missing Cohere language defaults to english")
    func missingCohereLanguageDefaultsToEnglish() throws {
        let json = """
        {
          "schemaVersion": 2,
          "currentStep": 3,
          "userName": "Test User",
          "selectedBackendKey": "cohere",
          "selectedModelKey": "phequals/cohere-transcribe-coreml-mixed-precision",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd",
          "systemAudioRequested": true
        }
        """

        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))

        #expect(progress.selectedCohereLanguageCode == CohereTranscribeLanguage.english.rawValue)
    }

    @Test("unsupported Cohere language is normalized")
    func unsupportedCohereLanguageFallsBackToEnglish() throws {
        let json = """
        {
          "schemaVersion": 3,
          "currentStep": 1,
          "userName": "Test User",
          "selectedBackendKey": "cohere",
          "selectedModelKey": "phequals/cohere-transcribe-coreml-mixed-precision",
          "selectedCohereLanguageCode": "xx",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd"
        }
        """

        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))

        #expect(progress.selectedCohereLanguageCode == CohereTranscribeLanguage.english.rawValue)
    }
}
