import SwiftUI
import MuesliCore

struct DictionaryView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var isAdding = false
    @State private var newWord = ""
    @State private var newReplacement = ""
    @State private var newThreshold = 0.85

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
                    newThreshold = 0.85
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
            Text("Add custom words for names, brands, and domain terms, and tune how aggressively each entry should fuzzy-match transcription errors.")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var wordList: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider().background(MuesliTheme.surfaceBorder)

            if isAdding {
                addWordRow
                Divider().background(MuesliTheme.surfaceBorder)
            }

            if appState.config.customWords.isEmpty && !isAdding {
                emptyState
            } else {
                ForEach(appState.config.customWords) { word in
                    DictionaryWordEditorRow(word: word, controller: controller)
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
            Text("Add words that transcription frequently gets wrong")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(MuesliTheme.spacing32)
    }

    private var columnHeader: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Text("Match")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("")
                .font(.system(size: 10))
                .frame(width: 14)
            Text("Replace")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Threshold")
                .fixedSize()
            // Space for action buttons
            Text("")
                .frame(width: 48)
        }
        .font(MuesliTheme.caption())
        .foregroundStyle(MuesliTheme.textTertiary)
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing8)
    }

    private var addWordRow: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            TextField("Word", text: $newWord)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
            TextField("Replace with", text: $newReplacement)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            ThresholdPicker(value: $newThreshold)
            Button {
                let trimmedWord = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedWord.isEmpty else { return }
                let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
                controller.addCustomWord(
                    CustomWord(
                        word: trimmedWord,
                        replacement: replacement.isEmpty ? nil : replacement,
                        matchingThreshold: newThreshold
                    )
                )
                isAdding = false
                newWord = ""
                newReplacement = ""
                newThreshold = 0.85
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                isAdding = false
                newWord = ""
                newReplacement = ""
                newThreshold = 0.85
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing12)
    }
}

private struct DictionaryWordEditorRow: View {
    let word: CustomWord
    let controller: MuesliController

    @State private var draftWord: String
    @State private var draftReplacement: String
    @State private var draftThreshold: Double

    init(word: CustomWord, controller: MuesliController) {
        self.word = word
        self.controller = controller
        _draftWord = State(initialValue: word.word)
        _draftReplacement = State(initialValue: word.replacement ?? "")
        _draftThreshold = State(initialValue: word.matchingThreshold)
    }

    private var trimmedWord: String {
        draftWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        draftReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedWord != word.word
            || (trimmedReplacement.isEmpty ? nil : trimmedReplacement) != word.replacement
            || abs(draftThreshold - word.matchingThreshold) > 0.001
    }

    var body: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            TextField("Word", text: $draftWord)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
            TextField("Replace with", text: $draftReplacement)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            ThresholdPicker(value: $draftThreshold)
            Button {
                controller.updateCustomWord(
                    CustomWord(
                        id: word.id,
                        word: trimmedWord,
                        replacement: trimmedReplacement.isEmpty ? nil : trimmedReplacement,
                        matchingThreshold: draftThreshold
                    )
                )
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hasChanges && !trimmedWord.isEmpty ? MuesliTheme.accent : MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(trimmedWord.isEmpty || !hasChanges)
            Button {
                controller.removeCustomWord(id: word.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(MuesliTheme.recording)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing12)
    }
}

private struct ThresholdPicker: View {
    @Binding var value: Double

    private static let steps: [Double] = [0.70, 0.75, 0.80, 0.85, 0.90, 0.95]

    var body: some View {
        Menu {
            ForEach(Self.steps, id: \.self) { step in
                Button {
                    value = step
                } label: {
                    HStack {
                        Text(Self.label(for: step))
                        if abs(value - step) < 0.001 {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(Self.label(for: value))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
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

    private static func label(for value: Double) -> String {
        "\(Int(value * 100))%"
    }
}
