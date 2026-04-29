import AppKit
import CoreAudio
import Foundation

@MainActor
final class MeetingMonitor {
    var calendarEventProvider: (() -> CalendarEventContext?)?
    var detectionEnabledProvider: (() -> Bool)?
    var isRecordingProvider: (() -> Bool)?
    var isStartingRecordingProvider: (() -> Bool)?
    var isCalendarNotificationVisibleProvider: (() -> Bool)?
    var promptVisibilityProvider: (() -> MeetingPromptVisibility)?
    var onPromptCandidateChanged: ((MeetingCandidate?) -> Void)?

    private let resolver = MeetingCandidateResolver()
    private let browserCollector = BrowserMeetingActivityCollector()
    private let audioProcessCollector = AudioProcessAttributionCollector()
    private let cameraMonitor = CameraActivityMonitor()
    private let promptState = MeetingPromptStateMachine()

    private var micListenerDeviceID: AudioDeviceID = 0
    private var micListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?
    private var evaluationTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var globalSuppressUntil: Date?
    private var lastLoggedCandidateID: String?
    private var lastSuppressionLogKey: String?

    func start() {
        installMicListener()
        installDeviceChangeListener()
        installWorkspaceActivationObserver()

        cameraMonitor.onCameraStateChanged = { [weak self] _ in
            self?.evaluateNow()
        }
        cameraMonitor.start()

        installEvaluationTimer()
        evaluateNow()
    }

    func stop() {
        removeMicListener()
        removeDeviceChangeListener()
        removeWorkspaceActivationObserver()
        cameraMonitor.stop()
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }

    func refreshState() {
        evaluateNow()
    }

    func suppress(for duration: TimeInterval = 120) {
        globalSuppressUntil = Date().addingTimeInterval(duration)
        dismissVisiblePromptForSuppression()
    }

    func suppressWhileActive() {
        globalSuppressUntil = .distantFuture
        dismissVisiblePromptForSuppression()
    }

    func resumeAfterCooldown() {
        globalSuppressUntil = Date().addingTimeInterval(15)
    }

    func markPromptShown(_ candidate: MeetingCandidate) {
        promptState.markShown(candidate)
    }

    func markPromptAutoDismissed(_ candidate: MeetingCandidate) {
        promptState.markAutoDismissed(candidate)
        log("prompt_auto_dismissed id=\(candidate.id)")
    }

    func markPromptUserDismissed(_ candidate: MeetingCandidate) {
        promptState.markUserDismissed(candidate)
        log("prompt_suppressed id=\(candidate.id) reason=user_dismissed")
    }

    func markPromptClosed(_ candidate: MeetingCandidate) {
        promptState.markClosed(candidate)
    }

    func markRecordingStarted(_ candidate: MeetingCandidate?) {
        if let candidate {
            log("recording_started id=\(candidate.id)")
        } else {
            log("recording_started")
        }
    }

    private func dismissVisiblePromptForSuppression() {
        promptState.resetVisiblePrompt()
        onPromptCandidateChanged?(nil)
    }

    private func evaluateNow() {
        let now = Date()
        let visibility = promptVisibilityProvider?() ?? MeetingPromptVisibility(isVisible: false, currentPromptID: nil, shownAt: nil)
        cameraMonitor.refresh()
        let audioInputProcesses = audioProcessCollector.activeInputProcesses()
        let micActive = isMicActive() || !audioInputProcesses.isEmpty

        let snapshot = MeetingSignalSnapshot(
            micActive: micActive,
            cameraActive: cameraMonitor.isCameraActive,
            calendarEvent: calendarEventProvider?(),
            runningApps: currentRunningApps(),
            browserMeetings: browserCollector.collect(),
            audioInputProcesses: audioInputProcesses,
            foregroundBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            now: now
        )

        let candidate = isGloballySuppressed(now: now) ? nil : resolver.resolve(snapshot)
        logCandidateIfChanged(candidate)

        let decision = promptState.evaluate(
            candidate: candidate,
            detectionEnabled: detectionEnabledProvider?() ?? true,
            isRecording: isRecordingProvider?() ?? false,
            isStartingRecording: isStartingRecordingProvider?() ?? false,
            isCalendarNotificationVisible: isCalendarNotificationVisibleProvider?() ?? false,
            visibility: visibility,
            now: now
        )

        switch decision.action {
        case .show:
            guard let candidate = decision.candidate else { return }
            log("prompt_shown id=\(candidate.id) platform=\(candidate.platform.displayName) app=\(candidate.appName)")
            onPromptCandidateChanged?(candidate)
        case .hide:
            onPromptCandidateChanged?(nil)
        case .none:
            logSuppressionIfNeeded(decision)
        }
    }

    private func isGloballySuppressed(now: Date) -> Bool {
        guard let until = globalSuppressUntil else { return false }
        if now >= until {
            globalSuppressUntil = nil
            return false
        }
        return true
    }

    private func logCandidateIfChanged(_ candidate: MeetingCandidate?) {
        guard candidate?.id != lastLoggedCandidateID else { return }
        lastLoggedCandidateID = candidate?.id
        if let candidate {
            log("candidate_detected id=\(candidate.id) platform=\(candidate.platform.displayName) app=\(candidate.appName)")
        }
    }

    private func logSuppressionIfNeeded(_ decision: MeetingPromptDecision) {
        guard let candidate = decision.candidate else {
            lastSuppressionLogKey = nil
            return
        }
        let key = "\(candidate.id):\(decision.reason)"
        guard key != lastSuppressionLogKey else { return }
        lastSuppressionLogKey = key
        switch decision.reason {
        case .autoDismissedSuppression:
            log("prompt_suppressed id=\(candidate.id) reason=auto_dismissed")
        case .userDismissedSuppression:
            log("prompt_suppressed id=\(candidate.id) reason=user_dismissed")
        case .calendarNotificationVisible:
            log("prompt_suppressed id=\(candidate.id) reason=calendar_notification_visible")
        case .recording:
            log("prompt_suppressed id=\(candidate.id) reason=recording")
        default:
            break
        }
    }

    private func installEvaluationTimer() {
        evaluationTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateNow()
            }
        }
        evaluationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installWorkspaceActivationObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateNow()
            }
        }
    }

    private func removeWorkspaceActivationObserver() {
        guard let workspaceObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        self.workspaceObserver = nil
    }

    private func currentRunningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppInfo(bundleID: bundleID, isActive: app.isActive)
        }
    }

    private func installMicListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else { return }

        micListenerDeviceID = deviceID

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluateNow() }
        }
        micListenerBlock = block

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(deviceID, &runningAddress, nil, block)
    }

    private func removeMicListener() {
        guard micListenerDeviceID != 0, let block = micListenerBlock else { return }
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(micListenerDeviceID, &runningAddress, nil, block)
        micListenerDeviceID = 0
        micListenerBlock = nil
    }

    private func installDeviceChangeListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.removeMicListener()
                self?.installMicListener()
                self?.evaluateNow()
            }
        }
        deviceChangeListenerBlock = block

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = deviceChangeListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        deviceChangeListenerBlock = nil
    }

    private func isMicActive() -> Bool {
        guard micListenerDeviceID != 0 else { return false }

        var isRunning: UInt32 = 0
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(
            micListenerDeviceID,
            &runningAddress,
            0,
            nil,
            &size,
            &isRunning
        ) == noErr else { return false }

        return isRunning != 0
    }

    private func log(_ message: String) {
        fputs("[meeting-monitor] \(message)\n", stderr)
    }
}
