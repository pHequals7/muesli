import SwiftUI
import MuesliCore

struct SidebarView: View {
    private let sidebarIconColumnWidth: CGFloat = 20
    private let meetingsTrailingColumnWidth: CGFloat = 24
    private let sidebarRowHorizontalPadding: CGFloat = 16
    private let sidebarRowOuterPadding: CGFloat = 8

    let appState: AppState
    let controller: MuesliController
    @State private var meetingsExpanded = true
    @State private var renamingFolderID: Int64?
    @State private var renamingFolderName = ""
    @State private var folderToDelete: MeetingFolder?
    @State private var showDeleteConfirmation = false
    @State private var draggingFolderID: Int64?
    @State private var dragOrderedFolders: [MeetingFolder]?

    private var userName: String {
        appState.config.userName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            sidebarHeader

            sidebarItem(tab: .dictations, icon: "mic.fill", label: "Dictations")
            meetingsSection
            sidebarItem(tab: .dictionary, icon: "character.book.closed", label: "Dictionary")
            sidebarItem(tab: .models, icon: "square.and.arrow.down", label: "Models")
            sidebarItem(tab: .shortcuts, icon: "keyboard", label: "Shortcuts")

            Spacer()

            sidebarItem(tab: .settings, icon: "gearshape", label: "Settings")
            sidebarItem(tab: .about, icon: "info.circle", label: "About")
            darkModeToggle
                .padding(.bottom, MuesliTheme.spacing16)
        }
        .frame(maxHeight: .infinity)
        .background(MuesliTheme.backgroundDeep)
        .onChange(of: appState.selectedTab) { _, tab in
            if tab == .meetings {
                meetingsExpanded = true
            }
            // Reset drag state if user navigates away during a drag
            if draggingFolderID != nil {
                draggingFolderID = nil
                dragOrderedFolders = nil
            }
        }
        .alert(
            "Delete \"\(folderToDelete?.name ?? "")\"?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                folderToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let folder = folderToDelete {
                    controller.deleteFolder(id: folder.id)
                    controller.showMeetingsHome(folderID: appState.selectedFolderID)
                }
                folderToDelete = nil
            }
        } message: {
            let count = folderToDelete.map { folder in
                appState.meetingCountsByFolder[folder.id] ?? 0
            } ?? 0
            if count > 0 {
                Text("\(count) meeting\(count == 1 ? "" : "s") in this folder will be moved to Unfiled.")
            } else {
                Text("This folder will be permanently removed.")
            }
        }
    }

    @ViewBuilder
    private var sidebarHeader: some View {
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
                    .padding(.leading, 34)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.top, MuesliTheme.spacing24)
        .padding(.bottom, MuesliTheme.spacing20)
    }

    @ViewBuilder
    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            let isSelected = appState.selectedTab == .meetings
            HStack(spacing: MuesliTheme.spacing12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        meetingsExpanded = true
                    }
                    controller.showMeetingsHome()
                } label: {
                    HStack(spacing: MuesliTheme.spacing12) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isSelected ? MuesliTheme.accent : MuesliTheme.textSecondary)
                            .frame(width: sidebarIconColumnWidth)
                        Text("Meetings")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        meetingsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: meetingsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? MuesliTheme.textSecondary : MuesliTheme.textTertiary)
                        .frame(width: meetingsTrailingColumnWidth, height: 18)
                }
                .buttonStyle(.plain)

                Button(action: createNewFolder) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? MuesliTheme.textSecondary : MuesliTheme.textTertiary)
                        .frame(width: meetingsTrailingColumnWidth, height: 18)
                }
                .buttonStyle(.plain)
                .help("New Meeting Folder")
            }
            .padding(.horizontal, sidebarRowHorizontalPadding)
            .padding(.vertical, MuesliTheme.spacing8)
            .background(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(isSelected ? MuesliTheme.surfaceSelected : Color.clear)
            )
            .padding(.horizontal, sidebarRowOuterPadding)

            if meetingsExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    meetingFilterRow(
                        icon: "tray.2",
                        label: "All Meetings",
                        count: appState.totalMeetingCount,
                        isSelected: appState.selectedTab == .meetings && appState.selectedFolderID == nil
                    ) {
                        controller.showMeetingsHome()
                    }

                    ForEach(dragOrderedFolders ?? appState.folders) { folder in
                        if renamingFolderID == folder.id {
                            folderRenameField(folder: folder)
                        } else {
                            meetingFilterRow(
                                icon: "folder",
                                label: folder.name,
                                count: appState.meetingCountsByFolder[folder.id] ?? 0,
                                isSelected: appState.selectedTab == .meetings && appState.selectedFolderID == folder.id
                            ) {
                                controller.showMeetingsHome(folderID: folder.id)
                            }
                            .opacity(draggingFolderID == folder.id ? 0.1 : 1)
                            .onDrag {
                                draggingFolderID = folder.id
                                dragOrderedFolders = appState.folders
                                return NSItemProvider(object: "\(folder.id)" as NSString)
                            }
                            .onDrop(of: [.text], delegate: FolderDropDelegate(
                                folderID: folder.id,
                                dragOrderedFolders: $dragOrderedFolders,
                                draggingFolderID: $draggingFolderID,
                                commitOrder: { ids in controller.reorderFolders(ids: ids) }
                            ))
                            .contextMenu {
                                Button("Rename") {
                                    renamingFolderID = folder.id
                                    renamingFolderName = folder.name
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    folderToDelete = folder
                                    showDeleteConfirmation = true
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, sidebarRowOuterPadding)
            }
        }
    }

    @ViewBuilder
    private func sidebarItem(tab: DashboardTab, icon: String, label: String) -> some View {
        let isSelected = appState.selectedTab == tab
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                appState.selectedTab = tab
            }
        } label: {
            HStack(spacing: MuesliTheme.spacing12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? MuesliTheme.accent : MuesliTheme.textSecondary)
                    .frame(width: sidebarIconColumnWidth)
                Text(label)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, sidebarRowHorizontalPadding)
            .padding(.vertical, MuesliTheme.spacing8)
            .background(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .fill(isSelected ? MuesliTheme.surfaceSelected : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, sidebarRowOuterPadding)
    }

    @ViewBuilder
    private var darkModeToggle: some View {
        let isDark = appState.config.darkMode
        HStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    controller.updateConfig { $0.darkMode = false }
                }
            } label: {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(!isDark ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 28, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(!isDark ? MuesliTheme.surfaceSelected : Color.clear)
                    )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    controller.updateConfig { $0.darkMode = true }
                }
            } label: {
                Image(systemName: "moon.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isDark ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 28, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isDark ? MuesliTheme.surfaceSelected : Color.clear)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .fill(MuesliTheme.backgroundRaised)
        )
        .padding(.horizontal, sidebarRowOuterPadding)
        .padding(.leading, sidebarRowHorizontalPadding)
        .padding(.bottom, MuesliTheme.spacing4)
    }

    @ViewBuilder
    private func meetingFilterRow(
        icon: String,
        label: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? MuesliTheme.accent : MuesliTheme.textTertiary)
                .frame(width: sidebarIconColumnWidth)
            Text(label)
                .font(MuesliTheme.callout())
                .foregroundStyle(isSelected ? MuesliTheme.textPrimary : MuesliTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            Text(formattedCount(count))
                .font(MuesliTheme.caption())
                .monospacedDigit()
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(minWidth: meetingsTrailingColumnWidth, alignment: .center)
        }
        .padding(.horizontal, sidebarRowHorizontalPadding)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .fill(isSelected ? MuesliTheme.surfaceSelected.opacity(0.6) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    @ViewBuilder
    private func folderRenameField(folder: MeetingFolder) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: sidebarIconColumnWidth)
            TextField("Folder name", text: $renamingFolderName)
                .font(MuesliTheme.callout())
                .textFieldStyle(.plain)
                .onSubmit {
                    let trimmed = renamingFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        controller.renameFolder(id: folder.id, name: trimmed)
                    }
                    renamingFolderID = nil
                }
        }
        .padding(.horizontal, sidebarRowHorizontalPadding)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .fill(MuesliTheme.surfaceSelected.opacity(0.6))
        )
    }

    private func formattedCount(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        let k = Double(count) / 1000.0
        if count < 10000 {
            return String(format: "%.1fk", k)
        }
        return String(format: "%.0fk", k)
    }

    private func createNewFolder() {
        if let id = controller.createFolder(name: "New Folder") {
            withAnimation(.easeInOut(duration: 0.15)) {
                meetingsExpanded = true
            }
            renamingFolderID = id
            renamingFolderName = "New Folder"
            controller.showMeetingsHome(folderID: id)
        }
    }
}

private struct FolderDropDelegate: DropDelegate {
    let folderID: Int64
    @Binding var dragOrderedFolders: [MeetingFolder]?
    @Binding var draggingFolderID: Int64?
    let commitOrder: ([Int64]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragID = draggingFolderID, dragID != folderID,
              var folders = dragOrderedFolders else { return }
        guard let fromIndex = folders.firstIndex(where: { $0.id == dragID }),
              let toIndex = folders.firstIndex(where: { $0.id == folderID }) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            folders.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            dragOrderedFolders = folders
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        if let folders = dragOrderedFolders {
            commitOrder(folders.map(\.id))
        }
        draggingFolderID = nil
        dragOrderedFolders = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
