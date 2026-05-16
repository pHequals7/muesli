import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("DictationAudioSessionManager")
struct DictationAudioSessionManagerTests {
    @Test("arm activates warm engine without starting capture")
    func armActivatesWarmEngineWithoutStartingCapture() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.arm(source: "hotkey", duckingEnabled: true)
        harness.wait()

        #expect(harness.recorder.activateCalls == 1)
        #expect(harness.recorder.prepareCalls == 0)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.ducking.beginCalls == [true])
    }

    @Test("begin recording starts capture and reuses duplicate activation")
    func beginRecordingReusesDuplicateActivation() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.arm(source: "hotkey", duckingEnabled: true)
        harness.manager.beginRecording(mode: "prepare", duckingEnabled: true)
        harness.manager.beginRecording(mode: "start", duckingEnabled: true)
        harness.wait()

        #expect(harness.recorder.prepareCalls == 1)
        #expect(harness.recorder.startCalls == 1)
        #expect(harness.events.contains { event in
            if case .latency(let name, _) = event {
                return name == "activation_reused:start"
            }
            return false
        })
    }

    @Test("headphone route skips ducking and selects built-in mic")
    func headphoneRouteSkipsDucking() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.arm(source: "hotkey", duckingEnabled: true)
        harness.manager.beginRecording(mode: "prepare", duckingEnabled: true)
        harness.wait()

        #expect(harness.ducking.beginCalls.allSatisfy { $0 == false })
        #expect(harness.recorder.lastWarmInputDeviceID == 82)
        #expect(harness.recorder.preferredInputDeviceID == 82)
    }

    @Test("stop restores ducking and emits wav URL")
    func stopRestoresDuckingAndEmitsWavURL() {
        let harness = Harness(routeKind: .speakerLike)
        let wavURL = URL(fileURLWithPath: "/tmp/dictation.wav")
        harness.recorder.stopURL = wavURL

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: true)
        harness.wait()
        harness.manager.stop()
        harness.wait()

        #expect(harness.recorder.stopCalls == 1)
        #expect(harness.ducking.restoreCalls == 1)
        #expect(harness.route.restoreCalls == 1)
        #expect(harness.events.contains { event in
            if case .stopped(_, let url) = event {
                return url == wavURL
            }
            return false
        })
    }

    @Test("route refresh warms graph without opening mic")
    func routeRefreshWarmsGraphWithoutOpeningMic() {
        let harness = Harness(routeKind: .headphoneLike, preferredInputDeviceID: 82)

        harness.manager.refreshRoute(reason: "route-change", canWarmUp: true)
        harness.wait()

        #expect(harness.route.refreshCalls == 1)
        #expect(harness.recorder.warmUpCalls == 1)
        #expect(harness.recorder.startCalls == 0)
        #expect(harness.recorder.activateCalls == 0)
    }

    @Test("recorder callbacks emit stream active, speech detected, and no audio timeout")
    func recorderCallbacksEmitAudioStateEvents() {
        let harness = Harness(routeKind: .speakerLike)

        harness.manager.beginRecording(mode: "toggle", duckingEnabled: false)
        harness.wait()
        let firstBufferAt = Date()
        harness.recorder.onFirstCapturedAudioBuffer?(firstBufferAt)
        harness.recorder.onFirstSpeechDetected?(firstBufferAt.addingTimeInterval(0.1))
        harness.recorder.onNoAudioTimeout?(firstBufferAt.addingTimeInterval(1.5))
        harness.wait()

        #expect(harness.events.contains { if case .streamActive = $0 { return true }; return false })
        #expect(harness.events.contains { if case .speechDetected = $0 { return true }; return false })
        #expect(harness.events.contains { if case .noAudioTimeout = $0 { return true }; return false })
    }
}

