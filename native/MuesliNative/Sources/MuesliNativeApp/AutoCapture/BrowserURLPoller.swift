import AppKit
import Foundation
import os

// MARK: - BrowserMeetingURLMatch

/// Result of matching a raw browser URL against the v1 meeting-URL patterns.
struct BrowserMeetingURLMatch: Equatable {
    let platformName: String
    let normalizedURL: String
}

// MARK: - BrowserMeetingURLMatcher

/// Recognises the URL shapes the v1 ticket calls out:
///
/// - `teams.microsoft.com`
/// - `teams.live.com`
/// - `teams.cloud.microsoft`
/// - `meet.google.com`
/// - `*.zoom.us/wc/*`
/// - `app.webex.com`
///
/// Pure value-level code so it is independently testable without spinning up
/// the poller. Returns `nil` for any URL outside the supported set.
enum BrowserMeetingURLMatcher {
    static func match(_ rawURL: String) -> BrowserMeetingURLMatch? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let host = components.host?.lowercased() else {
            return nil
        }
        let path = components.path

        if host == "meet.google.com", !path.isEmpty, path != "/" {
            return BrowserMeetingURLMatch(
                platformName: "Google Meet",
                normalizedURL: "meet.google.com\(path)"
            )
        }

        if host.hasSuffix(".zoom.us") || host == "zoom.us" {
            let normalizedPath = path.hasPrefix("/wc/") || path.contains("/wc/")
            if normalizedPath {
                return BrowserMeetingURLMatch(
                    platformName: "Zoom",
                    normalizedURL: "\(host)\(path)"
                )
            }
            return nil
        }

        if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com") {
            return BrowserMeetingURLMatch(
                platformName: "Teams",
                normalizedURL: "\(host)\(path)"
            )
        }

        if host == "teams.live.com" || host.hasSuffix(".teams.live.com") {
            return BrowserMeetingURLMatch(
                platformName: "Teams",
                normalizedURL: "\(host)\(path)"
            )
        }

        if host == "teams.cloud.microsoft" || host.hasSuffix(".teams.cloud.microsoft") {
            return BrowserMeetingURLMatch(
                platformName: "Teams",
                normalizedURL: "\(host)\(path)"
            )
        }

        if host == "app.webex.com" || host.hasSuffix(".webex.com") {
            return BrowserMeetingURLMatch(
                platformName: "Webex",
                normalizedURL: "\(host)\(path)"
            )
        }

        return nil
    }
}

// MARK: - BrowserURLPollerState

/// Snapshot state for tests and the `auto-capture status` CLI envelope.
enum BrowserURLPollerState: Equatable {
    case stopped
    case watching
    case polling(bundleID: String)
    case suspendedPermissionDenied(bundleID: String)

    var name: String {
        switch self {
        case .stopped: return "stopped"
        case .watching: return "watching"
        case .polling: return "polling"
        case .suspendedPermissionDenied: return "suspended_permission_denied"
        }
    }
}

// MARK: - BrowserURLPoller

/// Opt-in AppleScript URL poller. Only emits AppleScript invocations while a
/// configured browser owns the microphone; otherwise the poller is idle. See
/// `tickets/ticket-v1.md` and ADR-0003 for the rationale.
@MainActor
final class BrowserURLPoller {

    // MARK: Public types

    typealias MicOwnershipProbe = @MainActor () -> Set<String>
    typealias URLFetcher = @MainActor (String) async -> String?
    typealias PermissionProbe = @MainActor (String) -> AutomationPermissionStatus
    typealias SignalHandler = @MainActor (AutoCaptureSignal) -> Void
    typealias SleepFunction = (Double) async -> Void

    // MARK: Dependencies

    private let configProvider: () -> BrowserURLPollingConfig
    private let micOwnershipProbe: MicOwnershipProbe
    private let urlFetcher: URLFetcher
    private let permissionProbe: PermissionProbe
    private let signalHandler: SignalHandler
    private let watchdogInterval: Double
    private let pollInterval: Double
    private let sleepFn: SleepFunction
    private let logger: Logger

    // MARK: Mutable state

