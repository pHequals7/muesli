import CoreAudio
import Foundation

enum DictationAudioSessionState: Equatable {
    case idle
    case armed(UUID)
    case acquiringAudio(UUID)
    case streamActive(UUID)
    case speechDetected(UUID)

    var sessionID: UUID? {
        switch self {
        case .idle:
            return nil
        case .armed(let id), .acquiringAudio(let id), .streamActive(let id), .speechDetected(let id):
            return id
        }
    }
}

enum DictationAudioSessionEvent {
    case armed(UUID, source: String)
    case acquiringAudio(UUID)
    case streamActive(UUID, capturedAt: Date)
    case speechDetected(UUID, capturedAt: Date)
    case noAudioTimeout(UUID, at: Date)
    case stopped(UUID?, wavURL: URL?)
    case cancelled(UUID?, reason: String)
    case failed(UUID?, error: Error)
    case latency(String, Date)
}

protocol DictationAudioRecording: AnyObject {
    var preferredInputDeviceID: AudioObjectID? { get set }
    var keepsAudioGraphWarm: Bool { get set }
    var onFirstCapturedAudioBuffer: ((Date) -> Void)? { get set }
    var onFirstSpeechDetected: ((Date) -> Void)? { get set }
    var onNoAudioTimeout: ((Date) -> Void)? { get set }

    func prepare() throws
    func warmUp(preferredInputDeviceID: AudioObjectID?) throws
    func activateWarmEngine(preferredInputDeviceID: AudioObjectID?) throws
    func coolDown()
    func start() throws
    func stop() -> URL?
    func cancel()
    func currentPower() -> Float
}

extension MicrophoneRecorder: DictationAudioRecording {}

final class DictationAudioSessionManager: @unchecked Sendable {
    private struct RouteSnapshot {
        let routeKind: AudioOutputRouteKind
        let preferredInputDeviceID: AudioObjectID?
        let debugDescription: String

        var shouldDuck: Bool {
            routeKind != .headphoneLike
        }
    }

    private let recorder: DictationAudioRecording
    private let duckingController: AudioDuckingManaging
    private let routingController: DictationAudioRouting
    private let queue: DispatchQueue
    private let eventQueue: DispatchQueue

    private var stateStorage: DictationAudioSessionState = .idle
    private var routeSnapshot: RouteSnapshot
    private var duckingEnabledForSession = false
    private var externalSessionActive = false

    var onEvent: ((DictationAudioSessionEvent) -> Void)?

    init(
        recorder: DictationAudioRecording,
        duckingController: AudioDuckingManaging,
        routingController: DictationAudioRouting,
        queue: DispatchQueue = DispatchQueue(label: "com.muesli.dictation-audio-session-manager"),
        eventQueue: DispatchQueue = .main
    ) {
        self.recorder = recorder
        self.duckingController = duckingController
        self.routingController = routingController
        self.queue = queue
        self.eventQueue = eventQueue
        self.routeSnapshot = RouteSnapshot(
            routeKind: routingController.currentOutputRouteKindForDebug(),
            preferredInputDeviceID: routingController.cachedPreferredInputDeviceIDForDictation(),
            debugDescription: routingController.currentRouteDebugDescription()
        )

        recorder.onFirstCapturedAudioBuffer = { [weak self] capturedAt in
            self?.handleFirstAudioBuffer(capturedAt: capturedAt)
        }
        recorder.onFirstSpeechDetected = { [weak self] capturedAt in
            self?.handleFirstSpeech(capturedAt: capturedAt)
        }
        recorder.onNoAudioTimeout = { [weak self] at in
            self?.handleNoAudioTimeout(at: at)
        }
    }

    var currentState: DictationAudioSessionState {
        queue.sync { stateStorage }
    }

    var currentSessionID: UUID? {
        currentState.sessionID
    }

    var hasActiveSession: Bool {
        queue.sync {
            stateStorage.sessionID != nil || externalSessionActive
        }
    }

    func currentPower() -> Float {
        recorder.currentPower()
    }

