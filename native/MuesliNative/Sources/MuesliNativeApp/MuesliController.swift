import AppKit
import AVFoundation
import Foundation
import Sparkle
import TelemetryDeck
import MuesliCore

struct MeetingResummarizationPlan: Equatable {
    let promptTitle: String
    let persistedTitle: String
}

enum MeetingResummarizationPolicy {
    static func plan(for meeting: MeetingRecord) -> MeetingResummarizationPlan {
        let trimmed = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptTitle = trimmed.isEmpty ? "Meeting" : trimmed
        return MeetingResummarizationPlan(
            promptTitle: promptTitle,
            persistedTitle: meeting.title
        )
    }
}

enum MeetingSummaryPersistenceError: Error, LocalizedError {
    case failedToSaveSummary(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failedToSaveSummary(let underlying):
            let detail = underlying.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "The updated meeting notes could not be saved."
            }
            return "The updated meeting notes could not be saved. \(detail)"
        }
    }
}

enum MeetingTemplateSelectionError: Error, LocalizedError {
    case templateNoLongerExists

    var errorDescription: String? {
        switch self {
        case .templateNoLongerExists:
            return "That template no longer exists. Choose another template and try again."
        }
    }
}

enum MeetingLifecycleError: Error, LocalizedError {
    case failedToSaveRecording(underlying: Error)
    case failedToDeleteRecording(underlying: Error)
    case failedToDeleteMeeting(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failedToSaveRecording(let underlying):
            return "The meeting finished transcribing, but the recording could not be saved. \(underlying.localizedDescription)"
        case .failedToDeleteRecording(let underlying):
            return "The saved meeting recording could not be deleted, so the meeting was left in place. \(underlying.localizedDescription)"
        case .failedToDeleteMeeting(let underlying):
            return "The meeting could not be deleted. \(underlying.localizedDescription)"
        }
    }
}

struct CompletedMeetingPersistenceResult {
    let meetingID: Int64
    let recordingSaveError: MeetingLifecycleError?
}

@MainActor
final class MuesliController: NSObject {
    private let runtime: RuntimePaths
    private let configStore = ConfigStore()
    private let dictationStore: DictationStore
    let transcriptionCoordinator = TranscriptionCoordinator()
    private let hotkeyMonitor = HotkeyMonitor()
    private let recorder = MicrophoneRecorder()
    private let indicator: FloatingIndicatorController
    private let calendarMonitor = CalendarMonitor()
    private let micActivityMonitor = MicActivityMonitor()
    private let meetingNotification = MeetingNotificationController()

    private let chatGPTAuth = ChatGPTAuthManager.shared
    private let googleCalAuth = GoogleCalendarAuthManager.shared
    private let googleCalClient = GoogleCalendarClient()
    private var calendarRefreshTimer: Timer?

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
    private var isStartingMeetingRecording = false
    private var currentMeetingDetection: MeetingDetection?
    private var presentedMeetingDetection: MeetingDetection?

