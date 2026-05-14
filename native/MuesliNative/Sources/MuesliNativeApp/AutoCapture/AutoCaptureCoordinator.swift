import Foundation
import os

// MARK: - AutoCaptureSignal

/// Opaque detection signal consumed by the coordinator. Decouples auto-capture
/// from the upstream `MeetingCandidate` type so the state machine can be
/// tested without constructing AppKit-coupled types.
struct AutoCaptureSignal: Equatable {
    let appName: String
    let bundleID: String?
    let meetingTitle: String?
    let hasCalendarMatch: Bool

    init(appName: String, bundleID: String?, meetingTitle: String?, hasCalendarMatch: Bool) {
        self.appName = appName
        self.bundleID = bundleID
        self.meetingTitle = meetingTitle
        self.hasCalendarMatch = hasCalendarMatch
    }
}

// MARK: - AutoCaptureState

/// State machine matching `tickets/architecture.md` §5. Public for inspection
/// via the CLI `auto-capture status` subcommand and for testing.
enum AutoCaptureState: Equatable {
    case idle
    case armed(bundleID: String?, appName: String)
    case confirming(bundleID: String?, appName: String)
    case awaitingUserConfirm(bundleID: String?, appName: String)
    case recording(bundleID: String?, appName: String)

    var name: String {
        switch self {
        case .idle: return "idle"
        case .armed: return "armed"
        case .confirming: return "confirming"
        case .awaitingUserConfirm: return "awaiting_user_confirm"
        case .recording: return "recording"
        }
    }
}

// MARK: - AutoCaptureDecisionReason

/// Last decision taken by the coordinator. Surfaces via the CLI status
/// subcommand for headless diagnostics.
enum AutoCaptureDecisionReason: String, Equatable {
    case noSignal = "no_signal"
    case masterToggleOff = "master_toggle_off"
    case appNotAllowed = "app_not_allowed"
    case focusModeActive = "focus_mode_active"
    case calendarMatchRequired = "calendar_match_required"
    case awaitingDelay = "awaiting_delay"
    case awaitingConfirmation = "awaiting_confirmation"
    case userDeclined = "user_declined"
    case detectionCleared = "detection_cleared"
    case startedRecording = "started_recording"
    case alreadyRecording = "already_recording"
    case startFailed = "start_failed"
    case stoppedExternally = "stopped_externally"
    case autoStopped = "auto_stopped"
}

// MARK: - AutoCaptureCoordinator

/// Orchestrates opt-in auto-start of meeting recordings on top of the
/// existing detection pipeline. Pure listener — owns no AppKit resources.
@MainActor
final class AutoCaptureCoordinator {

    // MARK: Dependencies

    private let configProvider: () -> AutoCaptureConfig
    private let configWriter: (AutoCaptureConfig) -> Void
    private let recordingStarter: (_ title: String?) -> Bool
    private let recordingStopper: (() -> Void)?
    private let isRecordingNowProbe: () -> Bool
    private let isFocusModeActiveProbe: () -> Bool
    private let confirmationPresenter: AutoCaptureConfirmationPresenting
    private let clock: () -> Date
    private let delaySleep: (Double) async -> Void
    private let logger: Logger
    private let browserURLPollerFactory: BrowserURLPollerFactory?
    private let browserMicReleaseMonitorFactory: BrowserMicReleaseMonitorFactory?

    // MARK: State

    private(set) var state: AutoCaptureState = .idle
    private(set) var lastDecisionReason: AutoCaptureDecisionReason = .noSignal
    private(set) var lastSignal: AutoCaptureSignal?
    private(set) var lastDecisionAt: Date?
    private(set) var browserURLPoller: BrowserURLPoller?
    private(set) var browserMicReleaseMonitor: BrowserMicReleaseMonitoring?

    private var pendingDelayTask: Task<Void, Never>?
    private var hasStarted = false

    // MARK: Init

