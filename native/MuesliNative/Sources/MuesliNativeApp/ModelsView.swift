import SwiftUI
import MuesliCore

struct ModelsView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var downloadingModels: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadedModels: Set<String> = []
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]
    @State private var modelToDelete: BackendOption?
    @State private var selectedParakeetModel: String
    @State private var selectedWhisperModel: String
    @State private var showExperimental: Bool

    // Post-processor state
    @State private var downloadingPostProcModels: Set<String> = []
    @State private var downloadProgressPostProc: [String: Double] = [:]
    @State private var downloadedPostProcModels: Set<String> = []
    @State private var downloadTasksPostProc: [String: Task<Void, Never>] = [:]
    @State private var postProcModelToDelete: PostProcessorOption?
    @State private var isEditingSystemPrompt: Bool = false
    @State private var editedSystemPrompt: String

    init(appState: AppState, controller: MuesliController) {
        self.appState = appState
        self.controller = controller

        let active = appState.selectedBackend
        _selectedParakeetModel = State(initialValue: BackendOption.parakeetFamily.contains(active) ? active.model : BackendOption.parakeetMultilingual.model)
        _selectedWhisperModel = State(initialValue: BackendOption.whisperFamily.contains(active) ? active.model : BackendOption.whisperSmall.model)
        _showExperimental = State(initialValue: false)
        _editedSystemPrompt = State(initialValue: appState.config.postProcessorSystemPrompt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("Models")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Download and manage transcription models. The active model is used for dictation.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)

                familyCard(
                    title: "Parakeet Family",
                    subtitle: "NVIDIA speech models for fast everyday dictation.",
                    defaultBadge: "Default: v3",
                    selection: $selectedParakeetModel,
                    options: BackendOption.parakeetFamily
                )

                modelCard(option: .cohereTranscribe)

                familyCard(
                    title: "Whisper",
                    subtitle: "OpenAI Whisper variants for users who prefer the classic CPU/GPU path.",
                    defaultBadge: "Default: Small",
                    selection: $selectedWhisperModel,
                    options: BackendOption.whisperFamily
                )

                experimentalSection

                postProcessorSection

                if !BackendOption.comingSoon.isEmpty {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        Text("COMING SOON")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .textCase(.uppercase)
                            .padding(.leading, 2)
                            .padding(.top, MuesliTheme.spacing8)

                        VStack(spacing: MuesliTheme.spacing12) {
                            ForEach(BackendOption.comingSoon, id: \.model) { option in
                                comingSoonCard(option: option)
                            }
                        }
                    }
                }
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
        .onAppear {
            checkDownloadedModels()
            checkDownloadedPostProcModels()
            syncSelectionsFromActiveBackend()
        }
        .onChange(of: appState.selectedBackend.model) { _, _ in
            syncSelectionsFromActiveBackend()
        }
        .alert(
            "Delete \"\(modelToDelete?.label ?? "")\"?",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let option = modelToDelete else { return }
                deleteModel(option)
                modelToDelete = nil
            }
        } message: {
            Text("The downloaded model files will be removed from this Mac. You can download the model again later.")
        }
        .alert(
            "Delete \"\(postProcModelToDelete?.label ?? "")\"?",
            isPresented: Binding(
                get: { postProcModelToDelete != nil },
                set: { if !$0 { postProcModelToDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                postProcModelToDelete = nil
            }
            Button("Delete", role: .destructive) {
                guard let option = postProcModelToDelete else { return }
                deletePostProcModel(option)
                postProcModelToDelete = nil
            }
        } message: {
            Text("The downloaded model files will be removed from this Mac. You can download the model again later.")
        }
    }

    private var experimentalSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Button {
                showExperimental.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing12) {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                        HStack(spacing: 6) {
                            Image(systemName: showExperimental ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textTertiary)

                            Text("Experimental")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(MuesliTheme.textSecondary)
                        }

                        Text("Qwen and streaming backends. Hidden by default because these are still slower and less polished.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .opacity(0.8)
                    }

                    Spacer()

                    Text("IYKYK")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showExperimental {
                VStack(spacing: MuesliTheme.spacing12) {
                    ForEach(BackendOption.experimental, id: \.model) { option in
                        modelCard(option: option)
                    }
                }
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var postProcessorSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text("POST-PROCESSING")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .textCase(.uppercase)
                    .padding(.leading, 2)

                Text("Optional LLM cleanup layer applied after transcription. Removes filler words, formats spoken lists, and corrects common dictation errors.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.leading, 2)
            }
            .padding(.top, MuesliTheme.spacing8)

            VStack(spacing: MuesliTheme.spacing12) {
                ForEach(PostProcessorOption.all) { option in
                    postProcModelCard(option)
                }
            }

            systemPromptCard
        }
    }

    private func postProcModelCard(_ option: PostProcessorOption) -> some View {
        let isDownloaded = downloadedPostProcModels.contains(option.id)
        let isActive = appState.activePostProcessor.id == option.id && isDownloaded
        let isDownloading = downloadingPostProcModels.contains(option.id)
        let progress = downloadProgressPostProc[option.id] ?? 0

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                if isActive {
                    Text("Active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isDownloaded {
                    Text("Downloaded")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(MuesliTheme.accent)
                    Text("\(Int(progress * 100))% downloading...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                if isDownloading {
                    Button("Cancel") {
                        cancelPostProcDownload(option)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                } else if isDownloaded {
                    if !isActive {
                        Button("Set Active") {
                            controller.selectPostProcessor(option)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.accent)
                        .padding(.horizontal, MuesliTheme.spacing12)
                        .padding(.vertical, 4)
                        .background(MuesliTheme.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    }

                    Button {
                        postProcModelToDelete = option
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.6))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button("Download") {
                        startPostProcDownload(option)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private var systemPromptCard: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("System Prompt")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Controls how the model cleans up transcriptions. Applies to the active post-processor model.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                if !isEditingSystemPrompt {
                    Button("Edit") {
                        editedSystemPrompt = appState.config.postProcessorSystemPrompt
                        isEditingSystemPrompt = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
            }

            if isEditingSystemPrompt {
                TextEditor(text: $editedSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )

                HStack(spacing: MuesliTheme.spacing8) {
                    Button("Save") {
                        controller.updatePostProcessorSystemPrompt(editedSystemPrompt)
                        isEditingSystemPrompt = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                    Button("Cancel") {
                        isEditingSystemPrompt = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))

                    Button("Reset to Default") {
                        editedSystemPrompt = PostProcessorOption.defaultSystemPrompt
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
            } else {
                Text(appState.config.postProcessorSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(6)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func familyCard(
        title: String,
        subtitle: String,
        defaultBadge: String,
        selection: Binding<String>,
        options: [BackendOption]
    ) -> some View {
        let selectedOption = options.first(where: { $0.model == selection.wrappedValue }) ?? options[0]
        let isActive = appState.selectedBackend == selectedOption
        let isDownloaded = downloadedModels.contains(selectedOption.model)
        let isDownloading = downloadingModels.contains(selectedOption.model)
        let progress = downloadProgress[selectedOption.model] ?? 0

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(title)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        Text(defaultBadge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MuesliTheme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(MuesliTheme.accentSubtle)
                            .clipShape(Capsule())
                    }

                    Text(subtitle)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                familyStatusBadge(isActive: isActive, isDownloaded: isDownloaded)
            }

            HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
                Text("Variant")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 52, alignment: .leading)

                Picker("", selection: selection) {
                    ForEach(options, id: \.model) { option in
                        Text(option.label).tag(option.model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220, alignment: .leading)

                Text(selectedOption.sizeLabel)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            Text(selectedOption.description)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)

            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(MuesliTheme.accent)
                    Text("\(Int(progress * 100))% downloading...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            actionButtons(for: selectedOption, isActive: isActive, isDownloaded: isDownloaded, isDownloading: isDownloading)
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    @ViewBuilder
    private func familyStatusBadge(isActive: Bool, isDownloaded: Bool) -> some View {
        if isActive {
            Text("Active")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.success)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MuesliTheme.success.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if isDownloaded {
            Text("Downloaded")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func actionButtons(for option: BackendOption, isActive: Bool, isDownloaded: Bool, isDownloading: Bool) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            if isDownloading {
                Button("Cancel") {
                    cancelDownload(option)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 4)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            } else if isDownloaded {
                if !isActive {
                    Button("Set Active") {
                        controller.selectBackend(option)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 4)
                    .background(MuesliTheme.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }

                Button {
                    modelToDelete = option
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.6))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            } else {
                Button("Download") {
                    startDownload(option)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 4)
                .background(MuesliTheme.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
        }
    }

    private func modelCard(option: BackendOption) -> some View {
        let isActive = appState.selectedBackend == option
        let isDownloaded = downloadedModels.contains(option.model)
        let isDownloading = downloadingModels.contains(option.model)
        let progress = downloadProgress[option.model] ?? 0

        return VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        if option.recommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MuesliTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }

                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                // Status badge
                if isActive {
                    Text("Active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MuesliTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.success.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isDownloaded {
                    Text("Downloaded")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            // Progress bar when downloading
            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                        .tint(MuesliTheme.accent)
                    Text("\(Int(progress * 100))% downloading...")
                        .font(.system(size: 11))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            actionButtons(for: option, isActive: isActive, isDownloaded: isDownloaded, isDownloading: isDownloading)
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(isActive ? MuesliTheme.accent.opacity(0.5) : MuesliTheme.surfaceBorder, lineWidth: isActive ? 1.5 : 1)
        )
    }

    private func comingSoonCard(option: BackendOption) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Text(option.label)
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textTertiary)

                        Text("Experimental")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MuesliTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(option.sizeLabel)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary.opacity(0.6))
                    }

                    Text(option.description)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary.opacity(0.7))
                }
                Spacer()
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder.opacity(0.5), lineWidth: 1)
        )
        .opacity(0.6)
    }

    // MARK: - Post-Processor Actions

    private func startPostProcDownload(_ option: PostProcessorOption) {
        withAnimation { downloadingPostProcModels.insert(option.id) }
        downloadProgressPostProc[option.id] = 0.02

        let task = Task {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: option.cacheDirectory, withIntermediateDirectories: true)

                let delegate = PostProcDownloadDelegate { progress in
                    DispatchQueue.main.async {
                        downloadProgressPostProc[option.id] = max(progress, 0.02)
                    }
                }
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

                let tmpURL = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        delegate.setContinuation(continuation)
                        session.downloadTask(with: option.downloadURL).resume()
                    }
                } onCancel: {
                    session.invalidateAndCancel()
                }
                session.finishTasksAndInvalidate()

                if fm.fileExists(atPath: option.modelURL.path) { try fm.removeItem(at: option.modelURL) }
                try fm.moveItem(at: tmpURL, to: option.modelURL)

                await MainActor.run {
                    withAnimation {
                        downloadingPostProcModels.remove(option.id)
                        downloadedPostProcModels.insert(option.id)
                        downloadProgressPostProc.removeValue(forKey: option.id)
                        downloadTasksPostProc.removeValue(forKey: option.id)
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation {
                        downloadingPostProcModels.remove(option.id)
                        downloadProgressPostProc.removeValue(forKey: option.id)
                        downloadTasksPostProc.removeValue(forKey: option.id)
                    }
                }
                let isCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !isCancelled {
                    fputs("[muesli-native] Post-processor download failed: \(error)\n", stderr)
                }
            }
        }
        downloadTasksPostProc[option.id] = task
    }

    private func cancelPostProcDownload(_ option: PostProcessorOption) {
        downloadTasksPostProc[option.id]?.cancel()
        withAnimation {
            downloadingPostProcModels.remove(option.id)
            downloadProgressPostProc.removeValue(forKey: option.id)
            downloadTasksPostProc.removeValue(forKey: option.id)
        }
    }

    private func deletePostProcModel(_ option: PostProcessorOption) {
        if appState.activePostProcessor.id == option.id {
            let fallback = PostProcessorOption.all.first { $0.id != option.id } ?? .finetunedV2
            controller.selectPostProcessor(fallback)
        }
        try? FileManager.default.removeItem(at: option.cacheDirectory)
        downloadedPostProcModels.remove(option.id)
    }

    private func checkDownloadedPostProcModels() {
        for option in PostProcessorOption.all {
            if option.isDownloaded {
                downloadedPostProcModels.insert(option.id)
            }
        }
    }

    // MARK: - Actions

    private func startDownload(_ option: BackendOption) {
        withAnimation { downloadingModels.insert(option.model) }
        downloadProgress[option.model] = 0.05  // Show initial progress immediately

        let startTime = Date()
        let task = Task {
            await controller.transcriptionCoordinator.preload(backend: option) { progress, _ in
                DispatchQueue.main.async {
                    downloadProgress[option.model] = max(progress, 0.05)
                }
            }
            guard !Task.isCancelled else {
                await MainActor.run {
                    withAnimation {
                        downloadingModels.remove(option.model)
                        downloadProgress.removeValue(forKey: option.model)
                        downloadTasks.removeValue(forKey: option.model)
                    }
                }
                return
            }
            // Ensure the downloading state is visible for at least 1.5s
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 1.5 {
                try? await Task.sleep(nanoseconds: UInt64((1.5 - elapsed) * 1_000_000_000))
            }
            await MainActor.run {
                withAnimation {
                    downloadingModels.remove(option.model)
                    downloadedModels.insert(option.model)
                    downloadProgress.removeValue(forKey: option.model)
                    downloadTasks.removeValue(forKey: option.model)
                }
            }
        }
        downloadTasks[option.model] = task
    }

    private func cancelDownload(_ option: BackendOption) {
        downloadTasks[option.model]?.cancel()
        withAnimation {
            downloadingModels.remove(option.model)
            downloadProgress.removeValue(forKey: option.model)
            downloadTasks.removeValue(forKey: option.model)
        }
    }

    private func deleteModel(_ option: BackendOption) {
        if appState.selectedBackend == option {
            let fallback = downloadedModels
                .compactMap { model in BackendOption.all.first(where: { $0.model == model && $0 != option }) }
                .first ?? .parakeetMultilingual
            controller.selectBackend(fallback)
        }
        // Remove cached model files
        Task {
            await deleteModelFiles(option)
            await MainActor.run {
                downloadedModels.remove(option.model)
            }
        }
    }

    private func deleteModelFiles(_ option: BackendOption) async {
        let fm = FileManager.default
        switch option.backend {
        case "whisper":
            let filename = option.model.hasSuffix(".bin") ? option.model : "\(option.model).bin"
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/\(filename)")
            try? fm.removeItem(at: path)
        case "nemotron":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron-560ms")
            try? fm.removeItem(at: path)
        case "canary":
            try? fm.removeItem(at: CanaryQwenModelStore.cacheDirectory())
        case "cohere":
            try? fm.removeItem(at: CohereTranscribeModelStore.cacheDirectory())
        case "fluidaudio":
            // FluidAudio models are in ~/Library/Application Support/FluidAudio/Models/
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if option.model.contains("parakeet") {
                let version = option.model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    for dir in contents where dir.lastPathComponent.contains("parakeet") && dir.lastPathComponent.contains(version) {
                        try? fm.removeItem(at: dir)
                    }
                }
            }
        case "qwen":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b-coreml")
            try? fm.removeItem(at: path)
        default:
            break
        }
    }

    // MARK: - Check Downloaded Status

    private func checkDownloadedModels() {
        let fm = FileManager.default
        for option in BackendOption.all {
            if isModelDownloaded(option, fm: fm) {
                downloadedModels.insert(option.model)
            }
        }
    }

    private func syncSelectionsFromActiveBackend() {
        let active = appState.selectedBackend
        if BackendOption.parakeetFamily.contains(active) {
            selectedParakeetModel = active.model
        }
        if BackendOption.whisperFamily.contains(active) {
            selectedWhisperModel = active.model
        }
        if BackendOption.experimental.contains(active) {
            return
        }
    }

    private func isModelDownloaded(_ option: BackendOption, fm: FileManager) -> Bool {
        switch option.backend {
        case "whisper":
            let filename = option.model.hasSuffix(".bin") ? option.model : "\(option.model).bin"
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/\(filename)")
            return fm.fileExists(atPath: path.path)
        case "nemotron":
            let path = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/muesli/models/nemotron-560ms/encoder/encoder_int8.mlmodelc")
            return fm.fileExists(atPath: path.path)
        case "fluidaudio":
            // Check FluidAudio's cache
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models")
            if option.model.contains("parakeet") {
                let version = option.model.contains("v2") ? "v2" : "v3"
                if let contents = try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil) {
                    return contents.contains { $0.lastPathComponent.contains("parakeet") && $0.lastPathComponent.contains(version) }
                }
            }
            return false
        case "qwen":
            let supportDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b-coreml")
            return fm.fileExists(atPath: supportDir.appendingPathComponent("int8/vocab.json").path)
                || fm.fileExists(atPath: supportDir.appendingPathComponent("f32/vocab.json").path)
        case "canary":
            return CanaryQwenModelStore.isAvailableLocally()
        case "cohere":
            return CohereTranscribeModelStore.isAvailableLocally()
        default:
            return false
        }
    }
}

/// URLSessionDownloadDelegate bridge for post-processor GGUF downloads.
/// Uses OS-level buffered download task instead of byte-by-byte async iteration.
private final class PostProcDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func setContinuation(_ c: CheckedContinuation<URL, Error>) {
        continuation = c
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession deletes the temp file after this returns — move it first.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gguf.tmp")
        try? FileManager.default.moveItem(at: location, to: dest)
        continuation?.resume(returning: dest)
        continuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
