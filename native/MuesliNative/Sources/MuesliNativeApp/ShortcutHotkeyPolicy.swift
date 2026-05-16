enum ShortcutHotkeyUpdateResult: Equatable {
    case updated(notice: String?)
    case conflict(message: String)

    var message: String? {
        switch self {
        case .updated(let notice):
            return notice
        case .conflict(let message):
            return message
        }
    }

    var didUpdate: Bool {
        switch self {
        case .updated:
            return true
        case .conflict:
            return false
        }
    }

    static var updated: ShortcutHotkeyUpdateResult {
        .updated(notice: nil)
    }
}

struct ShortcutHotkeyPolicy {
    static let conflictMessage = "These shortcuts need different keys."

    static func hotkeysConflict(_ a: HotkeyConfig, _ b: HotkeyConfig) -> Bool {
        if a.isCombination != b.isCombination { return false }
        if a.isCombination {
            return a.combinationModifiers == b.combinationModifiers
                && a.combinationKeyCode == b.combinationKeyCode
        }
        return a.keyCode == b.keyCode
    }

    static func validateDictationHotkey(
        _ hotkey: HotkeyConfig,
        computerUseHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool,
        meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault,
        isMeetingRecordingEnabled: Bool = false
    ) -> ShortcutHotkeyUpdateResult {
        if isComputerUseEnabled && hotkeysConflict(hotkey, computerUseHotkey) {
            return .conflict(message: conflictMessage)
        }
        if isMeetingRecordingEnabled && hotkeysConflict(hotkey, meetingRecordingHotkey) {
            return .conflict(message: conflictMessage)
        }
        return .updated
    }

    static func validateComputerUseHotkey(
        _ hotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool,
        meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault,
        isMeetingRecordingEnabled: Bool = false
    ) -> ShortcutHotkeyUpdateResult {
        if isComputerUseEnabled && hotkeysConflict(hotkey, dictationHotkey) {
            return .conflict(message: conflictMessage)
        }
        if isMeetingRecordingEnabled && hotkeysConflict(hotkey, meetingRecordingHotkey) {
            return .conflict(message: conflictMessage)
        }
        return .updated
    }

    static func validateMeetingRecordingHotkey(
        _ hotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        computerUseHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool
    ) -> ShortcutHotkeyUpdateResult {
        if hotkeysConflict(hotkey, dictationHotkey) {
            return .conflict(message: conflictMessage)
        }
        if isComputerUseEnabled && hotkeysConflict(hotkey, computerUseHotkey) {
            return .conflict(message: conflictMessage)
        }
        return .updated
    }

    static func resolvedComputerUseHotkeyWhenEnabling(
        currentHotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault,
        isMeetingRecordingEnabled: Bool = false
    ) -> (hotkey: HotkeyConfig, result: ShortcutHotkeyUpdateResult) {
        var resolved = currentHotkey
        var notice: String?

        if hotkeysConflict(resolved, dictationHotkey) {
            resolved = HotkeyConfig.computerUseDefault(avoiding: dictationHotkey)
            notice = "Computer Use Command moved to \(resolved.label) to avoid matching Push to Talk."
        }
        if isMeetingRecordingEnabled && hotkeysConflict(resolved, meetingRecordingHotkey) {
            if notice != nil {
                // Already moved to avoid dictation but still conflicts with meeting recording — no fallback left
                return (currentHotkey, .conflict(message: conflictMessage))
            }
            resolved = HotkeyConfig.computerUseDefault(avoiding: dictationHotkey)
            notice = "Computer Use Command moved to \(resolved.label) to avoid matching Meeting Recording."
        }
        return (resolved, .updated(notice: notice))
    }
}