    init(
        config: @escaping () -> AutoCaptureConfig,
        configWriter: @escaping (AutoCaptureConfig) -> Void,
        recordingStarter: @escaping (_ title: String?) -> Bool,
        recordingStopper: (() -> Void)? = nil,
        isRecordingNow: @escaping () -> Bool,
        isFocusModeActive: @escaping () -> Bool = { false },
        confirmationPresenter: AutoCaptureConfirmationPresenting,
        clock: @escaping () -> Date = { Date() },
        sleep: @escaping (Double) async -> Void = { seconds in
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        },
        logger: Logger = Logger(subsystem: "com.muesli.native", category: "AutoCapture"),
        browserURLPollerFactory: BrowserURLPollerFactory? = .production,
        browserMicReleaseMonitorFactory: BrowserMicReleaseMonitorFactory? = .production
    ) {
        self.configProvider = config
        self.configWriter = configWriter
        self.recordingStarter = recordingStarter
        self.recordingStopper = recordingStopper
        self.isRecordingNowProbe = isRecordingNow
        self.isFocusModeActiveProbe = isFocusModeActive
        self.confirmationPresenter = confirmationPresenter
        self.clock = clock
        self.delaySleep = sleep
        self.logger = logger
        self.browserURLPollerFactory = browserURLPollerFactory
        self.browserMicReleaseMonitorFactory = browserMicReleaseMonitorFactory
    }

    // MARK: Lifecycle

    func start() {
        hasStarted = true
        installBrowserURLPollerIfNeeded()
        installBrowserMicReleaseMonitorIfNeeded()
    }

    func stop() {
        hasStarted = false
        cancelPendingDelay()
        browserURLPoller?.stop()
        browserURLPoller = nil
        browserMicReleaseMonitor?.stopWatching()
        browserMicReleaseMonitor = nil
        transition(to: .idle, reason: .detectionCleared)
    }

    // MARK: Inputs

    /// Main entry point. Pass `nil` when the upstream pipeline reports no
    /// candidate. Call from the MainActor only.
    func handle(_ signal: AutoCaptureSignal?) {
        lastSignal = signal

        guard hasStarted else {
            recordDecision(.noSignal)
            return
        }

        if case .recording = state {
            if !isRecordingNowProbe() {
                transition(to: .idle, reason: .stoppedExternally)
            } else {
                recordDecision(.alreadyRecording)
                return
            }
        }

        guard let signal else {
            if state != .idle {
                cancelPendingDelay()
                transition(to: .idle, reason: .detectionCleared)
            } else {
                recordDecision(.detectionCleared)
            }
            return
        }

        let config = configProvider()

        guard config.enabled else {
            if state != .idle {
                cancelPendingDelay()
                transition(to: .idle, reason: .masterToggleOff)
            } else {
                recordDecision(.masterToggleOff)
            }
            return
        }

        guard config.isAllowed(bundleID: signal.bundleID) else {
            if state != .idle {
                cancelPendingDelay()
                transition(to: .idle, reason: .appNotAllowed)
            } else {
                recordDecision(.appNotAllowed)
            }
            return
        }

        if config.disableDuringFocus, isFocusModeActiveProbe() {
            if state != .idle {
                cancelPendingDelay()
                transition(to: .idle, reason: .focusModeActive)
            } else {
                recordDecision(.focusModeActive)
            }
            return
        }

        if isRecordingNowProbe() {
            recordDecision(.alreadyRecording)
            return
        }

        switch state {
        case .idle:
            arm(with: signal, config: config)
        case .armed(let bundleID, _):
            if bundleID != signal.bundleID {
                cancelPendingDelay()
                arm(with: signal, config: config)
            } else {
                recordDecision(.awaitingDelay)
            }
        case .confirming, .awaitingUserConfirm, .recording:
            // Already advanced through delay — ignore subsequent signals for
            // this candidate. New candidates are handled when we return to idle.
            recordDecision(.awaitingConfirmation)
        }
    }

    // MARK: Acknowledgement

    /// Persist that the user has acknowledged the supplied bundle ID. Called
    /// when the confirmation modal returns `approved(rememberForApp: true)`
    /// or `declined(rememberForApp: true)`.
    func acknowledge(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        var config = configProvider()
        guard !config.acknowledgedAppBundleIDs.contains(bundleID) else { return }
        config.acknowledgedAppBundleIDs.insert(bundleID)
        configWriter(config)
    }

