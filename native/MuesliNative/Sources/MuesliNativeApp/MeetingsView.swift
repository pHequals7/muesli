import SwiftUI
import MuesliCore

enum MeetingBrowserFilter: Hashable {
    case all, last2Days, lastWeek, last2Weeks, lastMonth, last3Months

    var label: String {
        switch self {
        case .all: return "All time"
        case .last2Days: return "Last 2 days"
        case .lastWeek: return "Last week"
        case .last2Weeks: return "Last 2 weeks"
        case .lastMonth: return "Last month"
        case .last3Months: return "Last 3 months"
        }
    }
}

enum MeetingBrowserSort: Hashable {
    case newestFirst
    case oldestFirst

    var label: String {
        switch self {
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        }
    }
}

enum MeetingBrowserLogic {
    static func availableFilters(
        for meetings: [MeetingRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingBrowserFilter] {
        var filters: [MeetingBrowserFilter] = [.all]
        let oldestDate = meetings.compactMap { parseDate($0.startTime) }.min()

        guard let oldest = oldestDate else { return filters }
        let daysSinceOldest = calendar.dateComponents([.day], from: oldest, to: now).day ?? 0

        if daysSinceOldest >= 1 { filters.append(.last2Days) }
        if daysSinceOldest >= 3 { filters.append(.lastWeek) }
        if daysSinceOldest >= 8 { filters.append(.last2Weeks) }
        if daysSinceOldest >= 15 { filters.append(.lastMonth) }
        if daysSinceOldest >= 31 { filters.append(.last3Months) }

        return filters
    }

    static func filteredMeetings(
        from meetings: [MeetingRecord],
        filter: MeetingBrowserFilter,
        sort: MeetingBrowserSort,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingRecord] {
        let threshold = threshold(for: filter, now: now, calendar: calendar)
        let filtered = meetings.filter { isAfterThreshold($0, threshold: threshold) }

        return filtered.sorted { lhs, rhs in
            let lhsDate = parseDate(lhs.startTime) ?? .distantPast
            let rhsDate = parseDate(rhs.startTime) ?? .distantPast
            switch sort {
            case .newestFirst:
                return lhsDate > rhsDate
            case .oldestFirst:
                return lhsDate < rhsDate
            }
        }
    }

    private static func threshold(
        for filter: MeetingBrowserFilter,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        switch filter {
        case .all:
            return nil
        case .last2Days:
            return calendar.date(byAdding: .day, value: -2, to: now)
        case .lastWeek:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .last2Weeks:
            return calendar.date(byAdding: .day, value: -14, to: now)
        case .lastMonth:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .last3Months:
            return calendar.date(byAdding: .month, value: -3, to: now)
        }
    }

    private static func isAfterThreshold(_ meeting: MeetingRecord, threshold: Date?) -> Bool {
        guard let threshold else { return true }
        guard let date = parseDate(meeting.startTime) else { return false }
        return date >= threshold
    }

    static func parseDate(_ raw: String) -> Date? {
        isoParsers.lazy.compactMap { $0.date(from: raw) }.first
            ?? localParsers.lazy.compactMap { $0.date(from: raw) }.first
    }

    private static let isoParsers: [ISO8601DateFormatter] = {
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        return [iso1, iso2]
    }()

    private static let localParsers: [DateFormatter] = {
        let local1: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
            return f
        }()
        let local2: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f
        }()
        return [local1, local2]
    }()
}