    func arm(source: String, duckingEnabled: Bool) {
        let sessionID = ensureSession()
        emit(.armed(sessionID, source: source))
        emitLatency("ui_armed")
        queue.async { [self] in
            guard self.isCurrent(sessionID) else { return }
            self.stateStorage = .armed(sessionID)
            self.routeSnapshot = self.makeRouteSnapshot()
            self.emitLatency("route_snapshot \(self.routeSnapshot.debugDescription)")
            self.beginDuckingIfNeeded(duckingEnabled: duckingEnabled)
            self.recorder.keepsAudioGraphWarm = true
            do {
                self.emitLatency("activation_begin:\(source)")
                try self.recorder.activateWarmEngine(preferredInputDeviceID: self.routeSnapshot.preferredInputDeviceID)
                self.emitLatency("activation_end:\(source)")
                fputs("[dictation-session] armed source=\(source) \(self.routeSnapshot.debugDescription)\n", stderr)
            } catch {
                self.emitLatency("activation_failed:\(source)")
                self.failCurrentSession(error: error)
            }
        }
    }

    func beginRecording(mode: String, duckingEnabled: Bool) {
        let sessionID = ensureSession()
        queue.async { [self] in
            guard self.isCurrent(sessionID) else { return }
            switch self.stateStorage {
            case .acquiringAudio, .streamActive, .speechDetected:
                self.emitLatency("activation_reused:\(mode)")
                return
            default:
                break
            }
            self.stateStorage = .acquiringAudio(sessionID)
            self.emit(.acquiringAudio(sessionID))
            self.emitLatency("threshold_met:\(mode)")
            self.routeSnapshot = self.makeRouteSnapshot()
            self.beginDuckingIfNeeded(duckingEnabled: duckingEnabled)
            self.duckingController.ensureCurrentDefaultDucked()
            self.recorder.preferredInputDeviceID = self.routeSnapshot.preferredInputDeviceID
            self.recorder.keepsAudioGraphWarm = true
            do {
                self.emitLatency("engine_prepare_begin")
                try self.recorder.prepare()
                self.emitLatency("engine_prepare_end")
                self.emitLatency("activation_begin:\(mode)")
                try self.recorder.start()
                self.emitLatency("activation_end:\(mode)")
                fputs("[dictation-session] recording mode=\(mode) \(self.routeSnapshot.debugDescription)\n", stderr)
            } catch {
                self.emitLatency("activation_failed:\(mode)")
                self.recorder.cancel()
                self.failCurrentSession(error: error)
            }
        }
    }

    func beginExternalSession(source: String, duckingEnabled: Bool) {
        queue.async { [self] in
            self.externalSessionActive = true
            self.routeSnapshot = self.makeRouteSnapshot()
            self.emitLatency("external_begin:\(source)")
            self.beginDuckingIfNeeded(duckingEnabled: duckingEnabled)
            self.duckingController.ensureCurrentDefaultDucked()
        }
    }

    func endExternalSession(reason: String) {
        queue.async { [self] in
            guard self.externalSessionActive else { return }
            self.externalSessionActive = false
            self.emitLatency("external_end:\(reason)")
            self.restoreSessionAudioState()
        }
    }

    func stop() {
        queue.async { [self] in
            let sessionID = self.stateStorage.sessionID
            guard sessionID != nil else {
                self.restoreSessionAudioState()
                self.emit(.stopped(nil, wavURL: nil))
                return
            }
            self.emitLatency("stop")
            let wavURL = self.recorder.stop()
            self.recorder.preferredInputDeviceID = nil
            self.stateStorage = .idle
            self.restoreSessionAudioState()
            self.emit(.stopped(sessionID, wavURL: wavURL))
        }
    }

    func cancel(reason: String) {
        queue.async { [self] in
            let sessionID = self.stateStorage.sessionID
            self.recorder.cancel()
            self.recorder.preferredInputDeviceID = nil
            self.stateStorage = .idle
            self.externalSessionActive = false
            self.restoreSessionAudioState()
            self.emitLatency("cancelled:\(reason)")
            self.emit(.cancelled(sessionID, reason: reason))
        }
    }

