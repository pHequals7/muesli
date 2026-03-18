import SwiftUI
import MuesliCore

struct DictationRowView: View {
    let record: DictationRecord
    let timeOnly: String
    let onCopy: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing20) {
            Text(timeOnly)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 80, alignment: .leading)
                .padding(.top, 2)

            Text(record.rawText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
                .buttonStyle(.plain)

                if onDelete != nil {
                    Button { showDeleteConfirmation = true } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing16)
        .background(isHovered ? MuesliTheme.backgroundHover : MuesliTheme.backgroundRaised)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture(perform: onCopy)
        .alert("Delete Dictation", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this dictation? This cannot be undone.")
        }
    }
}
