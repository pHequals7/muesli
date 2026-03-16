import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: DashboardTab
    var userName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                HStack(spacing: MuesliTheme.spacing12) {
                    MWaveformIcon(barCount: 9, spacing: 2)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(MuesliTheme.accent)
                    Text("muesli")
                        .font(MuesliTheme.title2())
                        .foregroundStyle(MuesliTheme.textPrimary)
                }
                if !userName.isEmpty {
                    Text("Hi, \(userName)")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.leading, 34)  // align with text after icon (22 + 12 spacing)
                }
            }
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.top, MuesliTheme.spacing24)
            .padding(.bottom, MuesliTheme.spacing20)

            sidebarItem(
                tab: .dictations,
                icon: "mic.fill",
                label: "Dictations"
            )

            sidebarItem(
                tab: .meetings,
                icon: "person.2.fill",
                label: "Meetings"
            )

            sidebarItem(
                tab: .dictionary,
                icon: "character.book.closed",
                label: "Dictionary"
            )

            sidebarItem(
                tab: .models,
                icon: "square.and.arrow.down",
                label: "Models"
            )

            sidebarItem(
                tab: .shortcuts,
                icon: "keyboard",
                label: "Shortcuts"
            )

            Spacer()

            sidebarItem(
                tab: .settings,
                icon: "gearshape",
                label: "Settings"
            )

            sidebarItem(
                tab: .about,
                icon: "info.circle",
                label: "About"
            )
            .padding(.bottom, MuesliTheme.spacing16)
        }
        .frame(maxHeight: .infinity)
        .background(MuesliTheme.backgroundDeep)
    }

    @ViewBuilder
    private func sidebarItem(tab: DashboardTab, icon: String, label: String) -> some View {
        let isSelected = selectedTab == tab
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? MuesliTheme.accent : MuesliTheme.textSecondary)
                    .frame(width: 20)
                Text(label)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.vertical, MuesliTheme.spacing8)
            .background(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(isSelected ? MuesliTheme.surfaceSelected : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MuesliTheme.spacing8)
    }
}