private final class Harness {
    let recorder = FakeDictationRecorder()
    let ducking = FakeDuckingManager()
    let route: FakeDictationRoute
    let managerQueue = DispatchQueue(label: "test.dictation-session.manager")
    let eventQueue = DispatchQueue(label: "test.dictation-session.events")
    var events: [DictationAudioSessionEvent] = []
    lazy var manager: DictationAudioSessionManager = {
        let manager = DictationAudioSessionManager(
            recorder: recorder,
            duckingController: ducking,
            routingController: route,
            queue: managerQueue,
            eventQueue: eventQueue
        )
        manager.onEvent = { [weak self] event in
            self?.events.append(event)
        }
        return manager
    }()

    init(routeKind: AudioOutputRouteKind, preferredInputDeviceID: AudioObjectID? = nil) {
        self.route = FakeDictationRoute(
            routeKind: routeKind,
            preferredInputDeviceID: preferredInputDeviceID
        )
    }

    func wait() {
        managerQueue.sync {}
        eventQueue.sync {}
    }
}

private final class FakeDictationRecorder: DictationAudioRecording {
    var preferredInputDeviceID: AudioObjectID?
    var keepsAudioGraphWarm = false
    var onFirstCapturedAudioBuffer: ((Date) -> Void)?
    var onFirstSpeechDetected: ((Date) -> Void)?
    var onNoAudioTimeout: ((Date) -> Void)?

    var prepareCalls = 0
    var warmUpCalls = 0
    var activateCalls = 0
    var coolDownCalls = 0
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var stopURL: URL?
    var lastWarmInputDeviceID: AudioObjectID?

    func prepare() throws {
        prepareCalls += 1
    }

    func warmUp(preferredInputDeviceID: AudioObjectID?) throws {
        warmUpCalls += 1
        lastWarmInputDeviceID = preferredInputDeviceID
    }

    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws {
        activateCalls += 1
        lastWarmInputDeviceID = preferredInputDeviceID
    }

    func coolDown() {
        coolDownCalls += 1
    }

    func start() throws {
        startCalls += 1
    }

    func stop() -> URL? {
        stopCalls += 1
        return stopURL
    }

    func cancel() {
        cancelCalls += 1
    }

    func currentPower() -> Float {
        -24
    }
}

private final class FakeDuckingManager: AudioDuckingManaging {
    var beginCalls: [Bool] = []
    var ensureCalls = 0
    var restoreCalls = 0

    func beginDictationDucking(enabled: Bool) {
        beginCalls.append(enabled)
    }

    func ensureCurrentDefaultDucked() {
        ensureCalls += 1
    }

    func restoreDictationDucking() {
        restoreCalls += 1
    }
}

private final class FakeDictationRoute: DictationAudioRouting {
    var onPreferredInputDeviceChanged: ((AudioObjectID?) -> Void)?
    var routeKind: AudioOutputRouteKind
    var preferredInputDeviceID: AudioObjectID?
    var refreshCalls = 0
    var restoreCalls = 0

    init(routeKind: AudioOutputRouteKind, preferredInputDeviceID: AudioObjectID?) {
        self.routeKind = routeKind
        self.preferredInputDeviceID = preferredInputDeviceID
    }

    func refreshRouteCache() {
        refreshCalls += 1
    }

    func preferredInputDeviceIDForDictation() -> AudioObjectID? {
        preferredInputDeviceID
    }

    func cachedPreferredInputDeviceIDForDictation() -> AudioObjectID? {
        preferredInputDeviceID
    }

    func isDefaultOutputHeadphoneLike() -> Bool {
        routeKind == .headphoneLike
    }

    func currentOutputRouteKindForDebug() -> AudioOutputRouteKind {
        routeKind
    }

    func currentRouteDebugDescription() -> String {
        "output=\(routeKind.description) preferredInput=\(preferredInputDeviceID.map(String.init) ?? "default")"
    }

    func beginDictationInputOverride() {}

    func restoreDictationInputOverride() {
        restoreCalls += 1
    }
}
