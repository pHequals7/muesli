import AppKit
import Foundation
import MuesliCore

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let controller: MuesliController
    private let runtime: RuntimePaths
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusLabel = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")

    init(controller: MuesliController, runtime: RuntimePaths) {
        self.controller = controller
        self.runtime = runtime
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        build()
    }

    func setStatus(_ text: String) {
        statusLabel.title = "Status: \(text)"
    }

    func refresh() {
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func refreshIcon() {
        statusItem.button?.image = MenuBarIconRenderer.make(choice: controller.config.menuBarIcon)
    }

    private func build() {
        if let button = statusItem.button {
            button.image = MenuBarIconRenderer.make(choice: controller.config.menuBarIcon)
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = AppIdentity.displayName
        }
        rebuildMenu()
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(actionItem(title: "Open \(AppIdentity.displayName)", action: #selector(MuesliController.openHistoryWindow as (MuesliController) -> () -> Void)))
        let meetingTitle = controller.isMeetingRecording() ? "Stop Meeting Recording" : "Start Meeting Recording"
        menu.addItem(actionItem(title: meetingTitle, action: #selector(MuesliController.toggleMeetingRecording)))
        if controller.isMeetingRecording() {
            menu.addItem(actionItem(title: "Discard Meeting Recording...", action: #selector(MuesliController.discardMeetingWithConfirmation)))
        }
        menu.addItem(.separator())

        let recentItem = NSMenuItem(title: "Recent Dictations", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let recentRows = controller.recentDictations()
        if recentRows.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for row in recentRows {
                let item = NSMenuItem(title: controller.truncate(row.rawText, limit: 54), action: #selector(MuesliController.copyRecentDictation(_:)), keyEquivalent: "")
                item.target = controller
                item.representedObject = row.rawText
                recentMenu.addItem(item)
            }
        }
        menu.setSubmenu(recentMenu, for: recentItem)
        menu.addItem(recentItem)

        let meetingItem = NSMenuItem(title: "Meeting Transcripts", action: nil, keyEquivalent: "")
        let meetingMenu = NSMenu()
        let meetingRows = controller.recentMeetings()
        if meetingRows.isEmpty {
            let empty = NSMenuItem(title: "No meetings yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            meetingMenu.addItem(empty)
        } else {
            for row in meetingRows {
                let title = controller.truncate(row.title, limit: 18)
                let transcript = controller.truncate(row.rawTranscript, limit: 30)
                let item = NSMenuItem(
                    title: "\(title): \(transcript)",
                    action: #selector(MuesliController.copyRecentMeeting(_:)),
                    keyEquivalent: ""
                )
                item.target = controller
                item.representedObject = row.rawTranscript
                meetingMenu.addItem(item)
            }
        }
        menu.setSubmenu(meetingMenu, for: meetingItem)
        menu.addItem(meetingItem)

        let backendItem = NSMenuItem(title: "Transcription Backend", action: nil, keyEquivalent: "")
        let backendMenu = NSMenu()
        for option in BackendOption.downloaded {
            let prefix = controller.selectedBackend == option ? "✓ " : ""
            let item = NSMenuItem(title: "\(prefix)\(option.label)", action: #selector(MuesliController.selectBackendFromMenu(_:)), keyEquivalent: "")
            item.target = controller
            item.representedObject = option.label
            backendMenu.addItem(item)
        }
        menu.setSubmenu(backendMenu, for: backendItem)
        menu.addItem(backendItem)

        let meetingBackendItem = NSMenuItem(title: "Meetings Backend", action: nil, keyEquivalent: "")
        let meetingBackendMenu = NSMenu()
        for option in MeetingSummaryBackendOption.all {
            let prefix = controller.selectedMeetingSummaryBackend == option ? "✓ " : ""
            let item = NSMenuItem(
                title: "\(prefix)\(option.label)",
                action: #selector(MuesliController.selectMeetingSummaryBackendFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            item.representedObject = option.label
            meetingBackendMenu.addItem(item)
        }
        menu.setSubmenu(meetingBackendMenu, for: meetingBackendItem)
        menu.addItem(meetingBackendItem)

        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Settings…", action: #selector(MuesliController.openSettingsTab)))
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Quit", action: #selector(MuesliController.quitApp)))
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = controller
        return item
    }
}
