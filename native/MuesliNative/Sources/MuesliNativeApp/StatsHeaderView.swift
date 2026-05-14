import SwiftUI
import MuesliCore

struct StatsHeaderView: View {
    let dictationStats: DictationStats
    let meetingStats: MeetingStats

    var body: some View {
        HStack(spacing: MuesliTheme.spacing16) {
            StatCard(
                icon: "flame.fill",
                iconColor: .orange,
                value: "\(dictationStats.currentStreakDays)",
                label: "day streak"
            )
            StatCard(
                icon: "character.cursor.ibeam",
                iconColor: MuesliTheme.accent,
                value: formatWordCount(dictationStats.totalWords),
                label: "words dictated"
            )
            StatCard(
                icon: "gauge.with.dots.needle.33percent",
                iconColor: MuesliTheme.success,
                value: String(format: "%.0f", dictationStats.averageWPM),
                label: "avg WPM"
            )
            StatCard(
                icon: "person.2.fill",
                iconColor: MuesliTheme.accent,
                value: "\(meetingStats.totalMeetings)",
                label: "meetings"
            )
        }
        .frame(maxWidth: MuesliTheme.pageMaxWidth)
        .padding(.horizontal, MuesliTheme.pageHorizontalPadding)
        .padding(.vertical, MuesliTheme.spacing20)
        .frame(maxWidth: .infinity)
    }

    private func formatWordCount(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

private struct StatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
            Text(value)
                .font(MuesliTheme.title2())
                .foregroundStyle(MuesliTheme.textPrimary)
                .contentTransition(.numericText())
            Text(label)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(MuesliTheme.cardPadding)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }
}
