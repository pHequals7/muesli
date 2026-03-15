import AppKit
import AVFoundation
import Foundation

@MainActor
final class MuesliController: NSObject {
    private let runtime: RuntimePaths
    private let configStore = ConfigStore()
    private let dictationStore = DictationStore()
    private let workerClient: PythonWorkerClient
    private let transcriptionCoordinator: TranscriptionCoordinator
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = MicrophoneRecorder()
    private let indicator: FloatingIndicatorController
    private let calendarMonitor = CalendarMonitor()

    private var statusBarController: StatusBarController?
    private var historyWindowController: RecentHistoryWindowController?
    private var preferencesWindowController: PreferencesWindowController?

    let appState = AppState()

    private(set) var config: AppConfig
    private(set) var selectedBackend: BackendOption
    private(set) var selectedMeetingSummaryBackend: MeetingSummaryBackendOption
    private var activeMeetingSession: MeetingSession?
    private var dictationStartedAt: Date?
    private var openWindowCount = 0
    private var lastExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?

    init(runtime: RuntimePaths) {
        let loadedConfig = configStore.load()
        self.runtime = runtime
        self.config = loadedConfig
        self.selectedBackend = BackendOption.all.first(where: {
            $0.backend == loadedConfig.sttBackend && $0.model == loadedConfig.sttModel
        }) ?? .whisper
        self.selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == loadedConfig.meetingSummaryBackend
        }) ?? .openAI
        self.workerClient = PythonWorkerClient(runtime: runtime)
        self.transcriptionCoordinator = TranscriptionCoordinator(workerClient: workerClient)
        self.indicator = FloatingIndicatorController(configStore: configStore)
        super.init()
    }

    func start() {
        do {
            try dictationStore.migrateIfNeeded()
        } catch {
            fputs("[muesli-native] startup error: \(error)\n", stderr)
        }

        // Clean up leftover audio temp files from previous sessions
        let tempAudioDir = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-system-audio")
        if let files = try? FileManager.default.contentsOfDirectory(at: tempAudioDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            if !files.isEmpty {
                fputs("[muesli-native] cleaned up \(files.count) leftover temp audio files\n", stderr)
            }
        }

        do {
            try workerClient.start()
        } catch {
            fputs("[muesli-native] worker start failed: \(error)\n", stderr)
        }

        hotkeyMonitor.targetKeyCode = config.dictationHotkey.keyCode
        hotkeyMonitor.onPrepare = { [weak self] in self?.handlePrepare() }
        hotkeyMonitor.onStart = { [weak self] in self?.handleStart() }
        hotkeyMonitor.onStop = { [weak self] in self?.handleStop() }
        hotkeyMonitor.onCancel = { [weak self] in self?.handleCancel() }
        hotkeyMonitor.start()
        indicator.onStopMeeting = { [weak self] in self?.stopMeetingRecording() }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app != NSRunningApplication.current
            else { return }
            self?.lastExternalApp = app
        }

        statusBarController = StatusBarController(controller: self, runtime: runtime)
        preferencesWindowController = PreferencesWindowController(controller: self)
        historyWindowController = RecentHistoryWindowController(store: dictationStore, controller: self)
        refreshUI()

        calendarMonitor.onMeetingSoon = { [weak self] event in
            self?.handleUpcomingMeeting(event)
        }
        calendarMonitor.start()

        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.preload(backend: self.selectedBackend)
            await MainActor.run {
                self.refreshUI()
            }
        }

        if config.openDashboardOnLaunch {
            openHistoryWindow()
        }
    }

    func shutdown() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        hotkeyMonitor.stop()
        calendarMonitor.stop()
        recorder.cancel()
        Task {
            await transcriptionCoordinator.shutdown()
        }
        indicator.close()
    }

    func recentDictations() -> [DictationRecord] {
        (try? dictationStore.recentDictations(limit: 10)) ?? []
    }

    func recentMeetings() -> [MeetingRecord] {
        (try? dictationStore.recentMeetings(limit: 10)) ?? []
    }

    func dictationStats() -> DictationStats {
        (try? dictationStore.dictationStats()) ?? DictationStats(
            totalWords: 0,
            totalSessions: 0,
            averageWordsPerSession: 0,
            averageWPM: 0,
            currentStreakDays: 0,
            longestStreakDays: 0
        )
    }

    func meetingStats() -> MeetingStats {
        (try? dictationStore.meetingStats()) ?? MeetingStats(totalWords: 0, totalMeetings: 0, averageWPM: 0)
    }

    func truncate(_ text: String, limit: Int) -> String {
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 3)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    func refreshIndicatorVisibility() {
        if config.showFloatingIndicator {
            indicator.ensureVisible(config: config)
        } else {
            indicator.close()
        }
    }

    func refreshUI() {
        statusBarController?.setStatus("Idle")
        statusBarController?.refresh()
        historyWindowController?.updateBackendLabel()
        historyWindowController?.reload()
        preferencesWindowController?.refresh()
        refreshIndicatorVisibility()
        syncAppState()
    }

    func syncAppState() {
        appState.dictationRows = (try? dictationStore.recentDictations(limit: 50)) ?? []
        appState.meetingRows = (try? dictationStore.recentMeetings(limit: 50)) ?? []
        appState.dictationStats = dictationStats()
        appState.meetingStats = meetingStats()
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.config = config
        appState.isMeetingRecording = isMeetingRecording()
    }

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        configStore.save(config)
        selectedBackend = BackendOption.all.first(where: {
            $0.backend == config.sttBackend && $0.model == config.sttModel
        }) ?? .whisper
        selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == config.meetingSummaryBackend
        }) ?? .openAI
        statusBarController?.refresh()
        historyWindowController?.updateBackendLabel()
        if config.showFloatingIndicator {
            indicator.ensureVisible(config: config)
        } else {
            indicator.close()
        }
    }

    func selectBackend(_ option: BackendOption) {
        updateConfig {
            $0.sttBackend = option.backend
            $0.sttModel = option.model
        }
        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.preload(backend: option)
            await MainActor.run {
                self.statusBarController?.refresh()
                self.historyWindowController?.updateBackendLabel()
            }
        }
    }

    func selectMeetingSummaryBackend(_ option: MeetingSummaryBackendOption) {
        updateConfig {
            $0.meetingSummaryBackend = option.backend
        }
    }

    func addCustomWord(_ word: CustomWord) {
        updateConfig { $0.customWords.append(word) }
    }

    func removeCustomWord(id: UUID) {
        updateConfig { $0.customWords.removeAll { $0.id == id } }
    }

    func updateDictationHotkey(_ hotkey: HotkeyConfig) {
        updateConfig { $0.dictationHotkey = hotkey }
        hotkeyMonitor.configure(keyCode: hotkey.keyCode)
    }

    @objc func openHistoryWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.show()
        }
    }

    func openHistoryWindow(tab: DashboardTab) {
        appState.selectedTab = tab
        syncAppState()
        DispatchQueue.main.async { [weak self] in
            self?.historyWindowController?.show()
        }
    }

    @objc func openPreferences() {
        openHistoryWindow(tab: .settings)
    }

    @objc func openSettingsTab() {
        openHistoryWindow(tab: .settings)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func copyRecentDictation(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            copyToClipboard(text)
        }
    }

    @objc func copyRecentMeeting(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            copyToClipboard(text)
        }
    }

    @objc func selectBackendFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let option = BackendOption.all.first(where: { $0.label == label }) else { return }
        selectBackend(option)
    }

    @objc func selectMeetingSummaryBackendFromMenu(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let option = MeetingSummaryBackendOption.all.first(where: { $0.label == label }) else { return }
        selectMeetingSummaryBackend(option)
    }

    func resummarize(meeting: MeetingRecord, completion: @escaping () -> Void) {
        Task { [weak self] in
            guard let self else { return }
            // Regenerate title from transcript
            let newTitle: String
            if let autoTitle = await MeetingSummaryClient.generateTitle(transcript: meeting.rawTranscript, config: self.config),
               !autoTitle.isEmpty {
                newTitle = autoTitle
            } else {
                newTitle = meeting.title
            }
            let notes = await MeetingSummaryClient.summarize(
                transcript: meeting.rawTranscript,
                meetingTitle: newTitle,
                config: self.config
            )
            try? self.dictationStore.updateMeeting(id: meeting.id, title: newTitle, formattedNotes: notes)
            await MainActor.run {
                self.syncAppState()
                self.historyWindowController?.reload()
                completion()
            }
        }
    }

    func clearDictationHistory() {
        try? dictationStore.clearDictations()
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    func clearMeetingHistory() {
        try? dictationStore.clearMeetings()
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    func isMeetingRecording() -> Bool {
        activeMeetingSession?.isRecording == true
    }

    @objc func toggleMeetingRecording() {
        if isMeetingRecording() {
            stopMeetingRecording()
        } else {
            startMeetingRecording()
        }
    }

    func startMeetingRecording(title: String = "Meeting") {
        guard !isMeetingRecording() else { return }
        let meetingSession = MeetingSession(
            title: title,
            calendarEventID: nil,
            backend: selectedBackend,
            runtime: runtime,
            config: config,
            transcriptionCoordinator: transcriptionCoordinator
        )
        do {
            try meetingSession.start()
            activeMeetingSession = meetingSession
            statusBarController?.setStatus("Meeting: \(title)")
            indicator.setMeetingRecording(true, config: config)
            statusBarController?.refresh()
        } catch {
            fputs("[muesli-native] failed to start meeting: \(error)\n", stderr)
            setState(.idle)
        }
    }

    func stopMeetingRecording() {
        guard let activeMeetingSession else { return }
        indicator.setMeetingRecording(false, config: config)
        setState(.transcribing)
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await activeMeetingSession.stop()
                try self.dictationStore.insertMeeting(
                    title: result.title,
                    calendarEventID: result.calendarEventID,
                    startTime: result.startTime,
                    endTime: result.endTime,
                    rawTranscript: result.rawTranscript,
                    formattedNotes: result.formattedNotes,
                    micAudioPath: result.micAudioPath,
                    systemAudioPath: result.systemAudioPath
                )
            } catch {
                fputs("[muesli-native] meeting transcription failed: \(error)\n", stderr)
            }
            await MainActor.run {
                self.activeMeetingSession = nil
                self.setState(.idle)
                self.statusBarController?.refresh()
                self.historyWindowController?.reload()
                self.syncAppState()
            }
        }
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func noteWindowOpened() {
        openWindowCount += 1
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func noteWindowClosed() {
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    private func setState(_ state: DictationState) {
        let status: String
        switch state {
        case .idle: status = "Idle"
        case .preparing: status = "Preparing"
        case .recording: status = "Recording"
        case .transcribing: status = "Transcribing"
        }
        statusBarController?.setStatus(status)
        indicator.setState(state, config: config)
    }

    private func handlePrepare() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] prepare\n", stderr)
        do {
            try recorder.prepare()
            setState(.preparing)
        } catch {
            fputs("[muesli-native] recorder prepare failed: \(error)\n", stderr)
            setState(.idle)
        }
    }

    private func handleStart() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] recording start\n", stderr)
        do {
            try recorder.start()
            dictationStartedAt = Date()
            indicator.powerProvider = { [weak self] in
                self?.recorder.currentPower() ?? -160
            }
            setState(.recording)
        } catch {
            fputs("[muesli-native] recorder start failed: \(error)\n", stderr)
            setState(.idle)
        }
    }

    private func handleCancel() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] cancel\n", stderr)
        recorder.cancel()
        dictationStartedAt = nil
        setState(.idle)
    }

    private func handleStop() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] stop\n", stderr)
        let startedAt = dictationStartedAt ?? Date()
        dictationStartedAt = nil
        guard let wavURL = recorder.stop() else {
            fputs("[muesli-native] stop without wav\n", stderr)
            setState(.idle)
            return
        }
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        if duration < 0.3 {
            fputs("[muesli-native] discarded short recording\n", stderr)
            try? FileManager.default.removeItem(at: wavURL)
            setState(.idle)
            return
        }

        setState(.transcribing)
        Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            do {
                let result = try await self.transcriptionCoordinator.transcribeDictation(
                    at: wavURL,
                    backend: self.selectedBackend,
                    customWords: self.serializedCustomWords()
                )
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    await MainActor.run {
                        self.setState(.idle)
                    }
                    return
                }
                try? self.dictationStore.insertDictation(
                    text: text,
                    durationSeconds: duration,
                    startedAt: startedAt,
                    endedAt: Date()
                )
                await MainActor.run {
                    self.statusBarController?.refresh()
                    self.historyWindowController?.reload()
                    self.syncAppState()
                    PasteController.paste(text: text)
                    self.setState(.idle)
                }
            } catch {
                fputs("[muesli-native] transcription failed: \(error)\n", stderr)
                await MainActor.run {
                    self.setState(.idle)
                }
            }
        }
    }

    private func handleUpcomingMeeting(_ event: UpcomingMeetingEvent) {
        fputs("[muesli-native] meeting soon: \(event.title)\n", stderr)
        if config.autoRecordMeetings, !isMeetingRecording() {
            startMeetingRecording(title: event.title)
        }
    }

    func serializedCustomWords() -> [[String: Any]] {
        config.customWords.map { word in
            var dict: [String: Any] = ["word": word.word]
            if let replacement = word.replacement {
                dict["replacement"] = replacement
            }
            return dict
        }
    }
}
