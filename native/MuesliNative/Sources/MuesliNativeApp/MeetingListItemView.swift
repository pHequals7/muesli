import SwiftUI
import MuesliCore

struct MeetingListItemView: View {
    let record: MeetingRecord
    let isSelected: Bool
    let folders: [MeetingFolder]
    let onSelect: () -> Void
    let onMove: (Int64?) -> Void
    let onDelete: (() -> Void)?
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false

    private var currentFolderName: String? {
        guard let fid = record.folderID else { return nil }
        return folders.first(where: { $0.id == fid })?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(alignment: .top) {
                Text(record.title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(2)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    if !folders.isEmpty {
                        folderMenuButton
                    }
                    if onDelete != nil {
                        deleteButton
                    }
                }
            }

            HStack(spacing: MuesliTheme.spacing4) {
                Text(formatMeta())
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)

                // Current folder badge
                if let name = currentFolderName {
                    Text("\u{2022}")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                    HStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(name)
                            .font(MuesliTheme.caption())
                    }
                    .foregroundStyle(MuesliTheme.accent.opacity(0.8))
                }
            }

            Text(previewText())
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .lineLimit(2)
        }
        .padding(MuesliTheme.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? MuesliTheme.surfaceSelected : MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerLarge)
                .strokeBorder(
                    isSelected ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .alert("Delete Meeting", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this meeting? Saved notes, transcript, and any retained recording will be removed.")
        }
    }

    // MARK: - Folder menu button

    @ViewBuilder
    private var folderMenuButton: some View {
        Menu {
            Button {
                onMove(nil)
            } label: {
                Label("Unfiled", systemImage: "tray")
            }
            Divider()
            ForEach(folders) { folder in
                Button {
                    onMove(folder.id)
                } label: {
                    HStack {
                        Label(folder.name, systemImage: "folder")
                        if record.folderID == folder.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: record.folderID != nil ? "folder.fill" : "folder.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(
                    record.folderID != nil
                        ? MuesliTheme.accent
                        : (isHovering ? MuesliTheme.textSecondary : MuesliTheme.textTertiary)
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Move to folder")
    }

    @ViewBuilder
    private var deleteButton: some View {
        Button {
            showDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(
                    isHovering
                        ? MuesliTheme.recording.opacity(0.85)
                        : MuesliTheme.textTertiary
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 1 : 0)
        .help("Delete meeting")
    }

    // MARK: - Formatting

    private func formatMeta() -> String {
        let time = formatTime(record.startTime)
        let duration = formatDuration(record.durationSeconds)
        return "\(time)  \u{2022}  \(duration)"
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

    private func previewText() -> String {
        let source = record.formattedNotes.isEmpty ? record.rawTranscript : record.formattedNotes
        let compact = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if compact.count > 88 {
            return String(compact.prefix(85)) + "..."
        }
        return compact
    }
}
