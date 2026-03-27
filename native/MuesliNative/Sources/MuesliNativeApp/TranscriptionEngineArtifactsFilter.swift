import Foundation

/// Removes known model hallucination artifacts emitted on silence or blank input.
/// Applied as post-processing after ASR, before filler word filtering.
struct TranscriptionEngineArtifactsFilter {

    private static let artifacts: Set<String> = [
        "[blank_audio]",
    ]

    private static let promptLeakPatterns: [String] = [
        #"(?i)\btranscribe the spoken audio accurately\.?"#,
        #"(?i)\bif a word is unclear,?\s*use the most likely word that fits well within the context of the overall sentence(?:\s+transcription)?\.?"#,
    ]

    /// Returns an empty string if the entire transcription is a known blank-audio artifact;
    /// otherwise removes known prompt leakage while preserving normal transcript text.
    static func apply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if artifacts.contains(trimmed.lowercased()) {
            return ""
        }

        let stripped = stripPromptLeakage(from: trimmed)
        return stripped
    }

    private static func stripPromptLeakage(from text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        for pattern in promptLeakPatterns {
            result = replaceAnchoredPromptLeak(in: result, pattern: pattern, anchorAtStart: true)
            result = replaceAnchoredPromptLeak(in: result, pattern: pattern, anchorAtStart: false)
        }

        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceAnchoredPromptLeak(in text: String, pattern: String, anchorAtStart: Bool) -> String {
        let anchoredPattern = anchorAtStart
            ? #"^\s*(?:"# + pattern + #")(?:\s+|$)"#
            : #"(?:^|\s+)(?:"# + pattern + #")\s*$"#
        return text.replacingOccurrences(of: anchoredPattern, with: " ", options: .regularExpression)
    }
}