    // MARK: Helpers

    private func arm(with signal: AutoCaptureSignal, config: AutoCaptureConfig) {
        transition(to: .armed(bundleID: signal.bundleID, appName: signal.appName), reason: .awaitingDelay)
        let delay = config.startDelaySeconds
        pendingDelayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.delaySleep(delay)
            guard !Task.isCancelled else { return }
            self.delayElapsed(for: signal)
        }
    }

    private func delayElapsed(for signal: AutoCaptureSignal) {
        guard case .armed(let armedBundleID, _) = state, armedBundleID == signal.bundleID else { return }
        pendingDelayTask = nil

        let config = configProvider()
        guard config.enabled else {
            transition(to: .idle, reason: .masterToggleOff)
            return
        }
        guard config.isAllowed(bundleID: signal.bundleID) else {
            transition(to: .idle, reason: .appNotAllowed)
            return
        }
        if config.disableDuringFocus, isFocusModeActiveProbe() {
            transition(to: .idle, reason: .focusModeActive)
            return
        }
        if isRecordingNowProbe() {
            transition(to: .idle, reason: .alreadyRecording)
            return
        }

        if config.requireCalendarMatch, !signal.hasCalendarMatch {
            transition(to: .idle, reason: .calendarMatchRequired)
            return
        }

        transition(to: .confirming(bundleID: signal.bundleID, appName: signal.appName), reason: .awaitingConfirmation)

        if config.isAcknowledged(bundleID: signal.bundleID) {
            beginRecording(for: signal)
        } else if signal.hasCalendarMatch, config.requireCalendarMatch {
            // Strict mode: calendar match alone authorises (no first-run modal).
            beginRecording(for: signal)
        } else {
            promptConfirmation(for: signal)
        }
    }

    private func promptConfirmation(for signal: AutoCaptureSignal) {
        transition(
            to: .awaitingUserConfirm(bundleID: signal.bundleID, appName: signal.appName),
            reason: .awaitingConfirmation
        )
        confirmationPresenter.present(
            appName: signal.appName,
            bundleID: signal.bundleID,
            meetingTitle: signal.meetingTitle
        ) { [weak self] outcome in
            guard let self else { return }
            self.handleConfirmation(outcome: outcome, for: signal)
        }
    }

    private func handleConfirmation(outcome: AutoCaptureConfirmationOutcome, for signal: AutoCaptureSignal) {
        guard case .awaitingUserConfirm(let waitingBundleID, _) = state, waitingBundleID == signal.bundleID else {
            return
        }

        switch outcome {
        case .approved(let remember):
            if remember, let bundleID = signal.bundleID, !bundleID.isEmpty {
                acknowledge(bundleID: bundleID)
            }
            beginRecording(for: signal)
        case .declined(let remember):
            if remember, let bundleID = signal.bundleID, !bundleID.isEmpty {
                acknowledge(bundleID: bundleID)
            }
            transition(to: .idle, reason: .userDeclined)
        case .timedOut:
            transition(to: .idle, reason: .userDeclined)
        }
    }

    private func beginRecording(for signal: AutoCaptureSignal) {
        guard !isRecordingNowProbe() else {
            transition(to: .idle, reason: .alreadyRecording)
            return
        }
        let title = signal.meetingTitle?.isEmpty == false ? signal.meetingTitle : nil
        let started = recordingStarter(title)
        if started {
            transition(
                to: .recording(bundleID: signal.bundleID, appName: signal.appName),
                reason: .startedRecording
            )
            if let bundleID = signal.bundleID,
               BrowserMicReleaseMonitor.isEligibleForAutoStop(bundleID: bundleID) {
                browserMicReleaseMonitor?.beginWatching(bundleID: bundleID)
            }
        } else {
            transition(to: .idle, reason: .startFailed)
        }
    }

    // MARK: Auto-stop (v2.1)

    /// Called by `BrowserMicReleaseMonitor` when the watched browser has held
    /// no input device for the debounce window. Stops the recording iff the
    /// coordinator is in `.recording` for a matching bundle and the user has
    /// `auto_stop_enabled == true`. See ADR 0009 + `tickets/ticket-v2.1.md`.
    private func handleAutoStop(bundleID: String) {
        guard case .recording(let recordingBundleID, _) = state,
              recordingBundleID == bundleID || resolvedParent(recordingBundleID) == bundleID else {
            return
        }
        let config = configProvider()
        guard config.autoStopEnabled else {
            return
        }
        recordingStopper?()
        transition(to: .idle, reason: .autoStopped)
    }

    private func resolvedParent(_ bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return BrowserMicReleaseMonitor.parentBrowserBundleID(for: bundleID)
    }

    private func cancelPendingDelay() {
        pendingDelayTask?.cancel()
        pendingDelayTask = nil
    }

    private func transition(to newState: AutoCaptureState, reason: AutoCaptureDecisionReason) {
        guard state != newState else {
            recordDecision(reason)
            return
        }
        let previous = state
        state = newState
        if case .idle = newState {
            browserMicReleaseMonitor?.stopWatching()
        }
        recordDecision(reason)
        logger.notice(
            "auto_capture transition from=\(previous.name, privacy: .public) to=\(newState.name, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
    }

    private func recordDecision(_ reason: AutoCaptureDecisionReason) {
        lastDecisionReason = reason
        lastDecisionAt = clock()
    }

    // MARK: Browser URL poller

    /// Notify the coordinator that the user toggled a setting that may affect
    /// the browser URL poller (per-browser flags, master toggle). Cheap to
    /// call from the Settings view's binding setter.
    func configurationChanged() {
        guard hasStarted else { return }
        installBrowserURLPollerIfNeeded()
        browserURLPoller?.configurationChanged()
    }

    private func installBrowserURLPollerIfNeeded() {
        guard hasStarted, let factory = browserURLPollerFactory else { return }
        if browserURLPoller != nil { return }
        let poller = factory.make(
            { [weak self] in
                self?.configProvider().browserUrlPolling ?? .disabled
            },
            { [weak self] signal in
                self?.handle(signal)
            }
        )
        browserURLPoller = poller
        poller.start()
    }

    private func installBrowserMicReleaseMonitorIfNeeded() {
        guard hasStarted, recordingStopper != nil else { return }
        guard let factory = browserMicReleaseMonitorFactory else { return }
        if browserMicReleaseMonitor != nil { return }
        browserMicReleaseMonitor = factory.make { [weak self] bundleID in
            self?.handleAutoStop(bundleID: bundleID)
        }
    }
}

