import SwiftUI
import MuesliCore

struct ModelsView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var downloadingModels: Set<String> = []
    @State private var downloadProgress: [String: Double] = [:]
    @State private var downloadedModels: Set<String> = []
    @State private var modelToDelete: BackendOption?
    @State private var selectedParakeetModel: String
    @State private var selectedWhisperModel: String
    @State private var showExperimental: Bool

    init(appState: AppState, controller: MuesliController) {
        self.appState = appState
        self.controller = controller

        let active = appState.selectedBackend
        _selectedParakeetModel = State(initialValue: BackendOption.parakeetFamily.contains(active) ? active.model : BackendOption.parakeetMultilingual.model)
        _selectedWhisperModel = State(initialValue: BackendOption.whisperFamily.contains(active) ? active.model : BackendOption.whisperSmall.model)
        _showExperimental = State(initialValue: false)
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
                EmptyView()
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

    // MARK: - Actions

    private func startDownload(_ option: BackendOption) {
        withAnimation { downloadingModels.insert(option.model) }
        downloadProgress[option.model] = 0.05  // Show initial progress immediately

        let startTime = Date()
        Task {
            await controller.transcriptionCoordinator.preload(backend: option) { progress, _ in
                DispatchQueue.main.async {
                    downloadProgress[option.model] = max(progress, 0.05)
                }
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
                }
            }
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
