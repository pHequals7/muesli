import SwiftUI
import MuesliCore

private enum MeetingDocumentMode: Hashable {
    case notes
    case transcript
}

struct MeetingDetailView: View {
    let meeting: MeetingRecord?
    let controller: MuesliController
    let appState: AppState
    let onBack: (() -> Void)?
    let backLabel: String
    @State private var isSummarizing = false
    @State private var isEditingNotes = false
    @State private var editableTitle: String
    @State private var editableNotes: String
    @State private var editableManualNotes: String
    @State private var manualEditorCommand: MarkdownEditorCommand?
    @State private var pendingTemplateID: String
    @State private var documentMode: MeetingDocumentMode
    @State private var titleSaveTask: DispatchWorkItem?
    @State private var notesSaveTask: DispatchWorkItem?
    @State private var summaryErrorMessage: String?
    @State private var showDeleteConfirmation = false

    init(
        meeting: MeetingRecord?,
        controller: MuesliController,
        appState: AppState,
        onBack: (() -> Void)? = nil,
        backLabel: String = "Back to Meetings"
    ) {
        self.meeting = meeting
        self.controller = controller
        self.appState = appState
        self.onBack = onBack
        self.backLabel = backLabel
        let initialTemplateID = meeting.map { controller.meetingTemplateSnapshot(for: $0).id } ?? controller.defaultMeetingTemplate().id
        _editableTitle = State(initialValue: meeting?.title ?? "")
        _editableNotes = State(initialValue: meeting.map { Self.notesContent(for: $0) } ?? "")
        _editableManualNotes = State(initialValue: meeting?.manualNotes ?? "")
        _pendingTemplateID = State(initialValue: initialTemplateID)
        _documentMode = State(initialValue: meeting.map(Self.defaultDocumentMode(for:)) ?? .notes)
    }