struct MeetingsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var selectedFilter: MeetingBrowserFilter = .all
    @State private var selectedSort: MeetingBrowserSort = .newestFirst

    private var scopedMeetings: [MeetingRecord] {
        appState.meetingRows
    }

    private var filteredMeetings: [MeetingRecord] {
        MeetingBrowserLogic.filteredMeetings(
            from: scopedMeetings,
            filter: selectedFilter,
            sort: selectedSort
        )
    }

    private var currentFolderName: String {
        guard let folderID = appState.selectedFolderID else { return "All Meetings" }
        return appState.folders.first(where: { $0.id == folderID })?.name ?? "All Meetings"
    }

    private var currentDocumentMeeting: MeetingRecord? {
        guard case let .document(id) = appState.meetingsNavigationState else { return nil }
        if appState.selectedMeetingID == id, let selectedMeeting = appState.selectedMeeting {
            return selectedMeeting
        }
        return controller.meeting(id: id)
    }

    var body: some View {
        Group {
            if let meeting = currentDocumentMeeting {
                MeetingDetailView(
                    meeting: meeting,
                    controller: controller,
                    appState: appState,
                    onBack: { controller.showMeetingsHome(folderID: appState.selectedFolderID) }
                )
                .id(meeting.id)
            } else {
                browserView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuesliTheme.backgroundBase)
        .sheet(
            isPresented: Binding(
                get: { appState.isMeetingTemplatesManagerPresented },
                set: { appState.isMeetingTemplatesManagerPresented = $0 }
            )
        ) {
            MeetingTemplatesManagerView(
                appState: appState,
                controller: controller,
                onClose: { appState.isMeetingTemplatesManagerPresented = false }
            )
        }
    }

    @ViewBuilder
    private var browserView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                browserHeader

                if filteredMeetings.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: MuesliTheme.spacing12) {
                        ForEach(filteredMeetings) { meeting in
                            MeetingListItemView(
                                record: meeting,
                                isSelected: appState.selectedMeetingID == meeting.id,
                                folders: appState.folders,
                                onSelect: { controller.showMeetingDocument(id: meeting.id) },
                                onMove: { folderID in
                                    controller.moveMeeting(id: meeting.id, toFolder: folderID)
                                },
                                onCreateFolderAndMove: { name in
                                    controller.createFolderAndMoveMeeting(name: name, meetingID: meeting.id)
                                },
                                onDelete: {
                                    controller.deleteMeeting(id: meeting.id)
                                }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var browserHeader: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: MuesliTheme.spacing16) {
                    browserHeaderTitle
                    Spacer(minLength: MuesliTheme.spacing16)
                    browserHeaderActions
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                    browserHeaderTitle
                    HStack {
                        Spacer(minLength: 0)
                        browserHeaderActions
                    }
                }
            }

            browserHeaderMeta
        }
    }

    @ViewBuilder
    private var browserHeaderTitle: some View {
        Text(currentFolderName)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(MuesliTheme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var browserHeaderMeta: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Text("\(filteredMeetings.count) meeting\(filteredMeetings.count == 1 ? "" : "s")")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize()

            Text("\u{2022}")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize()

            Text("Open a meeting to review notes, transcript, and template-driven summaries")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var browserHeaderActions: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            sortButton
            dateFilterButton

            Button {
                controller.showMeetingTemplatesManager()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                    Text("Manage Templates")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var sortButton: some View {
        Menu {
            ForEach([MeetingBrowserSort.newestFirst, .oldestFirst], id: \.self) { option in
                Button {
                    selectedSort = option
                } label: {
                    HStack {
                        Text(option.label)
                        if selectedSort == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                Text(selectedSort.label)
                    .font(.system(size: 11))
            }
            .foregroundStyle(selectedSort != .newestFirst ? MuesliTheme.accent : MuesliTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selectedSort != .newestFirst ? MuesliTheme.accent.opacity(0.12) : MuesliTheme.surfacePrimary.opacity(0.5))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var dateFilterButton: some View {
        Menu {
            ForEach(availableFilters, id: \.self) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    HStack {
                        Text(filter.label)
                        if selectedFilter == filter {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                if selectedFilter != .all {
                    Text(selectedFilter.label)
                        .font(.system(size: 11))
                }
            }
            .foregroundStyle(selectedFilter != .all ? MuesliTheme.accent : MuesliTheme.textTertiary)
            .padding(.horizontal, selectedFilter != .all ? 8 : 0)
            .padding(.vertical, 3)
            .background(selectedFilter != .all ? MuesliTheme.accent.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var availableFilters: [MeetingBrowserFilter] {
        MeetingBrowserLogic.availableFilters(for: scopedMeetings)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Image(systemName: appState.selectedFolderID == nil ? "person.2.wave.2" : "folder")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(MuesliTheme.textTertiary)

            Text(appState.selectedFolderID == nil ? "No meetings yet" : "No meetings in this folder")
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textSecondary)

            Text(
                appState.selectedFolderID == nil
                    ? "Start a recording from the menu bar to create your first meeting note."
                    : "Choose another folder or move a meeting here from the browser."
            )
            .font(MuesliTheme.callout())
            .foregroundStyle(MuesliTheme.textTertiary)
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(MuesliTheme.spacing24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerXL))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerXL)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }
}
