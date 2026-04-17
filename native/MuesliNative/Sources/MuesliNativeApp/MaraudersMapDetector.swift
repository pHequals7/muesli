import Foundation

/// Detects the Marauder's Map activation phrase in transcribed text.
/// Normalises for common ASR variations (dropped words, contractions, punctuation).
enum MaraudersMapDetector {
    private static let canonicalPhrases: [String] = [
        "i solemnly swear that i am up to no good",
        "i solemnly swear i am up to no good",
        "i solemnly swear that im up to no good",
        "i solemnly swear im up to no good",
    ]

    static func containsActivationPhrase(_ text: String) -> Bool {
        let normalized = normalize(text)
        return canonicalPhrases.contains { normalized.contains($0) }
    }

    private static func normalize(_ text: String) -> String {
        var result = text.lowercased()
        // Strip punctuation
        let punctuation = CharacterSet.punctuationCharacters
            .union(.init(charactersIn: "\"'\u{2018}\u{2019}\u{201C}\u{201D}"))
        result = result.unicodeScalars
            .filter { !punctuation.contains($0) }
            .map { String($0) }
            .joined()
        // Collapse whitespace
        result = result.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return result
    }
}