    init(runtime: RuntimePaths, dictationStore: DictationStore? = nil) {
        let loadedConfig = configStore.load()
        self.runtime = runtime
        self.dictationStore = dictationStore ?? DictationStore(
            databaseURL: MuesliPaths.defaultDatabaseURL(appName: AppIdentity.supportDirectoryName)
        )
        self.config = loadedConfig
        if loadedConfig.recordingColorHex != "1e1e2e" {
            MuesliTheme.accentOverrideHex = loadedConfig.recordingColorHex
        }
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

        // Clean up leftover audio temp files from previous sessions.
        cleanupTemporaryDirectory(
            named: "muesli-system-audio",
            logDescription: "leftover temp audio files"
        )
        cleanupTemporaryDirectory(
            named: "muesli-meeting-recordings",
            logDescription: "leftover temp meeting recording files"
        )

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
        indicator.onDiscardMeeting = { [weak self] in self?.discardMeetingWithConfirmation() }
        indicator.onStopToggleDictation = { [weak self] in
            guard let self else { return }
            if self.hotkeyMonitor.isToggleRecording {
                self.hotkeyMonitor.stopToggleMode()
            } else {
                self.handleStop()
            }
        }
        indicator.onCancelToggleDictation = { [weak self] in
            self?.handleCancel()
            self?.indicator.isToggleDictation = false
            self?.hotkeyMonitor.cancelToggleMode()
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
        startCalendarRefreshTimer()

        micActivityMonitor.calendarEventProvider = { [weak self] in
            self?.calendarMonitor.currentOrNearbyEvent()
        }
        micActivityMonitor.onMeetingDetectionStateChanged = { [weak self] detection in
            guard let self else { return }
            self.currentMeetingDetection = detection
            self.updateMeetingNotificationVisibility()
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
        dismissPresentedMeetingDetection()
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

    func meeting(id: Int64) -> MeetingRecord? {
        if let row = appState.meetingRows.first(where: { $0.id == id }) {
            return row
        }
        return try? dictationStore.meeting(id: id)
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
            indicator.closeIfIdle()
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
        appState.meetingRows = (try? dictationStore.recentMeetings(limit: 200, folderID: appState.selectedFolderID)) ?? []
        let counts = (try? dictationStore.meetingCounts()) ?? (total: 0, byFolder: [:])
        appState.totalMeetingCount = counts.total
        appState.meetingCountsByFolder = counts.byFolder
        if let selectedMeetingID = appState.selectedMeetingID {
            appState.selectedMeetingRecord = appState.meetingRows.first(where: { $0.id == selectedMeetingID })
                ?? meeting(id: selectedMeetingID)
        } else {
            appState.selectedMeetingRecord = nil
        }
        let allFolders = (try? dictationStore.listFolders()) ?? []
        if config.folderOrder.isEmpty && !allFolders.isEmpty {
            updateConfig { $0.folderOrder = allFolders.map(\.id) }
        }
        let order = config.folderOrder
        appState.folders = allFolders.sorted { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            return ai < bi
        }
        appState.dictationStats = dictationStats()
        appState.meetingStats = meetingStats()
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.config = config
        appState.isMeetingRecording = isMeetingRecording()
        appState.isChatGPTAuthenticated = chatGPTAuth.isAuthenticated
        appState.isGoogleCalendarAvailable = googleCalAuth.isAvailable
        appState.isGoogleCalendarAuthenticated = googleCalAuth.isAuthenticated
    }

    func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        configStore.save(config)
        MuesliTheme.accentOverrideHex = config.recordingColorHex == "1e1e2e" ? nil : config.recordingColorHex
        selectedBackend = BackendOption.all.first(where: {
            $0.backend == config.sttBackend && $0.model == config.sttModel
        }) ?? .whisper
        selectedMeetingSummaryBackend = MeetingSummaryBackendOption.all.first(where: {
            $0.backend == config.meetingSummaryBackend
        }) ?? .openAI
        statusBarController?.refresh()
        statusBarController?.refreshIcon()
        historyWindowController?.updateBackendLabel()
        if config.showFloatingIndicator {
            indicator.ensureVisible(config: config)
        } else {
            indicator.closeIfIdle()
        }
        appState.selectedBackend = selectedBackend
        appState.selectedMeetingSummaryBackend = selectedMeetingSummaryBackend
        appState.config = config
        appState.isChatGPTAuthenticated = chatGPTAuth.isAuthenticated
        updateMeetingNotificationVisibility()
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

    func availableMeetingTemplates() -> [MeetingTemplateDefinition] {
        MeetingTemplates.allDefinitions(customTemplates: config.customMeetingTemplates)
    }

    func builtInMeetingTemplates() -> [MeetingTemplateDefinition] {
        MeetingTemplates.builtIns
    }

    func customMeetingTemplates() -> [CustomMeetingTemplate] {
        config.customMeetingTemplates
    }

    func defaultMeetingTemplate() -> MeetingTemplateSnapshot {
        MeetingTemplates.resolveSnapshot(
            id: config.defaultMeetingTemplateID,
            customTemplates: config.customMeetingTemplates
        )
    }

    func meetingTemplateSnapshot(for meeting: MeetingRecord) -> MeetingTemplateSnapshot {
        MeetingTemplates.snapshot(for: meeting, customTemplates: config.customMeetingTemplates)
    }

    func updateDefaultMeetingTemplate(id: String) {
        let resolved = MeetingTemplates.resolveSnapshot(id: id, customTemplates: config.customMeetingTemplates)
        updateConfig {
            $0.defaultMeetingTemplateID = resolved.id
        }
    }

    func createCustomMeetingTemplate(name: String, prompt: String, icon: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            $0.customMeetingTemplates.append(
                CustomMeetingTemplate(
                    name: trimmedName,
                    prompt: trimmedPrompt,
                    icon: MeetingTemplates.normalizedCustomIcon(named: icon)
                )
            )
        }
    }

    func updateCustomMeetingTemplate(id: String, name: String, prompt: String, icon: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        updateConfig {
            guard let index = $0.customMeetingTemplates.firstIndex(where: { $0.id == id }) else { return }
            $0.customMeetingTemplates[index].name = trimmedName
            $0.customMeetingTemplates[index].prompt = trimmedPrompt
            $0.customMeetingTemplates[index].icon = MeetingTemplates.normalizedCustomIcon(named: icon)
        }
    }

    func deleteCustomMeetingTemplate(id: String) {
        updateConfig {
            $0.customMeetingTemplates.removeAll { $0.id == id }
            if $0.defaultMeetingTemplateID == id {
                $0.defaultMeetingTemplateID = MeetingTemplates.autoID
            }
        }
    }

    /// Returns nil on success, or an error message on failure.
    func signInWithChatGPT() async -> String? {
        do {
            try await chatGPTAuth.signIn()
            selectMeetingSummaryBackend(.chatGPT)
            syncAppState()
            return nil
        } catch {
            fputs("[muesli-native] ChatGPT sign-in failed: \(error)\n", stderr)
            return error.localizedDescription
        }
    }

    func signOutChatGPT() {
        chatGPTAuth.signOut()
        if selectedMeetingSummaryBackend == .chatGPT {
            selectMeetingSummaryBackend(.openAI)
        }
        syncAppState()
    }

    // MARK: - Google Calendar

    func signInWithGoogleCalendar() async -> String? {
        do {
            try await googleCalAuth.signIn()
            syncAppState()
            Task { await refreshUpcomingCalendarEvents() }
            return nil
        } catch {
            fputs("[muesli-native] Google Calendar sign-in failed: \(error)\n", stderr)
            return error.localizedDescription
        }
    }

    func signOutGoogleCalendar() {
        googleCalAuth.signOut()
        syncAppState()
        Task { await refreshUpcomingCalendarEvents() }
    }

    func refreshUpcomingCalendarEvents() async {
        var ekEvents = calendarMonitor.upcomingEvents(daysAhead: 7)

        if googleCalAuth.isAuthenticated {
            do {
                let googleEvents = try await googleCalClient.fetchUpcomingEvents(daysAhead: 7)
                ekEvents = GoogleCalendarClient.mergeEvents(eventKit: ekEvents, google: googleEvents)
            } catch {
                fputs("[muesli-native] Google Calendar fetch failed: \(error)\n", stderr)
            }
        }

        appState.upcomingCalendarEvents = ekEvents
    }

    func startCalendarRefreshTimer() {
        calendarRefreshTimer?.invalidate()
        calendarRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshUpcomingCalendarEvents()
            }
        }
        Task { await refreshUpcomingCalendarEvents() }
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
                // ChatGPT backend uses OAuth tokens stored in app support dir, not an API key
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

    func showMeetingsHome(folderID: Int64? = nil) {
        appState.selectedTab = .meetings
        appState.selectedFolderID = folderID
        appState.meetingsNavigationState = .browser
    }

    func showMeetingDocument(id: Int64) {
        appState.selectedTab = .meetings
        appState.selectedMeetingID = id
        appState.selectedMeetingRecord = meeting(id: id)
        appState.meetingsNavigationState = .document(id)
    }

    func showMeetingTemplatesManager() {
        appState.selectedTab = .meetings
        appState.isMeetingTemplatesManagerPresented = true
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

    func resummarize(meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        let templateSnapshot = meetingTemplateSnapshot(for: meeting)
        resummarize(meeting: meeting, using: templateSnapshot, completion: completion)
    }

    func applyMeetingTemplate(id: String, to meeting: MeetingRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let templateSnapshot = MeetingTemplates.resolveExactSnapshot(
            id: id,
            customTemplates: config.customMeetingTemplates
        ) else {
            completion(.failure(MeetingTemplateSelectionError.templateNoLongerExists))
            return
        }
        resummarize(meeting: meeting, using: templateSnapshot, completion: completion)
    }

    private func resummarize(
        meeting: MeetingRecord,
        using templateSnapshot: MeetingTemplateSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task { [weak self] in
            guard let self else { return }
            let plan = MeetingResummarizationPolicy.plan(for: meeting)
            let notes = await MeetingSummaryClient.summarize(
                transcript: meeting.rawTranscript,
                meetingTitle: plan.promptTitle,
                config: self.config,
                template: templateSnapshot,
                existingNotes: self.notesContextForResummary(meeting)
            )

            do {
                try self.dictationStore.updateMeetingSummary(
                    id: meeting.id,
                    title: plan.persistedTitle,
                    formattedNotes: notes,
                    selectedTemplateID: templateSnapshot.id,
                    selectedTemplateName: templateSnapshot.name,
                    selectedTemplateKind: templateSnapshot.kind,
                    selectedTemplatePrompt: templateSnapshot.prompt
                )
                await MainActor.run {
                    self.syncAppState()
                    self.historyWindowController?.reload()
                    completion(.success(()))
                }
            } catch {
                fputs("[muesli-native] failed to persist meeting summary: \(error)\n", stderr)
                await MainActor.run {
                    completion(.failure(MeetingSummaryPersistenceError.failedToSaveSummary(underlying: error)))
                }
            }
        }
    }

    // MARK: - Meeting Editing

    private func notesContextForResummary(_ meeting: MeetingRecord) -> String? {
        guard meeting.notesState == .structuredNotes else { return nil }
        let trimmed = meeting.formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : meeting.formattedNotes
    }

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

    func reorderFolders(ids: [Int64]) {
        updateConfig { $0.folderOrder = ids }
        syncAppState()
    }

    func createFolderAndMoveMeeting(name: String, meetingID: Int64) {
        guard let folderID = try? dictationStore.createFolder(name: name) else { return }
        try? dictationStore.moveMeeting(id: meetingID, toFolder: folderID)
        syncAppState()
    }

    func deleteFolder(id: Int64) {
        try? dictationStore.deleteFolder(id: id)
        if appState.selectedFolderID == id {
            appState.selectedFolderID = nil
        }
        syncAppState()
    }

    func createMeetingFromCalendarEvent(_ event: UnifiedCalendarEvent, folderID: Int64?) {
        do {
            let meetingID = try dictationStore.insertMeeting(
                title: event.title,
                calendarEventID: event.id,
                startTime: event.startDate,
                endTime: event.endDate,
                rawTranscript: "",
                formattedNotes: "",
                micAudioPath: nil,
                systemAudioPath: nil
            )
            if let folderID {
                try? dictationStore.moveMeeting(id: meetingID, toFolder: folderID)
            }
            syncAppState()
            fputs("[muesli-native] created meeting from calendar event: \(event.title) (folder=\(folderID.map(String.init) ?? "none"))\n", stderr)
        } catch {
            fputs("[muesli-native] failed to create meeting from calendar event: \(error)\n", stderr)
        }
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

    func deleteMeeting(id: Int64) {
        guard let meeting = meeting(id: id) else { return }

        do {
            // Delete the retained file first so a failed file removal does not orphan
            // user-visible recording data after the meeting row disappears.
            if let savedRecordingPath = meeting.savedRecordingPath {
                try deleteSavedMeetingRecording(at: savedRecordingPath)
            }
            try dictationStore.deleteMeeting(id: id)
        } catch let error as MeetingLifecycleError {
            presentErrorAlert(title: "Couldn't Delete Meeting", message: error.localizedDescription)
            return
        } catch {
            presentErrorAlert(
                title: "Couldn't Delete Meeting",
                message: MeetingLifecycleError.failedToDeleteMeeting(underlying: error).localizedDescription
            )
            return
        }

        if appState.selectedMeetingID == id {
            appState.selectedMeetingID = nil
            appState.selectedMeetingRecord = nil
            if case .document(let selectedID) = appState.meetingsNavigationState, selectedID == id {
                appState.meetingsNavigationState = .browser
            }
        }

        historyWindowController?.reload()
        statusBarController?.refresh()
        syncAppState()
    }

    func clearDictationHistory() {
        try? dictationStore.clearDictations()
        statusBarController?.refresh()
        historyWindowController?.reload()
        syncAppState()
    }

    func clearMeetingHistory() {
        guard !isMeetingRecording() else {
            presentErrorAlert(
                title: "Couldn't Clear Meeting History",
                message: "Stop the current meeting recording before clearing saved meetings."
            )
            return
        }

        do {
            try clearSavedMeetingRecordingsDirectory()
        } catch {
            presentErrorAlert(
                title: "Couldn't Clear Meeting History",
                message: "Saved meeting recordings could not be deleted, so meeting history was left in place. \(error.localizedDescription)"
            )
            return
        }

        try? dictationStore.clearMeetings()
        appState.selectedMeetingID = nil
        appState.selectedMeetingRecord = nil
        appState.meetingsNavigationState = .browser
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
        guard !isMeetingRecording(), !isStartingMeetingRecording else { return }
        isStartingMeetingRecording = true
        micActivityMonitor.suppressWhileActive()
        micActivityMonitor.refreshState()
        updateMeetingNotificationVisibility()
        let meetingSession = MeetingSession(
            title: title,
            calendarEventID: nil,
            backend: selectedBackend,
            runtime: runtime,
            config: config,
            transcriptionCoordinator: transcriptionCoordinator
        )
        statusBarController?.setStatus("Starting meeting: \(title)")
        statusBarController?.refresh()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await meetingSession.start()
                self.activeMeetingSession = meetingSession
                self.micActivityMonitor.suppressWhileActive()
                self.micActivityMonitor.refreshState()
                self.statusBarController?.setStatus("Meeting: \(title)")
                self.indicator.powerProvider = { [weak meetingSession] in
                    meetingSession?.currentPower() ?? -160
                }
                self.indicator.setMeetingRecording(true, config: self.config)
                self.statusBarController?.refresh()
            } catch {
                fputs("[muesli-native] failed to start meeting: \(error)\n", stderr)
                self.micActivityMonitor.resumeAfterCooldown()
                self.micActivityMonitor.refreshState()
                self.statusBarController?.setStatus("Idle")
                self.statusBarController?.refresh()
                self.setState(.idle)
            }
            self.isStartingMeetingRecording = false
            self.updateMeetingNotificationVisibility()
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
        micActivityMonitor.refreshState()
        setState(.idle)
        statusBarController?.refresh()
        syncAppState()
        updateMeetingNotificationVisibility()
        fputs("[muesli-native] meeting recording discarded\n", stderr)
    }

    func stopMeetingRecording() {
        guard let activeMeetingSession else { return }
        indicator.setMeetingRecording(false, config: config)
        indicator.setTranscribingTitle("Transcribing", config: config)
        setState(.transcribing)
        activeMeetingSession.onProgress = { [weak self] stage in
            Task { @MainActor [weak self] in
                self?.setMeetingProcessingStage(stage)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            var meetingTitle = "Meeting"
            var completedMeetingID: Int64?
            var meetingResult: MeetingSessionResult?
            defer {
                if let meetingResult {
                    self.cleanupTemporaryMeetingAudioFiles(for: meetingResult)
                }
            }
            do {
                let result = try await activeMeetingSession.stop()
                meetingResult = result
                meetingTitle = result.title
                await MainActor.run {
                    self.setMeetingProcessingStatus("Finalizing")
                }
                let persistenceResult = try self.persistCompletedMeetingResult(result)
                completedMeetingID = persistenceResult.meetingID
                if let recordingSaveError = persistenceResult.recordingSaveError {
                    self.presentErrorAlert(title: "Meeting Recording", message: recordingSaveError.localizedDescription)
                }
            } catch {
                fputs("[muesli-native] meeting transcription failed: \(error)\n", stderr)
                if let lifecycleError = error as? MeetingLifecycleError {
                    self.presentErrorAlert(title: "Meeting Recording", message: lifecycleError.localizedDescription)
                } else {
                    self.presentErrorAlert(title: "Meeting Recording", message: error.localizedDescription)
                }
            }
            await MainActor.run {
                self.activeMeetingSession = nil
                self.setState(.idle)
                self.micActivityMonitor.resumeAfterCooldown()
                self.micActivityMonitor.refreshState()
                self.statusBarController?.refresh()
                self.historyWindowController?.reload()
                self.syncAppState()
                TelemetryDeck.signal("meeting.completed")

                self.presentedMeetingDetection = nil
                let savedMeetingID = completedMeetingID
                self.meetingNotification.show(
                    title: "Transcription complete",
                    subtitle: meetingTitle,
                    actionLabel: "View Notes",
                    onStartRecording: { [weak self] in
                        guard let self else { return }
                        if let savedMeetingID {
                            self.showMeetingDocument(id: savedMeetingID)
                        }
                        self.syncAppState()
                        self.historyWindowController?.show()
                    }
                )
                self.updateMeetingNotificationVisibility()
            }
        }
    }

    func revealMeetingRecordingInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentErrorAlert(
                title: "Recording Not Found",
                message: "The saved meeting recording is no longer available on disk."
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func persistCompletedMeetingResult(_ result: MeetingSessionResult) throws -> CompletedMeetingPersistenceResult {
        let meetingID = try dictationStore.insertMeeting(
            title: result.title,
            calendarEventID: result.calendarEventID,
            startTime: result.startTime,
            endTime: result.endTime,
            rawTranscript: result.rawTranscript,
            formattedNotes: result.formattedNotes,
            micAudioPath: nil,
            systemAudioPath: nil,
            savedRecordingPath: nil,
            selectedTemplateID: result.templateSnapshot.id,
            selectedTemplateName: result.templateSnapshot.name,
            selectedTemplateKind: result.templateSnapshot.kind,
            selectedTemplatePrompt: result.templateSnapshot.prompt
        )

        do {
            if let savedRecordingPath = try persistMeetingRecordingIfNeeded(for: result) {
                try dictationStore.updateMeetingSavedRecordingPath(id: meetingID, path: savedRecordingPath)
            }
            return CompletedMeetingPersistenceResult(meetingID: meetingID, recordingSaveError: nil)
        } catch let error as MeetingLifecycleError {
            return CompletedMeetingPersistenceResult(meetingID: meetingID, recordingSaveError: error)
        } catch {
            return CompletedMeetingPersistenceResult(
                meetingID: meetingID,
                recordingSaveError: .failedToSaveRecording(underlying: error)
            )
        }
    }

    private func persistMeetingRecordingIfNeeded(for result: MeetingSessionResult) throws -> String? {
        let shouldSave: Bool
        switch config.meetingRecordingSavePolicy {
        case .never:
            shouldSave = false
        case .always:
            shouldSave = true
        case .prompt:
            shouldSave = promptToSaveMeetingRecording(for: result.title)
        }

        guard shouldSave else {
            if let retainedRecordingURL = result.retainedRecordingURL {
                try? FileManager.default.removeItem(at: retainedRecordingURL)
            }
            return nil
        }

        if let retainedRecordingError = result.retainedRecordingError {
            throw MeetingLifecycleError.failedToSaveRecording(underlying: retainedRecordingError)
        }

        guard let retainedRecordingURL = result.retainedRecordingURL else {
            return nil
        }

        do {
            let outputURL = try MeetingRecordingWriter.persistTemporaryRecording(
                from: retainedRecordingURL,
                meetingTitle: result.title,
                startedAt: result.startTime,
                supportDirectory: AppIdentity.supportDirectoryURL
            )
            return outputURL.path
        } catch {
            throw MeetingLifecycleError.failedToSaveRecording(underlying: error)
        }
    }

    private func cleanupTemporaryMeetingAudioFiles(for result: MeetingSessionResult) {
        if let retainedRecordingURL = result.retainedRecordingURL {
            try? FileManager.default.removeItem(at: retainedRecordingURL)
        }
        if let systemRecordingURL = result.systemRecordingURL {
            try? FileManager.default.removeItem(at: systemRecordingURL)
        }
    }

    private func cleanupTemporaryDirectory(named directoryName: String, logDescription: String) {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files {
            try? FileManager.default.removeItem(at: file)
        }

        if !files.isEmpty {
            fputs("[muesli-native] cleaned up \(files.count) \(logDescription)\n", stderr)
        }
    }

    private func clearSavedMeetingRecordingsDirectory() throws {
        let recordingsDirectory = AppIdentity.supportDirectoryURL
            .appendingPathComponent("meeting-recordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return }
        try FileManager.default.removeItem(at: recordingsDirectory)
    }

    private func deleteSavedMeetingRecording(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw MeetingLifecycleError.failedToDeleteRecording(underlying: error)
        }
    }

    private func promptToSaveMeetingRecording(for title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Save meeting recording?"
        alert.informativeText = "Keep a merged audio file for \"\(title)\" so you can inspect it later in Finder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save Recording")
        alert.addButton(withTitle: "Don't Save")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    private func dismissPresentedMeetingDetection() {
        guard presentedMeetingDetection != nil else { return }
        meetingNotification.close()
        presentedMeetingDetection = nil
    }

    private func updateMeetingNotificationVisibility() {
        guard config.showMeetingDetectionNotification else {
            dismissPresentedMeetingDetection()
            return
        }

        guard !isMeetingRecording(), !isStartingMeetingRecording, let detection = currentMeetingDetection else {
            dismissPresentedMeetingDetection()
            return
        }

        guard presentedMeetingDetection != detection else { return }

        let title = detection.meetingTitle ?? detection.appName
        presentedMeetingDetection = detection
        meetingNotification.show(
            title: "Meeting detected",
            subtitle: title,
            onStartRecording: { [weak self] in
                guard let self else { return }
                self.presentedMeetingDetection = nil
                self.micActivityMonitor.suppress()
                self.micActivityMonitor.refreshState()
                self.startMeetingRecording(title: title)
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                self.presentedMeetingDetection = nil
                self.micActivityMonitor.suppress()
                self.micActivityMonitor.refreshState()
            }
        )
    }

    @MainActor
    private func setMeetingProcessingStage(_ stage: MeetingProcessingStage) {
        switch stage {
        case .transcribingAudio:
            setMeetingProcessingStatus("Transcribing")
        case .cleaningAudio:
            setMeetingProcessingStatus("Cleaning")
        case .generatingTitle:
            setMeetingProcessingStatus("Titling")
        case .summarizingNotes:
            setMeetingProcessingStatus("Summarizing")
        }
    }

    @MainActor
    private func setMeetingProcessingStatus(_ status: String) {
        statusBarController?.setStatus(status)
        statusBarController?.refresh()
        indicator.setTranscribingTitle(status, config: config)
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
            SoundController.playDictationStart(enabled: config.soundEnabled)
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
                    SoundController.playDictationInsert(enabled: self.config.soundEnabled)
                    self.setState(.idle)
                    self.micActivityMonitor.resumeAfterCooldown()
                    TelemetryDeck.signal("dictation.completed", parameters: [
                        "backend": self.selectedBackend.backend,
                        "paste_method": "clipboard_restore",
                    ])
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