    func refreshRoute(reason: String, delay: TimeInterval = 0, canWarmUp: Bool) {
        routingController.refreshRouteCache()
        queue.async { [self] in
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            self.routeSnapshot = self.makeRouteSnapshot()
            self.emitLatency("route_refresh:\(reason) \(self.routeSnapshot.debugDescription)")
            guard self.stateStorage == .idle, !self.externalSessionActive else { return }
            guard canWarmUp else {
                self.recorder.keepsAudioGraphWarm = false
                self.recorder.coolDown()
                return
            }
            self.recorder.keepsAudioGraphWarm = true
            do {
                self.emitLatency("engine_prepare_begin:warmup:\(reason)")
                try self.recorder.warmUp(preferredInputDeviceID: self.routeSnapshot.preferredInputDeviceID)
                self.emitLatency("engine_prepare_end:warmup:\(reason)")
                fputs("[dictation-session] warmed reason=\(reason) \(self.routeSnapshot.debugDescription)\n", stderr)
            } catch {
                self.emitLatency("engine_prepare_failed:warmup:\(reason)")
                fputs("[dictation-session] warmup failed reason=\(reason) error=\(error)\n", stderr)
            }
        }
    }

    func coolDown(reason: String) {
        queue.async { [self] in
            guard self.stateStorage == .idle, !self.externalSessionActive else { return }
            self.recorder.keepsAudioGraphWarm = false
            self.recorder.coolDown()
            self.emitLatency("cool_down:\(reason)")
        }
    }

    private func ensureSession() -> UUID {
        queue.sync {
            if let current = stateStorage.sessionID {
                return current
            }
            let id = UUID()
            stateStorage = .armed(id)
            return id
        }
    }

    private func isCurrent(_ sessionID: UUID) -> Bool {
        stateStorage.sessionID == sessionID
    }

    private func beginDuckingIfNeeded(duckingEnabled: Bool) {
        duckingEnabledForSession = duckingEnabled && routeSnapshot.shouldDuck
        emitLatency(duckingEnabledForSession ? "duck_begin" : "duck_skip")
        duckingController.beginDictationDucking(enabled: duckingEnabledForSession)
    }

    private func restoreSessionAudioState() {
        duckingController.restoreDictationDucking()
        routingController.restoreDictationInputOverride()
        duckingEnabledForSession = false
    }

    private func makeRouteSnapshot() -> RouteSnapshot {
        RouteSnapshot(
            routeKind: routingController.currentOutputRouteKindForDebug(),
            preferredInputDeviceID: routingController.cachedPreferredInputDeviceIDForDictation(),
            debugDescription: routingController.currentRouteDebugDescription()
        )
    }

    private func failCurrentSession(error: Error) {
        let sessionID = stateStorage.sessionID
        stateStorage = .idle
        recorder.preferredInputDeviceID = nil
        restoreSessionAudioState()
        emit(.failed(sessionID, error: error))
    }

    private func handleFirstAudioBuffer(capturedAt: Date) {
        queue.async { [self] in
            guard let sessionID = self.stateStorage.sessionID else { return }
            switch self.stateStorage {
            case .acquiringAudio(let id) where id == sessionID,
                 .armed(let id) where id == sessionID:
                self.stateStorage = .streamActive(sessionID)
            default:
                break
            }
            self.emitLatency("first_buffer", at: capturedAt)
            self.emit(.streamActive(sessionID, capturedAt: capturedAt))
        }
    }

    private func handleFirstSpeech(capturedAt: Date) {
        queue.async { [self] in
            guard let sessionID = self.stateStorage.sessionID else { return }
            self.stateStorage = .speechDetected(sessionID)
            self.emitLatency("first_speech", at: capturedAt)
            self.emit(.speechDetected(sessionID, capturedAt: capturedAt))
        }
    }

    private func handleNoAudioTimeout(at: Date) {
        queue.async { [self] in
            guard let sessionID = self.stateStorage.sessionID else { return }
            self.emitLatency("no_audio_timeout", at: at)
            self.emit(.noAudioTimeout(sessionID, at: at))
        }
    }

    private func emitLatency(_ event: String, at date: Date = Date()) {
        emit(.latency(event, date))
    }

    private func emit(_ event: DictationAudioSessionEvent) {
        eventQueue.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
