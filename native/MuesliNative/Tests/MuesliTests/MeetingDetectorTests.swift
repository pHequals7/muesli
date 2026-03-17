import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingDetector")
struct MeetingDetectorTests {

    private func makeDetector() -> MeetingDetector {
        let d = MeetingDetector()
        d.selfBundleID = "com.muesli.app"
        return d
    }

    // MARK: - Calendar + Mic (Priority 1, strongest signal)

    @Test("mic active + calendar event triggers with event title")
    func calendarPlusMicTriggers() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Sprint Planning"),
            runningApps: []
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.meetingTitle == "Sprint Planning")
        #expect(result?.appName == "Meeting")  // no app identified
    }

    @Test("calendar + mic + Zoom running uses Zoom as app name")
    func calendarPlusMicWithZoom() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Standup"),
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.appName == "Zoom")
        #expect(result?.meetingTitle == "Standup")
    }

    @Test("calendar + mic + Chrome frontmost uses Chrome as app name")
    func calendarPlusMicWithChromeFront() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "1:1"),
            runningApps: [RunningAppInfo(bundleID: "com.google.Chrome", isActive: true)]
        )
        let result = d.evaluate(signals)
        #expect(result?.appName == "Chrome")
        #expect(result?.meetingTitle == "1:1")
    }

    @Test("calendar + mic + Chrome background still triggers (calendar overrides)")
    func calendarOverridesBrowserBackground() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Team sync"),
            runningApps: [RunningAppInfo(bundleID: "com.google.Chrome", isActive: false)]
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.meetingTitle == "Team sync")
    }

    // MARK: - Dedicated Apps + Mic (Priority 2)

    @Test("mic active + Zoom running triggers")
    func zoomPlusMic() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.appName == "Zoom")
        #expect(result?.meetingTitle == nil)
    }

    @Test("mic active + Teams running triggers")
    func teamsPlusMic() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.microsoft.teams2", isActive: false)]
        )
        #expect(d.evaluate(signals)?.appName == "Teams")
    }

    @Test("mic active + FaceTime running triggers")
    func faceTimePlusMic() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.apple.FaceTime", isActive: false)]
        )
        #expect(d.evaluate(signals)?.appName == "FaceTime")
    }

    @Test("mic active + Slack running triggers")
    func slackPlusMic() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.tinyspeck.slackmacgap", isActive: false)]
        )
        #expect(d.evaluate(signals)?.appName == "Slack")
    }

    // MARK: - Browser + Mic (Priority 3, weakest)

    @Test("mic active + Chrome frontmost triggers")
    func chromeFrontmostPlusMic() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.google.Chrome", isActive: true)]
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.appName == "Chrome")
    }

    @Test("mic active + Chrome background does NOT trigger without calendar")
    func chromeBackgroundNoCalendar() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.google.Chrome", isActive: false)]
        )
        #expect(d.evaluate(signals) == nil)
    }

    @Test("mic active + Arc frontmost triggers")
    func arcFrontmostPlusMic() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "company.thebrowser.Browser", isActive: true)]
        )
        #expect(d.evaluate(signals)?.appName == "Arc")
    }

    @Test("mic active + Safari background does NOT trigger")
    func safariBackgroundNoTrigger() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.apple.Safari", isActive: false)]
        )
        #expect(d.evaluate(signals) == nil)
    }

    // MARK: - No trigger cases

    @Test("mic inactive never triggers even with calendar + apps")
    func micInactiveNoTrigger() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: false,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Meeting"),
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: true)]
        )
        #expect(d.evaluate(signals) == nil)
    }

    @Test("mic active + no apps + no calendar does not trigger")
    func micOnlyNoTrigger() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: []
        )
        #expect(d.evaluate(signals) == nil)
    }

    @Test("mic active + unknown app does not trigger")
    func unknownAppNoTrigger() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.example.randomapp", isActive: true)]
        )
        #expect(d.evaluate(signals) == nil)
    }

    @Test("own bundle ID never triggers")
    func selfBundleIDIgnored() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.muesli.app", isActive: true)]
        )
        #expect(d.evaluate(signals) == nil)
    }

    // MARK: - Deduplication

    @Test("same calendar event only triggers once")
    func calendarDedup() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Meeting"),
            runningApps: []
        )
        #expect(d.evaluate(signals) != nil)
        #expect(d.evaluate(signals) == nil)  // second eval — already detected
    }

    @Test("different calendar events trigger separately")
    func differentCalendarEvents() {
        let d = makeDetector()
        let s1 = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Meeting A"),
            runningApps: []
        )
        let s2 = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt2", title: "Meeting B"),
            runningApps: []
        )
        #expect(d.evaluate(s1)?.meetingTitle == "Meeting A")
        #expect(d.evaluate(s2)?.meetingTitle == "Meeting B")
    }

    @Test("same app only triggers once per session")
    func appDedup() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        #expect(d.evaluate(signals) != nil)
        #expect(d.evaluate(signals) == nil)
    }

    // MARK: - Idle reset

    @Test("detection resets after sustained idle period")
    func idleReset() {
        let d = makeDetector()
        let active = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        #expect(d.evaluate(active) != nil)
        #expect(d.evaluate(active) == nil)  // dedup

        // Simulate idle for threshold count
        let idle = MeetingSignals(micActive: false, cameraActive: false, calendarEvent: nil, runningApps: [])
        for _ in 0..<MeetingDetector.idleResetThreshold {
            _ = d.evaluate(idle)
        }

        // Should trigger again now
        #expect(d.evaluate(active) != nil)
    }

    @Test("idle count resets when mic becomes active")
    func idleCountResets() {
        let d = makeDetector()
        let idle = MeetingSignals(micActive: false, cameraActive: false, calendarEvent: nil, runningApps: [])
        let active = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )

        // Partial idle (not enough to reset)
        for _ in 0..<(MeetingDetector.idleResetThreshold - 1) {
            _ = d.evaluate(idle)
        }

        // Active interrupts — triggers
        let result = d.evaluate(active)
        #expect(result != nil)

        // More partial idle (counter should have reset)
        for _ in 0..<(MeetingDetector.idleResetThreshold - 1) {
            _ = d.evaluate(idle)
        }

        // Active again — should NOT trigger (not enough idle to clear dedup)
        #expect(d.evaluate(active) == nil)
    }

    // MARK: - App quit cleanup

    @Test("app quitting allows re-detection when it returns")
    func appQuitCleanup() {
        let d = makeDetector()
        let withZoom = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        #expect(d.evaluate(withZoom) != nil)

        // Zoom quits — not in running apps anymore
        let withoutZoom = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: []
        )
        _ = d.evaluate(withoutZoom)  // cleanup happens here

        // Zoom re-launches
        #expect(d.evaluate(withZoom) != nil)
    }

    // MARK: - Suppression

    @Test("suppressed detector returns nil")
    func suppressed() {
        let d = makeDetector()
        d.suppress(for: 60)
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Meeting"),
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: true)]
        )
        #expect(d.evaluate(signals) == nil)
    }

    @Test("suppression expires and detection resumes")
    func suppressionExpires() {
        let d = makeDetector()
        d.suppress(for: -1)  // already expired
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        #expect(d.evaluate(signals) != nil)
    }

    @Test("suppressWhileActive blocks all detection")
    func suppressWhileActive() {
        let d = makeDetector()
        d.suppressWhileActive()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Meeting"),
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: true)]
        )
        #expect(d.evaluate(signals) == nil)
    }

    // MARK: - Priority ordering

    @Test("calendar takes priority over app-only detection")
    func calendarPriority() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Sprint"),
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        let result = d.evaluate(signals)
        #expect(result?.meetingTitle == "Sprint")  // calendar title used
        #expect(result?.appName == "Zoom")  // app name enriched
    }

    @Test("dedicated app preferred over browser for app name")
    func dedicatedPreferredOverBrowser() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Meeting"),
            runningApps: [
                RunningAppInfo(bundleID: "com.google.Chrome", isActive: true),
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: false),
            ]
        )
        let result = d.evaluate(signals)
        #expect(result?.appName == "Zoom")  // dedicated app preferred
    }

    // MARK: - Multiple apps

    @Test("only one detection per evaluation cycle")
    func oneDetectionPerCycle() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: nil,
            runningApps: [
                RunningAppInfo(bundleID: "us.zoom.xos", isActive: false),
                RunningAppInfo(bundleID: "com.microsoft.teams2", isActive: false),
            ]
        )
        let first = d.evaluate(signals)
        #expect(first != nil)

        // Second eval triggers the other app
        let second = d.evaluate(signals)
        #expect(second != nil)
        #expect(first?.appName != second?.appName)
    }

    // MARK: - resetDetections

    @Test("resetDetections clears all state")
    func resetDetections() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: false,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Meeting"),
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        #expect(d.evaluate(signals) != nil)
        #expect(d.evaluate(signals) == nil)  // deduped

        d.resetDetections()
        #expect(d.evaluate(signals) != nil)  // triggers again
    }

    // MARK: - Camera detection (Priority 0)

    @Test("camera active alone triggers detection")
    func cameraAloneTriggers() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: false,
            cameraActive: true,
            calendarEvent: nil,
            runningApps: []
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.appName == "Meeting")
    }

    @Test("camera active + calendar event includes event title")
    func cameraPlusCalendar() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: false,
            cameraActive: true,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Design Review"),
            runningApps: []
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.meetingTitle == "Design Review")
    }

    @Test("camera active + Zoom running uses Zoom as app name")
    func cameraPlusZoom() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: false,
            cameraActive: true,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.appName == "Zoom")
    }

    @Test("camera active + Chrome background triggers (no frontmost required)")
    func cameraPlusChromeBackground() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: false,
            cameraActive: true,
            calendarEvent: nil,
            runningApps: [RunningAppInfo(bundleID: "com.google.Chrome", isActive: false)]
        )
        // Camera is strong enough signal — browser doesn't need to be frontmost
        let result = d.evaluate(signals)
        #expect(result != nil)
    }

    @Test("camera detection only triggers once (dedup)")
    func cameraDedup() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: false,
            cameraActive: true,
            calendarEvent: nil,
            runningApps: []
        )
        #expect(d.evaluate(signals) != nil)
        #expect(d.evaluate(signals) == nil)  // already detected
    }

    @Test("camera off + idle resets camera detection")
    func cameraIdleReset() {
        let d = makeDetector()
        let cameraOn = MeetingSignals(
            micActive: false,
            cameraActive: true,
            calendarEvent: nil,
            runningApps: []
        )
        #expect(d.evaluate(cameraOn) != nil)

        // Camera off for threshold count
        let idle = MeetingSignals(micActive: false, cameraActive: false, calendarEvent: nil, runningApps: [])
        for _ in 0..<MeetingDetector.idleResetThreshold {
            _ = d.evaluate(idle)
        }

        // Camera back on — should trigger again
        #expect(d.evaluate(cameraOn) != nil)
    }

    @Test("camera active takes priority over mic-only signals")
    func cameraPriorityOverMic() {
        let d = makeDetector()
        let signals = MeetingSignals(
            micActive: true,
            cameraActive: true,
            calendarEvent: CalendarEventContext(id: "evt1", title: "Standup"),
            runningApps: [RunningAppInfo(bundleID: "us.zoom.xos", isActive: false)]
        )
        let result = d.evaluate(signals)
        #expect(result != nil)
        #expect(result?.appName == "Zoom")
        #expect(result?.meetingTitle == "Standup")

        // Calendar should NOT re-trigger (camera detection already marked it)
        #expect(d.evaluate(signals) == nil)
    }
}
