import SwiftUI
import MuesliCore

struct DashboardRootView: View {
    let appState: AppState
    let controller: MuesliController

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(appState: appState, controller: controller)
                .frame(
                    minWidth: MuesliTheme.sidebarMinWidth,
                    idealWidth: MuesliTheme.sidebarIdealWidth,
                    maxWidth: MuesliTheme.sidebarIdealWidth,
                    maxHeight: .infinity
                )

            Rectangle()
                .fill(MuesliTheme.surfaceBorder)
                .frame(width: 1)

            detailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MuesliTheme.backgroundBase)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(MuesliTheme.backgroundBase)
        .preferredColorScheme(appState.config.darkMode ? .dark : .light)
    }

    @ViewBuilder
    private var detailContent: some View {
        if appState.isSearchActive,
           case .document(let id) = appState.meetingsNavigationState {
            MeetingDetailView(
                meeting: appState.selectedMeeting,
                controller: controller,
                appState: appState,
                onBack: {
                    appState.meetingsNavigationState = .browser
                    appState.selectedMeetingID = nil
                    appState.selectedMeetingRecord = nil
                },
                backLabel: "Back to Search"
            )
            .id(id)
        } else if appState.isSearchActive {
            SearchResultsView(appState: appState, controller: controller)
        } else {
            switch appState.selectedTab {
            case .dictations:
                DictationsView(appState: appState, controller: controller)
            case .meetings:
                MeetingsView(appState: appState, controller: controller)
            case .dictionary:
                DictionaryView(appState: appState, controller: controller)
            case .models:
                ModelsView(appState: appState, controller: controller)
            case .shortcuts:
                ShortcutsView(appState: appState, controller: controller)
            case .settings:
                SettingsView(appState: appState, controller: controller)
            case .about:
                AboutView(appState: appState, controller: controller)
            }
        }
    }
}