// MARK: - BrowserURLPollerFactory

/// Pluggable factory so tests can supply a poller with mocked dependencies
/// (or opt out of having one altogether by passing `nil` to the coordinator).
/// Production code uses `.production`.
struct BrowserURLPollerFactory {
    let make: @MainActor (
        _ configProvider: @escaping () -> BrowserURLPollingConfig,
        _ signalHandler: @escaping @MainActor (AutoCaptureSignal) -> Void
    ) -> BrowserURLPoller

    /// Real factory backed by `AudioProcessAttributionCollector` for the
    /// mic-ownership signal and `NSAppleScript` for URL fetching.
    static let production: BrowserURLPollerFactory = BrowserURLPollerFactory(make: { configProvider, signalHandler in
        BrowserURLPoller(config: configProvider, signalHandler: signalHandler)
    })
}

// MARK: - BrowserMicReleaseMonitorFactory

/// Pluggable factory mirroring `BrowserURLPollerFactory`. Tests substitute a
/// fake monitor so they can drive `onCallEnded` deterministically.
struct BrowserMicReleaseMonitorFactory {
    let make: @MainActor (
        _ onCallEnded: @escaping @MainActor (_ bundleID: String) -> Void
    ) -> BrowserMicReleaseMonitoring

    /// Production factory using `BrowserMicReleaseMonitor` with the CoreAudio
    /// HAL backend.
    static let production: BrowserMicReleaseMonitorFactory = BrowserMicReleaseMonitorFactory(make: { onCallEnded in
        BrowserMicReleaseMonitor(onCallEnded: onCallEnded)
    })
}
