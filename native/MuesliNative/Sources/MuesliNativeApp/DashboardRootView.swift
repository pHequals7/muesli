import SwiftUI

struct DashboardRootView: View {
    let appState: AppState
    let controller: MuesliController

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: Binding(
                get: { appState.selectedTab },
                set: { appState.selectedTab = $0 }
            ))
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            Group {
                switch appState.selectedTab {
                case .dictations:
                    DictationsView(appState: appState, controller: controller)
                case .meetings:
                    MeetingsView(appState: appState, controller: controller)
                case .dictionary:
                    DictionaryView(appState: appState, controller: controller)
                case .shortcuts:
                    ShortcutsView(appState: appState, controller: controller)
                case .settings:
                    SettingsView(appState: appState, controller: controller)
                case .about:
                    AboutView(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MuesliTheme.backgroundBase)
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(appState.config.darkMode ? .dark : .light)
    }
}