    var body: some View {
        Group {
            if let meeting {
                VStack(alignment: .leading, spacing: 0) {
                    header(meeting)

                    Divider()
                        .background(MuesliTheme.surfaceBorder)

                    content(for: meeting)
                }
                .background(MuesliTheme.backgroundBase)
                .onChange(of: meeting.id) { _, _ in
                    syncLocalState(with: meeting)
                }
                .onChange(of: meeting.status) { _, _ in
                    syncLocalState(with: meeting)
                }
                .onChange(of: appState.config.customMeetingTemplates) { _, _ in
                    syncPendingTemplateSelectionIfNeeded(for: meeting)
                }
            } else {
                VStack(spacing: MuesliTheme.spacing12) {
                    Text("No meeting selected")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Text("Choose a meeting from the Meetings browser to open it here.")
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MuesliTheme.backgroundBase)
            }
        }
        .alert("Couldn't Save Summary", isPresented: summaryErrorBinding) {
            Button("OK", role: .cancel) {
                summaryErrorMessage = nil
            }
        } message: {
            Text(summaryErrorMessage ?? "The updated meeting notes could not be saved.")
        }
        .alert("Delete Meeting", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let meeting {
                    controller.deleteMeeting(id: meeting.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? Saved notes, transcript, and any retained recording will be removed.")
        }
    }

    @ViewBuilder
    private func header(_ meeting: MeetingRecord) -> some View {
        let appliedTemplate = controller.meetingTemplateSnapshot(for: meeting)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(backLabel)
                            .font(MuesliTheme.callout())
                    }
                    .foregroundStyle(MuesliTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: MuesliTheme.spacing24) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    TextField("Meeting Title", text: $editableTitle)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            controller.updateMeetingTitle(id: meeting.id, title: editableTitle)
                        }
                        .onChange(of: editableTitle) { _, _ in
                            debounceSaveTitle(meetingID: meeting.id)
                        }

                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(formatMeta(meeting))
                            .font(MuesliTheme.callout())
                            .foregroundStyle(MuesliTheme.textSecondary)
                        templateChip(for: appliedTemplate)
                    }
                }

                Spacer(minLength: MuesliTheme.spacing16)

                VStack(alignment: .trailing, spacing: 10) {
                    if showsManualNotesEditor(for: meeting) {
                        HStack(spacing: MuesliTheme.spacing8) {
                            statusChip(for: meeting)
                            if meeting.status == .recording {
                                stopRecordingButton
                                discardRecordingButton
                            } else if meeting.status == .noteOnly || meeting.status == .failed {
                                deleteButton
                            }
                        }
                    } else {
                        documentModePicker

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: MuesliTheme.spacing8) {
                                templateMenu(for: meeting, appliedTemplate: appliedTemplate)
                                recordingAction(for: meeting)
                                summaryAction(for: meeting)
                                editButton(for: meeting)
                                deleteButton
                            }

                            VStack(alignment: .trailing, spacing: MuesliTheme.spacing8) {
                                HStack(spacing: MuesliTheme.spacing8) {
                                    templateMenu(for: meeting, appliedTemplate: appliedTemplate)
                                    recordingAction(for: meeting)
                                    summaryAction(for: meeting)
                                }
                                HStack(spacing: MuesliTheme.spacing8) {
                                    editButton(for: meeting)
                                    deleteButton
                                }
                            }
                        }
                    }
                }
            }

            if !showsManualNotesEditor(for: meeting), isRawTranscript(meeting), documentMode == .notes {
                transcriptCTA
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func content(for meeting: MeetingRecord) -> some View {
        if showsManualNotesEditor(for: meeting) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                manualNotesToolbar(for: meeting)

                MarkdownRichTextEditor(
                    text: $editableManualNotes,
                    command: $manualEditorCommand,
                    shouldFocus: meeting.status == .recording
                )
                .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
                .background(MuesliTheme.backgroundBase)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
                .onChange(of: editableManualNotes) { _, _ in
                    saveManualNotes(meetingID: meeting.id)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if isEditingNotes {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                contentToolbar(for: meeting)

                TextEditor(text: $editableNotes)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(MuesliTheme.spacing24)
                    .background(MuesliTheme.backgroundBase)
                    .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
                    .onChange(of: editableNotes) { _, _ in
                        debounceSaveNotes(meetingID: meeting.id)
                    }
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                contentToolbar(for: meeting)

                ZStack {
                    MeetingNotesView(markdown: Self.notesContent(for: meeting))
                        .opacity(documentMode == .notes ? 1 : 0)
                        .allowsHitTesting(documentMode == .notes)
                        .accessibilityHidden(documentMode != .notes)

                    MeetingTranscriptView(transcript: meeting.rawTranscript)
                        .opacity(documentMode == .transcript ? 1 : 0)
                        .allowsHitTesting(documentMode == .transcript)
                        .accessibilityHidden(documentMode != .transcript)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var documentModePicker: some View {
        Picker("", selection: $documentMode) {
            Text("Notes").tag(MeetingDocumentMode.notes)
            Text("Transcript").tag(MeetingDocumentMode.transcript)
        }
        .pickerStyle(.segmented)
        .tint(MuesliTheme.accent)
        .frame(width: 220)
        .disabled(isEditingNotes)
    }

    private func showsManualNotesEditor(for meeting: MeetingRecord) -> Bool {
        switch meeting.status {
        case .recording, .processing, .noteOnly, .failed:
            return true
        case .completed:
            return false
        }
    }

    @ViewBuilder
    private func summaryAction(for meeting: MeetingRecord) -> some View {
        if isSummarizing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Summarizing...")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .padding(.horizontal, MuesliTheme.spacing8)
        } else {
            iconButton("sparkles", label: primarySummaryActionLabel(for: meeting)) {
                isSummarizing = true
                let completion: (Result<Void, Error>) -> Void = { [meeting] result in
                    isSummarizing = false
                    switch result {
                    case .success:
                        if let updated = controller.meeting(id: meeting.id) {
                            syncLocalState(with: updated)
                        }
                    case .failure(let error):
                        syncPendingTemplateSelectionIfNeeded(
                            for: controller.meeting(id: meeting.id) ?? meeting
                        )
                        summaryErrorMessage = error.localizedDescription
                    }
                }
                if hasPendingTemplateChange(for: meeting) {
                    controller.applyMeetingTemplate(id: pendingTemplateID, to: meeting, completion: completion)
                } else {
                    controller.resummarize(meeting: meeting, completion: completion)
                }
            }
        }
    }

    @ViewBuilder
    private func editButton(for meeting: MeetingRecord) -> some View {
        iconButton(
            isEditingNotes ? "checkmark.circle" : "pencil",
            label: isEditingNotes ? "Done" : "Edit"
        ) {
            if isEditingNotes {
                notesSaveTask?.cancel()
                controller.updateMeetingNotes(id: meeting.id, notes: editableNotes)
            } else {
                documentMode = .notes
                editableNotes = Self.notesContent(for: meeting)
            }
            isEditingNotes.toggle()
        }
    }

    @ViewBuilder
    private func recordingAction(for meeting: MeetingRecord) -> some View {
        if let savedRecordingPath = meeting.savedRecordingPath {
            iconButton("folder", label: "Show Recording") {
                controller.revealMeetingRecordingInFinder(path: savedRecordingPath)
            }
        }
    }

    @ViewBuilder
    private func templateMenu(for meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> some View {
        Menu {
            Button {
                pendingTemplateID = MeetingTemplates.autoID
            } label: {
                templateMenuItem(
                    title: MeetingTemplates.auto.title,
                    systemImage: MeetingTemplates.auto.icon,
                    isSelected: pendingTemplateID == MeetingTemplates.autoID
                )
            }

            Section("Built-in Templates") {
                ForEach(controller.builtInMeetingTemplates()) { template in
                    Button {
                        pendingTemplateID = template.id
                    } label: {
                        templateMenuItem(
                            title: template.title,
                            systemImage: template.icon,
                            isSelected: pendingTemplateID == template.id
                        )
                    }
                }
            }

            if !controller.customMeetingTemplates().isEmpty {
                Section("Custom Templates") {
                    ForEach(controller.customMeetingTemplates()) { template in
                        Button {
                            pendingTemplateID = template.id
                        } label: {
                            let resolved = MeetingTemplates.customDefinition(from: template)
                            templateMenuItem(
                                title: template.name,
                                systemImage: resolved.icon,
                                isSelected: pendingTemplateID == template.id
                            )
                        }
                    }
                }
            }

            Divider()

            Button("Manage Templates…") {
                controller.showMeetingTemplatesManager()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName(forSelectionOn: meeting, appliedTemplate: appliedTemplate))
                    .font(.system(size: 10))
                Text(labelForSelection(on: meeting, appliedTemplate: appliedTemplate))
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 5)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func contentToolbar(for meeting: MeetingRecord) -> some View {
        HStack {
            Spacer()

            exportMenu(for: meeting)

            Button(action: {
                controller.copyToClipboard(activeCopyText(for: meeting))
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(copyButtonLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .fill(MuesliTheme.accent.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.accent.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 980, alignment: .leading)
    }

    @ViewBuilder
    private func manualNotesToolbar(for meeting: MeetingRecord) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Spacer()

            markdownToolbarButton(systemImage: "textformat.size", label: "Heading") {
                manualEditorCommand = MarkdownEditorCommand(kind: .heading)
            }
            markdownToolbarButton(systemImage: "bold", label: "Bold") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bold)
            }
            markdownToolbarButton(systemImage: "list.bullet", label: "Bullet") {
                manualEditorCommand = MarkdownEditorCommand(kind: .bullet)
            }
            markdownToolbarButton(systemImage: "checklist", label: "Checkbox") {
                manualEditorCommand = MarkdownEditorCommand(kind: .checkbox)
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
    }

    @ViewBuilder
    private func statusChip(for meeting: MeetingRecord) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(for: meeting.status))
                .frame(width: 7, height: 7)
            Text(statusLabel(for: meeting.status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 6)
        .background(MuesliTheme.surfacePrimary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func markdownToolbarButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MuesliTheme.textSecondary)
            .frame(width: 34, height: 30)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    @ViewBuilder
    private func exportMenu(for meeting: MeetingRecord) -> some View {
        let currentContent: MeetingExportContent = documentMode == .transcript ? .transcript : .notes
        let currentLabel = documentMode == .transcript ? "Export Transcript" : "Export Notes"
        Menu {
            Button {
                MeetingExporter.export(meeting: meeting, content: currentContent)
            } label: {
                Label(currentLabel, systemImage: documentMode == .transcript ? "text.quote" : "doc.text")
            }
            Button {
                MeetingExporter.export(meeting: meeting, content: .fullMeeting)
            } label: {
                Label("Export Full Meeting", systemImage: "doc.on.doc")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                Text("Export")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(MuesliTheme.accent.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isEditingNotes)
    }

    private func templateMenuItem(title: String, systemImage: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark" : systemImage)
                .frame(width: 12)
            Text(title)
        }
    }

    @ViewBuilder
    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 5)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
        iconButton("trash", label: "Delete") {
            showDeleteConfirmation = true
        }
    }

    private var stopRecordingButton: some View {
        Button {
            controller.stopMeetingRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Stop Recording")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 8)
            .background(MuesliTheme.recording)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .help("Stop recording")
    }

    private var discardRecordingButton: some View {
        iconButton("xmark", label: "Discard") {
            controller.discardMeetingRecording()
        }
    }

    @ViewBuilder
    private func templateChip(for snapshot: MeetingTemplateSnapshot) -> some View {
        HStack(spacing: 5) {
            Image(systemName: iconName(for: snapshot))
                .font(.system(size: 10))
            Text(snapshot.name)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(MuesliTheme.accent)
        .padding(.horizontal, MuesliTheme.spacing8)
        .padding(.vertical, 4)
        .background(MuesliTheme.accentSubtle)
        .clipShape(Capsule())
    }

    private var transcriptCTA: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if hasApiKey {
                Image(systemName: "sparkles")
                    .foregroundStyle(MuesliTheme.accent)
                Text("Use \(primarySummaryActionLabel) to turn this raw transcript into AI meeting notes and a cleaned-up title.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            } else {
                Image(systemName: "key.fill")
                    .foregroundStyle(MuesliTheme.accent)
                Text("Add your API key in Settings to generate meeting notes")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Spacer()
                Button("Open Settings") {
                    controller.openHistoryWindow(tab: .settings)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .buttonStyle(.plain)
            }
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
    }

    private var hasApiKey: Bool {
        let config = appState.config
        if appState.selectedMeetingSummaryBackend == .chatGPT {
            return appState.isChatGPTAuthenticated
        } else if appState.selectedMeetingSummaryBackend == .openAI {
            return !config.openAIAPIKey.isEmpty || ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        } else {
            return !config.openRouterAPIKey.isEmpty || ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil
        }
    }

    private var primarySummaryActionLabel: String {
        guard let meeting else { return "Re-summarize" }
        return primarySummaryActionLabel(for: meeting)
    }

    private var copyButtonLabel: String {
        "Copy"
    }

    private func primarySummaryActionLabel(for meeting: MeetingRecord) -> String {
        hasPendingTemplateChange(for: meeting) ? "Apply Template" : "Re-summarize"
    }

    private func activeCopyText(for meeting: MeetingRecord) -> String {
        switch documentMode {
        case .notes:
            return isEditingNotes ? editableNotes : Self.notesContent(for: meeting)
        case .transcript:
            return meeting.rawTranscript
        }
    }

    private func isRawTranscript(_ meeting: MeetingRecord) -> Bool {
        meeting.notesState != .structuredNotes
    }

    private func hasPendingTemplateChange(for meeting: MeetingRecord) -> Bool {
        resolvedPendingTemplateDefinition(for: meeting).id != controller.meetingTemplateSnapshot(for: meeting).id
    }

    private func labelForSelection(on meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> String {
        if pendingTemplateID == appliedTemplate.id {
            return appliedTemplate.name
        }
        return resolvedPendingTemplateDefinition(for: meeting).title
    }

    private func iconName(forSelectionOn meeting: MeetingRecord, appliedTemplate: MeetingTemplateSnapshot) -> String {
        if pendingTemplateID == appliedTemplate.id {
            return iconName(for: appliedTemplate)
        }
        return resolvedPendingTemplateDefinition(for: meeting).icon
    }

    private func iconName(for snapshot: MeetingTemplateSnapshot) -> String {
        switch snapshot.kind {
        case .auto:
            return MeetingTemplates.auto.icon
        case .builtin, .custom:
            return MeetingTemplates.resolveDefinition(
                id: snapshot.id,
                customTemplates: appState.config.customMeetingTemplates
            ).icon
        }
    }

    static func notesContent(for meeting: MeetingRecord) -> String {
        if meeting.status == .noteOnly {
            return meeting.manualNotes
        }
        if meeting.notesState != .structuredNotes {
            return "# \(meeting.title)\n\n## Raw Transcript\n\n\(meeting.rawTranscript)"
        }
        return meeting.formattedNotes
    }

    private static func defaultDocumentMode(for meeting: MeetingRecord) -> MeetingDocumentMode {
        if meeting.status == .noteOnly || meeting.status == .recording || meeting.status == .processing || meeting.status == .failed {
            return .notes
        }
        return meeting.notesState == .structuredNotes
            ? MeetingDocumentMode.notes
            : MeetingDocumentMode.transcript
    }

    private func debounceSaveTitle(meetingID: Int64) {
        titleSaveTask?.cancel()
        let title = editableTitle
        let c = controller
        let item = DispatchWorkItem { c.updateMeetingTitle(id: meetingID, title: title) }
        titleSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func debounceSaveNotes(meetingID: Int64) {
        notesSaveTask?.cancel()
        let notes = editableNotes
        let c = controller
        let item = DispatchWorkItem { c.updateMeetingNotes(id: meetingID, notes: notes) }
        notesSaveTask = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    private func saveManualNotes(meetingID: Int64) {
        controller.updateMeetingManualNotes(id: meetingID, notes: editableManualNotes)
    }

    private func statusLabel(for status: MeetingStatus) -> String {
        switch status {
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .completed:
            return "Completed"
        case .noteOnly:
            return "Note only"
        case .failed:
            return "Needs attention"
        }
    }

    private func statusColor(for status: MeetingStatus) -> Color {
        switch status {
        case .recording:
            return MuesliTheme.recording
        case .processing:
            return MuesliTheme.accent
        case .completed:
            return MuesliTheme.success
        case .noteOnly:
            return MuesliTheme.textTertiary
        case .failed:
            return MuesliTheme.transcribing
        }
    }

    private var summaryErrorBinding: Binding<Bool> {
        Binding(
            get: { summaryErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    summaryErrorMessage = nil
                }
            }
        )
    }

    private func resolvedPendingTemplateDefinition(for meeting: MeetingRecord) -> MeetingTemplateDefinition {
        if let resolved = MeetingTemplates.resolveExactDefinition(
            id: pendingTemplateID,
            customTemplates: appState.config.customMeetingTemplates
        ) {
            return resolved
        }
        return MeetingTemplates.resolveDefinition(
            id: controller.meetingTemplateSnapshot(for: meeting).id,
            customTemplates: appState.config.customMeetingTemplates
        )
    }

    private func syncPendingTemplateSelectionIfNeeded(for meeting: MeetingRecord?) {
        guard let meeting else { return }
        guard MeetingTemplates.resolveExactDefinition(
            id: pendingTemplateID,
            customTemplates: appState.config.customMeetingTemplates
        ) == nil else {
            return
        }
        pendingTemplateID = controller.meetingTemplateSnapshot(for: meeting).id
    }

    private func syncLocalState(with meeting: MeetingRecord?) {
        editableTitle = meeting?.title ?? ""
        editableNotes = meeting.map { Self.notesContent(for: $0) } ?? ""
        editableManualNotes = meeting?.manualNotes ?? ""
        pendingTemplateID = meeting.map { controller.meetingTemplateSnapshot(for: $0).id } ?? controller.defaultMeetingTemplate().id
        documentMode = meeting.map(Self.defaultDocumentMode(for:)) ?? .notes
    }

    private func formatMeta(_ meeting: MeetingRecord) -> String {
        let time = formatTime(meeting.startTime)
        let duration = formatDuration(meeting.durationSeconds)
        return "\(time)  \u{2022}  \(duration)  \u{2022}  \(meeting.wordCount) words"
    }

    private func formatTime(_ raw: String) -> String {
        let clean = raw.replacingOccurrences(of: "T", with: " ")
        if clean.count > 16 {
            return String(clean.prefix(16))
        }
        return clean
    }

    private func formatDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \((rounded % 3600) / 60)m"
        }
        if rounded >= 60 {
            let m = rounded / 60
            let s = rounded % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        return "\(rounded)s"
    }
}

private struct MeetingTranscriptView: View {
    let transcript: String

    var body: some View {
        ScrollView {
            Text(transcript)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(MuesliTheme.textPrimary)
                .frame(maxWidth: 860, alignment: .leading)
                .textSelection(.enabled)
                .padding(MuesliTheme.spacing24)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
