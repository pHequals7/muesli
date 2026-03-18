import AppKit
import AVFoundation
import Foundation
import Sparkle
import MuesliCore

@MainActor
final class MuesliController: NSObject {
    private let runtime: RuntimePaths
    private let configStore = ConfigStore()
    private let dictationStore = DictationStore()
    let transcriptionCoordinator = TranscriptionCoordinator()
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = MicrophoneRecorder()
    private let indicator: FloatingIndicatorController
    private let calendarMonitor = CalendarMonitor()
    private let micActivityMonitor = MicActivityMonitor()
    private let meetingNotification = MeetingNotificationController()

    private let chatGPTAuth = ChatGPTAuthManager.shared

    private var statusBarController: StatusBarController?
    private var historyWindowController: RecentHistoryWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    var updaterController: SPUStandardUpdaterController?

    let appState = AppState()

    private(set) var config: AppConfig
    private(set) var selectedBackend: BackendOption
    private(set) var selectedMeetingSummaryBackend: MeetingSummaryBackendOption
    private var activeMeetingSession: MeetingSession?
    private var dictationStartedAt: Date?
    private var _streamingDictationController: Any?  // StreamingDictationController (macOS 15+)
    private var isNemotronStreaming = false
    private var previousStreamText = ""
    private var openWindowCount = 0
    private var lastExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var dataDidChangeObserver: NSObjectProtocol?

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