    private(set) var state: BrowserURLPollerState = .stopped
    private(set) var appleScriptInvocations: Int = 0
    private(set) var lastEmittedURL: String?
    private var deniedBundleIDs: Set<String> = []
    private var watchdogTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    /// Bundle ID → display name. Mirrors the catalog used by the Settings UI.
    private static let browserDisplayNames: [String: String] = [
        BrowserURLPollingConfig.chromeBundleID: "Chrome",
        BrowserURLPollingConfig.edgeBundleID: "Edge",
        BrowserURLPollingConfig.braveBundleID: "Brave",
        BrowserURLPollingConfig.arcBundleID: "Arc",
        BrowserURLPollingConfig.safariBundleID: "Safari",
    ]

    // MARK: Init

    init(
        config: @escaping () -> BrowserURLPollingConfig,
        signalHandler: @escaping SignalHandler,
        micOwnershipProbe: MicOwnershipProbe? = nil,
        urlFetcher: URLFetcher? = nil,
        permissionProbe: PermissionProbe? = nil,
        watchdogInterval: Double = 1.0,
        pollInterval: Double = 0.5,
        sleep: @escaping SleepFunction = { seconds in
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        },
        logger: Logger = Logger(subsystem: "com.muesli.native", category: "AutoCapture")
    ) {
        self.configProvider = config
        self.signalHandler = signalHandler
        self.micOwnershipProbe = micOwnershipProbe ?? BrowserURLPoller.defaultMicOwnershipProbe()
        self.urlFetcher = urlFetcher ?? BrowserURLPoller.defaultURLFetcher
        self.permissionProbe = permissionProbe ?? { AutomationPermissionProbe.status(forBundleID: $0) }
        self.watchdogInterval = watchdogInterval
        self.pollInterval = pollInterval
        self.sleepFn = sleep
        self.logger = logger
    }

    // MARK: Lifecycle

