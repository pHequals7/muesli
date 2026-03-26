import SwiftUI
import MuesliCore

struct MeetingNotesView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                let lines = markdown.components(separatedBy: .newlines)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    markdownLine(line.trimmingCharacters(in: .whitespaces))
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(MuesliTheme.spacing24)
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func markdownLine(_ line: String) -> some View {
        if line.isEmpty {
            Spacer()
                .frame(height: MuesliTheme.spacing8)
        } else if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2)))
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.top, MuesliTheme.spacing12)
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.top, MuesliTheme.spacing8)
        } else if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.top, MuesliTheme.spacing4)
        } else if line.hasPrefix("- [ ] ") {
            HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                Image(systemName: "square")
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(String(line.dropFirst(6)))
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                Image(systemName: "checkmark.square")
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.success)
                Text(String(line.dropFirst(6)))
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                Circle()
                    .fill(MuesliTheme.textTertiary)
                    .frame(width: 4, height: 4)
                    .offset(y: -2)
                Text(String(line.dropFirst(2)))
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
        } else if line.hasPrefix("**") && line.hasSuffix("**") {
            Text(String(line.dropFirst(2).dropLast(2)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
        } else {
            Text(line)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
        }
    }
}
