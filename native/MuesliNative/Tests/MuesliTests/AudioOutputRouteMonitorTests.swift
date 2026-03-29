import CoreAudio
import Testing
@testable import MuesliNativeApp

@Suite("AudioOutputRouteMonitor")
struct AudioOutputRouteMonitorTests {

    @Test("classifies obvious headphone routes")
    func classifiesHeadphones() {
        #expect(AudioOutputRouteMonitor.classifyRoute(
            name: "Pranav's AirPods Pro",
            uid: "airpods-pro-output",
            transportType: UInt32(kAudioDeviceTransportTypeBluetooth)
        ) == .headphoneLike)

        #expect(AudioOutputRouteMonitor.classifyRoute(
            name: "External Headphones",
            uid: nil,
            transportType: UInt32(kAudioDeviceTransportTypeBuiltIn)
        ) == .headphoneLike)
    }

    @Test("defaults non-headphone routes to speaker-like")
    func defaultsToSpeakerLike() {
        #expect(AudioOutputRouteMonitor.classifyRoute(
            name: "MacBook Pro Speakers",
            uid: "built-in-speakers",
            transportType: UInt32(kAudioDeviceTransportTypeBuiltIn)
        ) == .speakerLike)

        #expect(AudioOutputRouteMonitor.classifyRoute(
            name: "Studio Display",
            uid: "display-speakers",
            transportType: UInt32(kAudioDeviceTransportTypeDisplayPort)
        ) == .speakerLike)
    }

    @Test("estimates delay from latency and buffer size")
    func estimatesDelayMs() {
        let delay = AudioOutputRouteMonitor.estimateDelayMs(
            latencyFrames: 128,
            bufferFrames: 256,
            sampleRate: 48_000
        )

        #expect(delay == 8)
    }
}
