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

    @Test("missing onboarding use case defaults to dictation")
    func missingOnboardingUseCaseDefaultsToDictation() throws {
        let json = """
        {
          "schemaVersion": 3,
          "currentStep": 1,
          "userName": "Test User",
          "selectedBackendKey": "fluidaudio",
          "selectedModelKey": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
          "hotkeyKeyCode": 55,
          "hotkeyLabel": "Left Cmd"
        }
        """

        let progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))

        #expect(progress.onboardingUseCaseRawValue == OnboardingUseCase.dictation.rawValue)
    }

    @Test("meeting permissions do not block dictation step resume")
    func meetingPermissionsDoNotBlockDictationResume() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: true,
            inputMonitoring: true,
            systemAudio: false,
            screenRecording: false
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 4,
            permissions: permissions,
            dictationTestStep: 4
        )

        #expect(OnboardingPermissionGate.hasRequiredDictationPermissions(permissions))
        #expect(step == 4)
    }

    @Test("missing core permission resumes at permissions step")
    func missingCorePermissionResumesAtPermissionsStep() {
        let permissions = OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: true,
            inputMonitoring: false,
            systemAudio: true,
            screenRecording: true
        )

        let step = OnboardingPermissionGate.resumeStep(
            requestedStep: 4,
            permissions: permissions,
            dictationTestStep: 4
        )

        #expect(!OnboardingPermissionGate.hasRequiredDictationPermissions(permissions))
        #expect(step == 3)
    }
}
