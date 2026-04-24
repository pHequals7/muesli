import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("MeetingCandidateResolver")
struct MeetingCandidateResolverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func resolver() -> MeetingCandidateResolver {
        let resolver = MeetingCandidateResolver()
        resolver.selfBundleID = "com.muesli.app"
        return resolver
    }

    private func snapshot(
        micActive: Bool = true,
        cameraActive: Bool = true,
        calendarEvent: CalendarEventContext? = nil,
        runningApps: [RunningAppInfo] = [],
        browserMeetings: [BrowserMeetingContext] = [],
        audioInputProcesses: [AudioProcessActivity] = [],
        foregroundBundleID: String? = nil
    ) -> MeetingSignalSnapshot {
        MeetingSignalSnapshot(
            micActive: micActive,
            cameraActive: cameraActive,
            calendarEvent: calendarEvent,
            runningApps: runningApps,
            browserMeetings: browserMeetings,
            audioInputProcesses: audioInputProcesses,
            foregroundBundleID: foregroundBundleID,
            now: now
        )
    }

    @Test("Chrome Meet active beats background WhatsApp")
    func chromeMeetBeatsBackgroundWhatsApp() {
        let candidate = resolver().resolve(snapshot(
            runningApps: [
                RunningAppInfo(bundleID: "net.whatsapp.WhatsApp", isActive: false),
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: true),
            ],
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: true
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(candidate?.platform == .googleMeet)
        #expect(candidate?.appName == "Chrome")
    }

    @Test("Chrome Meet audio input beats background WhatsApp")
    func chromeMeetAudioInputBeatsBackgroundWhatsApp() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            runningApps: [
                RunningAppInfo(bundleID: "net.whatsapp.WhatsApp", isActive: false),
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: true),
            ],
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    pid: 1234,
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: true
                ),
            ],
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 1234,
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(candidate?.platform == .googleMeet)
        #expect(candidate?.appName == "Chrome")
        #expect(candidate?.sourcePID == 1234)
        #expect(candidate?.evidence.contains(.audioInputProcess) == true)
    }

    @Test("focused Meet URL is eligible before mic flips")
    func focusedMeetURLIsEligibleBeforeMicFlips() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            browserMeetings: [
                BrowserMeetingContext(
                    bundleID: "com.google.Chrome",
                    appName: "Chrome",
                    pid: 1234,
                    url: "meet.google.com/pwm-txwq-txy",
                    normalizedID: "googleMeet:meet.google.com/pwm-txwq-txy",
                    platform: .googleMeet,
                    isFocused: true
                ),
            ],
            foregroundBundleID: "com.google.Chrome"
        ))

        #expect(candidate?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(candidate?.platform == .googleMeet)
        #expect(candidate?.sourceBundleID == "com.google.Chrome")
    }

    @Test("Teams active audio input resolves to Teams")
    func teamsActiveAudioInputResolvesToTeams() {
        let candidate = resolver().resolve(snapshot(
            micActive: false,
            cameraActive: false,
            audioInputProcesses: [
                AudioProcessActivity(
                    pid: 4321,
                    bundleID: "com.microsoft.teams2",
                    appName: "Microsoft Teams",
                    isRunningInput: true,
                    isRunningOutput: false
                ),
            ]
        ))

        #expect(candidate?.id == "app:com.microsoft.teams2")
        #expect(candidate?.platform == .teams)
        #expect(candidate?.appName == "Microsoft Teams")
        #expect(candidate?.sourcePID == 4321)
    }

    @Test("different Meet URLs are different candidates")
    func differentMeetURLsAreDifferentCandidates() {
        let first = resolver().resolve(snapshot(browserMeetings: [
            BrowserMeetingContext(
                bundleID: "com.google.Chrome",
                appName: "Chrome",
                url: "meet.google.com/aaa-bbbb-ccc",
                normalizedID: "googleMeet:meet.google.com/aaa-bbbb-ccc",
                platform: .googleMeet,
                isFocused: true
            ),
        ]))

        let second = resolver().resolve(snapshot(browserMeetings: [
            BrowserMeetingContext(
                bundleID: "com.google.Chrome",
                appName: "Chrome",
                url: "meet.google.com/ddd-eeee-fff",
                normalizedID: "googleMeet:meet.google.com/ddd-eeee-fff",
                platform: .googleMeet,
                isFocused: true
            ),
        ]))

        #expect(first?.id != second?.id)
    }

    @Test("URL normalizer extracts stable Google Meet identity")
    func googleMeetURLNormalization() {
        let normalized = MeetingURLNormalizer.normalize("https://meet.google.com/pwm-txwq-txy?authuser=0")

        #expect(normalized?.id == "googleMeet:meet.google.com/pwm-txwq-txy")
        #expect(normalized?.url == "meet.google.com/pwm-txwq-txy")
        #expect(normalized?.platform == .googleMeet)
    }
}
