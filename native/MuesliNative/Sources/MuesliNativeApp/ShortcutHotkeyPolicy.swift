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
    static let conflictMessage = "Push to Talk and Computer Use Command need different keys."

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
        isComputerUseEnabled: Bool
    ) -> ShortcutHotkeyUpdateResult {
        guard !isComputerUseEnabled || !hotkeysConflict(hotkey, computerUseHotkey) else {
            return .conflict(message: conflictMessage)
        }
        return .updated
    }

    static func validateComputerUseHotkey(
        _ hotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool
    ) -> ShortcutHotkeyUpdateResult {
        guard !isComputerUseEnabled || !hotkeysConflict(hotkey, dictationHotkey) else {
            return .conflict(message: conflictMessage)
        }
        return .updated
    }

    static func resolvedComputerUseHotkeyWhenEnabling(
        currentHotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig
    ) -> (hotkey: HotkeyConfig, result: ShortcutHotkeyUpdateResult) {
        guard hotkeysConflict(currentHotkey, dictationHotkey) else {
            return (currentHotkey, .updated)
        }

        let fallback = HotkeyConfig.computerUseDefault(avoiding: dictationHotkey)
        return (
            fallback,
            .updated(notice: "Computer Use Command moved to \(fallback.label) to avoid matching Push to Talk.")
        )
    }
}
