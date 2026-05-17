import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("DictationAudioRouteController")
struct DictationAudioRouteControllerTests {
    @Test("dictation prefers built-in mic for headphone output")
    func dictationPrefersBuiltInMicForHeadphoneOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.headphone-like"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == 82)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 82)
    }

    @Test("dictation preserves default input for speaker output")
    func dictationPreservesDefaultInputForSpeakerOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .speakerLike,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.speaker-like"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
    }

    @Test("dictation prefers built-in mic for ambiguous Bluetooth unknown output")
    func dictationPrefersBuiltInMicForAmbiguousBluetoothUnknownOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .unknown,
            outputIsAmbiguousBluetooth: true,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.unknown"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == 82)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == 82)
    }

    @Test("dictation preserves default input for non-Bluetooth unknown output")
    func dictationPreservesDefaultInputForNonBluetoothUnknownOutput() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .unknown,
            outputIsAmbiguousBluetooth: false,
            builtInInputDeviceID: 82
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.unknown-non-bluetooth"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
    }

    @Test("dictation falls back to default input when built-in mic is unavailable")
    func dictationFallsBackWhenBuiltInMicUnavailable() {
        let inspector = FakeCoreAudioDeviceInspector(
            defaultOutputDeviceID: 10,
            outputRouteKind: .headphoneLike,
            builtInInputDeviceID: nil
        )
        let controller = DictationAudioRouteController(
            inspector: inspector,
            queue: DispatchQueue(label: "test.dictation-audio-route.no-built-in"),
            observesDefaultOutputChanges: false
        )

        #expect(controller.preferredInputDeviceIDForDictation() == nil)
        #expect(controller.cachedPreferredInputDeviceIDForDictation() == nil)
    }
}

private final class FakeCoreAudioDeviceInspector: CoreAudioDeviceInspecting {
    var defaultOutputDeviceIDValue: AudioObjectID?
    var outputRouteKindValue: AudioOutputRouteKind
    var outputIsAmbiguousBluetoothValue: Bool
    var builtInInputDeviceIDValue: AudioObjectID?

    init(
        defaultOutputDeviceID: AudioObjectID?,
        outputRouteKind: AudioOutputRouteKind,
        outputIsAmbiguousBluetooth: Bool = false,
        builtInInputDeviceID: AudioObjectID?
    ) {
        self.defaultOutputDeviceIDValue = defaultOutputDeviceID
        self.outputRouteKindValue = outputRouteKind
        self.outputIsAmbiguousBluetoothValue = outputIsAmbiguousBluetooth
        self.builtInInputDeviceIDValue = builtInInputDeviceID
    }

    func defaultOutputDeviceID() -> AudioObjectID? {
        defaultOutputDeviceIDValue
    }

    func defaultInputDeviceID() -> AudioObjectID? {
        nil
    }

    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) -> Bool {
        false
    }

    func isDeviceAvailable(_ deviceID: AudioObjectID) -> Bool {
        true
    }

    func nominalSampleRate(for deviceID: AudioObjectID) -> Double? {
        nil
    }

    func outputRouteClassification(for deviceID: AudioObjectID) -> AudioRouteClassifier.Classification {
        AudioRouteClassifier.Classification(
            kind: outputRouteKindValue,
            isAmbiguousBluetooth: outputIsAmbiguousBluetoothValue
        )
    }

    func builtInInputDeviceID() -> AudioObjectID? {
        builtInInputDeviceIDValue
    }
}