        hotkeyMonitor.targetKeyCode = config.dictationHotkey.keyCode
        hotkeyMonitor.onPrepare = { [weak self] in self?.handlePrepare() }
        hotkeyMonitor.onStart = { [weak self] in self?.handleStart() }
        hotkeyMonitor.onStop = { [weak self] in self?.handleStop() }
        hotkeyMonitor.onCancel = { [weak self] in self?.handleCancel() }
        hotkeyMonitor.onToggleStart = { [weak self] in self?.handleToggleStart() }
        hotkeyMonitor.onToggleStop = { [weak self] in self?.handleToggleStop() }
        hotkeyMonitor.doubleTapEnabled = config.enableDoubleTapDictation
        hotkeyMonitor.start()
        indicator.hotkeyLabel = config.dictationHotkey.label
        indicator.onStopMeeting = { [weak self] in self?.stopMeetingRecording() }
        indicator.onDiscardMeeting = { [weak self] in self?.discardMeetingRecording() }
        indicator.onStopToggleDictation = { [weak self] in
            self?.hotkeyMonitor.stopToggleMode()
        }
        indicator.onCancelToggleDictation = { [weak self] in
            self?.handleCancel()
            self?.indicator.isToggleDictation = false
            self?.hotkeyMonitor.cancelToggleMode()
        }
        hotkeyMonitor.onEscapePressed = { [weak self] in
            guard let self else { return }
            if self.isMeetingRecording() {
                self.discardMeetingWithConfirmation()
            }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app != NSRunningApplication.current
            else { return }
            Task { @MainActor [weak self] in
                self?.lastExternalApp = app
            }
        }
        dataDidChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: MuesliNotifications.dataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.historyWindowController?.reload()
                self.syncAppState()
            }
        }

        statusBarController = StatusBarController(controller: self, runtime: runtime)
        preferencesWindowController = PreferencesWindowController(controller: self)
        historyWindowController = RecentHistoryWindowController(store: dictationStore, controller: self)
        refreshUI()

        calendarMonitor.onMeetingSoon = { [weak self] event in
            self?.handleUpcomingMeeting(event)
        }
        calendarMonitor.start()

        micActivityMonitor.calendarEventProvider = { [weak self] in
            self?.calendarMonitor.currentOrNearbyEvent()
        }
        micActivityMonitor.onMeetingDetected = { [weak self] detection in
            guard let self,
                  !self.isMeetingRecording(),
                  self.config.showMeetingDetectionNotification else { return }
            let title = detection.meetingTitle ?? detection.appName
            self.meetingNotification.show(
                title: "Meeting detected",
                subtitle: title,
                onStartRecording: { [weak self] in
                    self?.micActivityMonitor.suppress()
                    self?.startMeetingRecording(title: title)
                },
                onDismiss: { [weak self] in
                    self?.micActivityMonitor.suppress()
                }
            )
        }
        micActivityMonitor.start()

        Task { [weak self] in
            guard let self else { return }
            await self.transcriptionCoordinator.preload(backend: self.selectedBackend)
            await MainActor.run {
                self.refreshUI()
            }
        }

        if !config.hasCompletedOnboarding {
            showOnboarding()
        } else if config.openDashboardOnLaunch {
            openHistoryWindow()
        }
    }

    func shutdown() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let dataDidChangeObserver {
            DistributedNotificationCenter.default().removeObserver(dataDidChangeObserver)
            self.dataDidChangeObserver = nil
        }
        hotkeyMonitor.stop()
        calendarMonitor.stop()
        micActivityMonitor.stop()
        meetingNotification.close()
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
        let rows = (try? dictationStore.recentDictations(
            limit: appState.dictationPageSize,
            offset: 0,
            fromDate: appState.dictationFromDate,
            toDate: appState.dictationToDate
        )) ?? []
        appState.dictationRows = rows
        appState.hasMoreDictations = rows.count >= appState.dictationPageSize
        appState.meetingRows = (try? dictationStore.recentMeetings(limit: 50)) ?? []
        appState.folders = (try? dictationStore.listFolders()) ?? []
        appState.dictationStats = dictationStats()
        appState.meetingStats = meetingStats()
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.config = config
        appState.isMeetingRecording = isMeetingRecording()
        appState.isChatGPTAuthenticated = chatGPTAuth.isAuthenticated
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

    func signInWithChatGPT() async {
        do {
            try await chatGPTAuth.signIn()
            selectMeetingSummaryBackend(.chatGPT)
            syncAppState()
        } catch {
            fputs("[muesli-native] ChatGPT sign-in failed: \(error)\n", stderr)
        }
    }

    func signOutChatGPT() {
        chatGPTAuth.signOut()
        if selectedMeetingSummaryBackend == .chatGPT {
            selectMeetingSummaryBackend(.openAI)
        }
        syncAppState()
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
        indicator.hotkeyLabel = hotkey.label
    }

    // MARK: - Onboarding

    func showOnboarding() {
        let wc = OnboardingWindowController(controller: self)
        self.onboardingWindowController = wc
        wc.show()
    }

    func downloadModelForOnboarding(_ backend: BackendOption, progress: @escaping (Double, String?) -> Void) async throws -> Bool {
        progress(0.0, "Downloading \(backend.label)...")
        await transcriptionCoordinator.preload(backend: backend, progress: progress)
        progress(1.0, nil)
        return false
    }

    func completeOnboarding(userName: String, backend: BackendOption, hotkey: HotkeyConfig, summaryBackend: MeetingSummaryBackendOption?, apiKey: String?) {
        updateConfig { config in
            config.hasCompletedOnboarding = true
            config.userName = userName
            config.sttBackend = backend.backend
            config.sttModel = backend.model
            config.dictationHotkey = hotkey
            if let summaryBackend {
                config.meetingSummaryBackend = summaryBackend.backend
            }
            if let apiKey, !apiKey.isEmpty {
                if summaryBackend == .openAI {
                    config.openAIAPIKey = apiKey
                } else if summaryBackend == .openRouter {
                    config.openRouterAPIKey = apiKey
                }
                // ChatGPT backend uses OAuth tokens in Keychain, not an API key
            }
        }
        selectBackend(backend)
        hotkeyMonitor.configure(keyCode: hotkey.keyCode)
        onboardingWindowController?.close()
        onboardingWindowController = nil
        openHistoryWindow()
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

    @objc func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
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
        if option == .chatGPT, !chatGPTAuth.isAuthenticated {
            Task { await signInWithChatGPT() }
            return
        }
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

    // MARK: - Meeting Editing

    func updateMeetingTitle(id: Int64, title: String) {
        try? dictationStore.updateMeetingTitle(id: id, title: title)
        syncAppState()
    }

    func updateMeetingNotes(id: Int64, notes: String) {
        try? dictationStore.updateMeetingNotes(id: id, formattedNotes: notes)
        syncAppState()
    }

    // MARK: - Folder Management

    @discardableResult
    func createFolder(name: String) -> Int64? {
        let id = try? dictationStore.createFolder(name: name)
        syncAppState()
        return id
    }

    func renameFolder(id: Int64, name: String) {
        try? dictationStore.renameFolder(id: id, name: name)
        syncAppState()
    }

    func deleteFolder(id: Int64) {
        try? dictationStore.deleteFolder(id: id)
        if appState.selectedFolderID == id {
            appState.selectedFolderID = nil
        }
        syncAppState()
    }

    func moveMeeting(id: Int64, toFolder folderID: Int64?) {
        try? dictationStore.moveMeeting(id: id, toFolder: folderID)
        syncAppState()
    }

    func loadMoreDictations() {
        guard appState.hasMoreDictations else { return }
        let offset = appState.dictationRows.count
        let more = (try? dictationStore.recentDictations(
            limit: appState.dictationPageSize,
            offset: offset,
            fromDate: appState.dictationFromDate,
            toDate: appState.dictationToDate
        )) ?? []
        appState.dictationRows.append(contentsOf: more)
        appState.hasMoreDictations = more.count >= appState.dictationPageSize
    }

    func filterDictations(from: Date?, to: Date?) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        appState.dictationFromDate = from.map { formatter.string(from: $0) }
        appState.dictationToDate = to.map { formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: $0)!) }
        syncAppState()
    }

    func clearDictationFilter() {
        appState.dictationFromDate = nil
        appState.dictationToDate = nil
        syncAppState()
    }

    func deleteDictation(id: Int64) {
        try? dictationStore.deleteDictation(id: id)
        syncAppState()
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
            micActivityMonitor.suppressWhileActive()
            statusBarController?.setStatus("Meeting: \(title)")
            indicator.powerProvider = { [weak meetingSession] in
                meetingSession?.currentPower() ?? -160
            }
            indicator.setMeetingRecording(true, config: config)
            statusBarController?.refresh()
        } catch {
            fputs("[muesli-native] failed to start meeting: \(error)\n", stderr)
            setState(.idle)
        }
    }

    @objc func discardMeetingWithConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Discard recording?"
        alert.informativeText = "This will stop the meeting recording and delete all captured audio. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            discardMeetingRecording()
        }
    }

    func discardMeetingRecording() {
        guard let activeMeetingSession else { return }
        activeMeetingSession.discard()
        self.activeMeetingSession = nil
        indicator.setMeetingRecording(false, config: config)
        micActivityMonitor.resumeAfterCooldown()
        setState(.idle)
        statusBarController?.refresh()
        syncAppState()
        fputs("[muesli-native] meeting recording discarded\n", stderr)
    }

    func stopMeetingRecording() {
        guard let activeMeetingSession else { return }
        indicator.setMeetingRecording(false, config: config)
        setState(.transcribing)
        Task { [weak self] in
            guard let self else { return }
            var meetingTitle = "Meeting"
            do {
                let result = try await activeMeetingSession.stop()
                meetingTitle = result.title
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
                self.micActivityMonitor.resumeAfterCooldown()
                self.statusBarController?.refresh()
                self.historyWindowController?.reload()
                self.syncAppState()

                self.meetingNotification.show(
                    title: "Transcription complete",
                    subtitle: meetingTitle,
                    actionLabel: "View Notes",
                    onStartRecording: { [weak self] in
                        self?.openHistoryWindow(tab: .meetings)
                    }
                )
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

        // Nemotron is handsfree-only — block hold-to-talk and show a hint
        if selectedBackend.backend == "nemotron" {
            recorder.cancel()
            fputs("[muesli-native] hold-to-talk blocked for Nemotron, showing warning\n", stderr)
            indicator.showWarning("Double-tap for Nemotron handsfree mode", icon: "⚡")
            return
        }

        fputs("[muesli-native] recording start\n", stderr)
        micActivityMonitor.suppressWhileActive()

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

    @available(macOS 15, *)
    private func startNemotronStreamingAsync() {
        Task {
            let transcriber = await transcriptionCoordinator.getNemotronTranscriber()
            fputs("[muesli-native] got Nemotron transcriber\n", stderr)

            let controller = StreamingDictationController(transcriber: transcriber)
            controller.onPartialText = { [weak self] fullText in
                guard let self else { return }
                let delta = String(fullText.dropFirst(self.previousStreamText.count))
                fputs("[muesli-native] streaming partial: +\"\(delta)\" (total \(fullText.count) chars)\n", stderr)
                if !delta.isEmpty {
                    self.previousStreamText = fullText
                    DispatchQueue.main.async {
                        PasteController.typeText(delta)
                    }
                }
            }

            await MainActor.run {
                self._streamingDictationController = controller
                controller.start()
                fputs("[muesli-native] Nemotron streaming controller started\n", stderr)
            }
        }
    }

    private func handleCancel() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] cancel\n", stderr)

        if isNemotronStreaming {
            isNemotronStreaming = false
            if #available(macOS 15, *), let sdc = _streamingDictationController as? StreamingDictationController {
                let _ = sdc.stop()
            }
            _streamingDictationController = nil
            previousStreamText = ""
        }

        recorder.cancel()
        dictationStartedAt = nil
        setState(.idle)
    }

    private func handleToggleStart() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] toggle dictation start\n", stderr)
        micActivityMonitor.suppressWhileActive()

        // Nemotron streaming: live text at cursor in handsfree mode too
        if selectedBackend.backend == "nemotron" {
            if #available(macOS 15, *) {
                isNemotronStreaming = true
                previousStreamText = ""
                dictationStartedAt = Date()
                indicator.setToggleDictation(true, config: config)
                fputs("[muesli-native] Nemotron streaming toggle mode active\n", stderr)
                startNemotronStreamingAsync()
                return
            }
        }

        do {
            try recorder.prepare()
            try recorder.start()
            dictationStartedAt = Date()
            indicator.powerProvider = { [weak self] in
                self?.recorder.currentPower() ?? -160
            }
            indicator.setToggleDictation(true, config: config)
        } catch {
            fputs("[muesli-native] toggle start failed: \(error)\n", stderr)
            setState(.idle)
        }
    }

    private func handleToggleStop() {
        fputs("[muesli-native] toggle dictation stop\n", stderr)
        indicator.isToggleDictation = false
        handleStop()
    }

    private func handleStop() {
        if isMeetingRecording() { return }
        fputs("[muesli-native] stop\n", stderr)
        let startedAt = dictationStartedAt ?? Date()
        dictationStartedAt = nil

        // Nemotron streaming: text already typed — just finalize and store
        if isNemotronStreaming {
            isNemotronStreaming = false
            var finalText = ""
            if #available(macOS 15, *), let controller = _streamingDictationController as? StreamingDictationController {
                finalText = controller.stop()
                fputs("[muesli-native] Nemotron streaming stop, got \(finalText.count) chars\n", stderr)
            } else {
                fputs("[muesli-native] Nemotron streaming stop, controller not ready (short press)\n", stderr)
            }
            _streamingDictationController = nil
            previousStreamText = ""

            let duration = max(Date().timeIntervalSince(startedAt), 0)
            let cleaned = FillerWordFilter.apply(finalText)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleaned.isEmpty {
                try? dictationStore.insertDictation(
                    text: cleaned,
                    durationSeconds: duration,
                    startedAt: startedAt,
                    endedAt: Date()
                )
            }

            statusBarController?.refresh()
            historyWindowController?.reload()
            syncAppState()
            setState(.idle)
            micActivityMonitor.resumeAfterCooldown()
            fputs("[muesli-native] Nemotron streaming done (\(String(format: "%.1f", duration))s)\n", stderr)
            return
        }

        // Standard path: stop recording → transcribe → paste
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
                    self.micActivityMonitor.resumeAfterCooldown()
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
