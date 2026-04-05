import AppKit

/// Plays subtle system sounds for dictation lifecycle events.
/// Plays subtle system sounds for dictation lifecycle events.
/// Sounds are skipped when `soundEnabled` is false.
enum SoundController {
    static func playDictationStart(enabled: Bool) {
        guard enabled else { return }
        NSSound(named: .init("Tink"))?.play()
    }

    static func playDictationInsert(enabled: Bool) {
        guard enabled else { return }
        NSSound(named: .init("Purr"))?.play()
    }
}
