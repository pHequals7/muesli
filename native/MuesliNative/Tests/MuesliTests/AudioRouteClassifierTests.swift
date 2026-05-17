import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("AudioRouteClassifier")
struct AudioRouteClassifierTests {
    @Test("AirPods output is headphone-like")
    func airPodsOutputIsHeadphoneLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: nil,
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("generic Bluetooth output defaults to headphone-like")
    func genericBluetoothOutputDefaultsToHeadphoneLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Wireless Audio",
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("Bluetooth speaker output is speaker-like when no input stream is exposed")
    func bluetoothSpeakerOutputIsSpeakerLikeWithoutInputStream() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Generic Output",
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: false
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("Bluetooth headset route does not depend on brand or product words")
    func bluetoothHeadsetRouteDoesNotDependOnBrandOrProductWords() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Generic Output",
                transportType: kAudioDeviceTransportTypeBluetooth,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("built-in speakers are speaker-like")
    func builtInSpeakersAreSpeakerLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "MacBook Pro Speakers",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("wired headphones are headphone-like by terminal type")
    func wiredHeadphonesAreHeadphoneLikeByTerminalType() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "External Output",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("USB headphones are headphone-like by terminal type")
    func usbHeadphonesAreHeadphoneLikeByTerminalType() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "USB Output",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("USB speakers are speaker-like by terminal type")
    func usbSpeakersAreSpeakerLikeByTerminalType() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "USB Output",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("mixed headphone and speaker terminals are speaker-like")
    func mixedHeadphoneAndSpeakerTerminalsAreSpeakerLike() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Mixed Output",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: true,
                outputTerminalTypes: [
                    kAudioStreamTerminalTypeHeadphones,
                    kAudioStreamTerminalTypeSpeaker,
                ]
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("USB headset without terminal metadata is headphone-like when input capable")
    func usbHeadsetWithoutTerminalMetadataIsHeadphoneLikeWhenInputCapable() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "USB Audio Device",
                transportType: kAudioDeviceTransportTypeUSB,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("Thunderbolt headset without terminal metadata is headphone-like when input capable")
    func thunderboltHeadsetWithoutTerminalMetadataIsHeadphoneLikeWhenInputCapable() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "Thunderbolt Audio Device",
                transportType: kAudioDeviceTransportTypeThunderbolt,
                hasOutputStreams: true,
                hasInputStreams: true
            )
        )

        #expect(route == .headphoneLike)
    }

    @Test("device names do not override transport classification")
    func deviceNamesDoNotOverrideTransportClassification() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "External Headphones",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: true,
                hasInputStreams: false,
                outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]
            )
        )

        #expect(route == .speakerLike)
    }

    @Test("devices without output streams are unknown")
    func devicesWithoutOutputStreamsAreUnknown() {
        let route = AudioRouteClassifier.outputRouteKind(
            for: AudioOutputDeviceDescription(
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                hasOutputStreams: false,
                hasInputStreams: true
            )
        )

        #expect(route == .unknown)
    }
}