    /// Start the watchdog. The watchdog always runs once `start()` is called
    /// so toggling a browser in Settings takes effect on the next tick without
    /// needing an external wake-up. AppleScript invocations are still gated
    /// on per-tick config inspection — they only happen when a configured
    /// browser owns the microphone.
    func start() {
        guard watchdogTask == nil else { return }
        state = .watching
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let strongSelf = self else { return }
                await strongSelf.tickWatchdog()
                if Task.isCancelled { return }
                let interval = strongSelf.watchdogInterval
                let sleep = strongSelf.sleepFn
                await sleep(interval)
            }
        }
    }

    /// Stop watchdog + any active polling. Idempotent.
    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
        stopPolling(reason: .stopped)
        state = .stopped
    }

    /// Re-evaluate state when the user changes the config. Cheap to call from
    /// `AutoCaptureCoordinator` whenever it sees a config-change notification.
    func configurationChanged() {
        let config = configProvider()
        if !config.anyEnabled {
            stop()
            return
        }
        // Reset cached permission-denied entries that are no longer enabled.
        deniedBundleIDs = deniedBundleIDs.filter { config.isEnabled(forBundleID: $0) }
        if watchdogTask == nil {
            start()
        }
    }

    /// Test/diagnostic hook: counts of AppleScript invocations since `start()`.
    func resetInstrumentation() {
        appleScriptInvocations = 0
        lastEmittedURL = nil
    }

    // MARK: Watchdog

    private func tickWatchdog() async {
        let config = configProvider()
        guard config.anyEnabled else {
            stopPolling(reason: .configDisabled)
            state = .stopped
            return
        }

        let micOwners = micOwnershipProbe()
        let activeBrowser = micOwners.first { bundleID in
            config.isEnabled(forBundleID: bundleID)
        }

        guard let bundleID = activeBrowser else {
            stopPolling(reason: .micReleased)
            if state != .stopped { state = .watching }
            return
        }

        if deniedBundleIDs.contains(bundleID) {
            // Honour persistent denial — no AppleScript while user has not granted.
            stopPolling(reason: .permissionDenied)
            state = .suspendedPermissionDenied(bundleID: bundleID)
            return
        }

        if case .polling(let current) = state, current == bundleID {
            return
        }

        startPolling(forBundleID: bundleID)
    }

    private func startPolling(forBundleID bundleID: String) {
        stopPolling(reason: .switchedBrowser)
        state = .polling(bundleID: bundleID)
        let pollerBundle = bundleID
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let strongSelf = self else { return }
                await strongSelf.pollOnce(bundleID: pollerBundle)
                if Task.isCancelled { return }
                let interval = strongSelf.pollInterval
                let sleep = strongSelf.sleepFn
                await sleep(interval)
            }
        }
        logger.notice("browser_url_poller poll_started bundle=\(bundleID, privacy: .public)")
    }

    private enum StopReason {
        case stopped
        case configDisabled
        case micReleased
        case switchedBrowser
        case permissionDenied
    }

    private func stopPolling(reason: StopReason) {
        guard pollingTask != nil else { return }
        pollingTask?.cancel()
        pollingTask = nil
        logger.notice("browser_url_poller poll_stopped reason=\(String(describing: reason), privacy: .public)")
    }

    // MARK: Poll iteration

    private func pollOnce(bundleID: String) async {
        // Re-check config before each call so toggling the user setting takes
        // effect immediately without waiting for the watchdog interval.
        let config = configProvider()
        guard config.isEnabled(forBundleID: bundleID) else {
            stopPolling(reason: .configDisabled)
            state = .watching
            return
        }

        let permission = permissionProbe(bundleID)
        switch permission {
        case .granted, .notDetermined:
            // Proceed: the first invocation when `.notDetermined` will surface
            // the macOS prompt; subsequent calls will see `.granted` or `.denied`.
            break
        case .denied:
            deniedBundleIDs.insert(bundleID)
            stopPolling(reason: .permissionDenied)
            state = .suspendedPermissionDenied(bundleID: bundleID)
            logger.notice("browser_url_poller permission_denied bundle=\(bundleID, privacy: .public)")
            return
        case .targetMissing:
            // Browser quit between the watchdog tick and now; bounce back to
            // watching so the next mic-ownership tick re-evaluates.
            stopPolling(reason: .switchedBrowser)
            state = .watching
            return
        case .error:
            // Treat as transient and keep polling; the watchdog will
            // re-evaluate next tick.
            break
        }

        appleScriptInvocations += 1
        let rawURL = await urlFetcher(bundleID)
        guard let rawURL, !rawURL.isEmpty else { return }
        guard let match = BrowserMeetingURLMatcher.match(rawURL) else { return }
        guard lastEmittedURL != match.normalizedURL else { return }
        lastEmittedURL = match.normalizedURL

        let appName = Self.browserDisplayNames[bundleID] ?? bundleID
        let signal = AutoCaptureSignal(
            appName: appName,
            bundleID: bundleID,
            meetingTitle: match.platformName,
            hasCalendarMatch: false
        )
        signalHandler(signal)
        logger.notice(
            "browser_url_poller match_emitted bundle=\(bundleID, privacy: .public) platform=\(match.platformName, privacy: .public)"
        )
    }
}

// MARK: - Default dependencies

extension BrowserURLPoller {
    /// Production mic-ownership probe. Uses `AudioProcessAttributionCollector`
    /// (the same primitive `MeetingMonitor` relies on) to identify which
    /// processes are currently using a microphone input device.
    static func defaultMicOwnershipProbe() -> MicOwnershipProbe {
        let collector = AudioProcessAttributionCollector()
        return { @MainActor in
            Set(collector.activeInputProcesses().map(\.bundleID))
        }
    }

    /// Production URL fetcher. Runs a per-browser AppleScript snippet via
    /// `NSAppleScript`, mirroring the snippets that
    /// `BrowserMeetingActivityCollector` uses for the existing detector path.
    @MainActor
    static func defaultURLFetcher(_ bundleID: String) async -> String? {
        let source: String
        switch bundleID {
        case BrowserURLPollingConfig.safariBundleID:
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of current tab of front window
            end tell
            """
        case BrowserURLPollingConfig.chromeBundleID,
             BrowserURLPollingConfig.braveBundleID,
             BrowserURLPollingConfig.arcBundleID,
             BrowserURLPollingConfig.edgeBundleID:
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        default:
            return nil
        }

        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        guard let output = script?.executeAndReturnError(&errorInfo).stringValue,
              !output.isEmpty else {
            return nil
        }
        return output
    }
}
