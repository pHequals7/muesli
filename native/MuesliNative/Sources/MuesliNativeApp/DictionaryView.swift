import SwiftUI

struct DictionaryView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var isAdding = false
    @State private var newWord = ""
    @State private var newReplacement = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                header
                wordList
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MuesliTheme.backgroundBase)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack {
                Text("Dictionary")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Spacer()
                Button {
                    isAdding = true
                    newWord = ""
                    newReplacement = ""
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add new")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, MuesliTheme.spacing8)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            Text("Add custom words to improve transcription accuracy for names, brands, and domain terms.")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var wordList: some View {
        VStack(spacing: 0) {
            if isAdding {
                addWordRow
                Divider().background(MuesliTheme.surfaceBorder)
            }

            if appState.config.customWords.isEmpty && !isAdding {
                emptyState
            } else {
                ForEach(appState.config.customWords) { word in
                    wordRow(word)
                    Divider().background(MuesliTheme.surfaceBorder)
                }
            }
        }
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No custom words yet")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
            Text("Add words that Whisper frequently gets wrong")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(MuesliTheme.spacing32)
    }

    private func wordRow(_ word: CustomWord) -> some View {
        HStack {
            if let replacement = word.replacement, !replacement.isEmpty {
                Text(word.word)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(replacement)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
            } else {
                Text(word.word)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MuesliTheme.textPrimary)
            }
            Spacer()
            Button {
                controller.removeCustomWord(id: word.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing12)
    }

    private var addWordRow: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            TextField("Word", text: $newWord)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)

            Text("→")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textTertiary)

            TextField("Replace with (optional)", text: $newReplacement)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Button {
                let trimmed = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                let word = CustomWord(
                    word: trimmed,
                    replacement: replacement.isEmpty ? nil : replacement
                )
                controller.addCustomWord(word)
                newWord = ""
                newReplacement = ""
                isAdding = false
            } label: {
                Text("Add")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                isAdding = false
                newWord = ""
                newReplacement = ""
            } label: {
                Text("Cancel")
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing12)
    }
}
