import Foundation
import MuesliCore

/// Post-processing step that replaces transcribed words with entries from
/// the user's personal dictionary using fuzzy matching.
///
/// Matching stages (first match wins):
/// 1. Exact case-insensitive match
/// 2. Jaro-Winkler similarity >= the entry's configured threshold
struct CustomWordMatcher {

    struct Entry {
        let word: String
        let replacement: String
        let matchingThreshold: Double
    }

    /// Apply custom word replacements to transcribed text.
    static func apply(text: String, customWords: [CustomWord]) -> String {
        guard !text.isEmpty, !customWords.isEmpty else { return text }

        let entries = customWords.map {
            Entry(word: $0.word, replacement: $0.targetWord, matchingThreshold: $0.matchingThreshold)
        }
        let words = text.components(separatedBy: " ")
        var result: [String] = []

        for word in words {
            // Strip trailing punctuation for matching
            let punctuation = CharacterSet(charactersIn: ".,!?;:")
            let stripped = word.trimmingCharacters(in: punctuation)
            let trailing = String(word.dropFirst(stripped.count))
            let wordLower = stripped.lowercased()

            guard !wordLower.isEmpty else {
                result.append(word)
                continue
            }

            var bestMatch: String?
            var bestScore: Double = 0

            for entry in entries {
                let targetLower = entry.word.lowercased()

                // Stage 1: Exact match
                if wordLower == targetLower {
                    bestMatch = entry.replacement
                    break
                }

                // Stage 2: Jaro-Winkler similarity
                let score = jaroWinklerSimilarity(wordLower, targetLower)
                if score >= entry.matchingThreshold && score > bestScore {
                    bestScore = score
                    bestMatch = entry.replacement
                }
            }

            if let match = bestMatch {
                result.append(match + trailing)
            } else {
                result.append(word)
            }
        }

        return result.joined(separator: " ")
    }

    // MARK: - Jaro-Winkler Similarity

    /// Computes Jaro-Winkler similarity between two strings (0.0 to 1.0).
    static func jaroWinklerSimilarity(_ s1: String, _ s2: String) -> Double {
        let jaro = jaroSimilarity(s1, s2)
        guard jaro > 0 else { return 0 }

        // Winkler modification: boost for common prefix (up to 4 chars)
        let chars1 = Array(s1)
        let chars2 = Array(s2)
        let prefixLen = min(4, min(chars1.count, chars2.count))
        var commonPrefix = 0
        for i in 0..<prefixLen {
            if chars1[i] == chars2[i] {
                commonPrefix += 1
            } else {
                break
            }
        }

        return jaro + Double(commonPrefix) * 0.1 * (1.0 - jaro)
    }

    /// Computes Jaro similarity between two strings.
    private static func jaroSimilarity(_ s1: String, _ s2: String) -> Double {
        let chars1 = Array(s1)
        let chars2 = Array(s2)

        if chars1.isEmpty && chars2.isEmpty { return 1.0 }
        if chars1.isEmpty || chars2.isEmpty { return 0.0 }
        if chars1 == chars2 { return 1.0 }

        let matchWindow = max(chars1.count, chars2.count) / 2 - 1
        guard matchWindow >= 0 else { return 0.0 }

        var s1Matches = [Bool](repeating: false, count: chars1.count)
        var s2Matches = [Bool](repeating: false, count: chars2.count)

        var matches: Double = 0
        var transpositions: Double = 0

        // Find matches
        for i in 0..<chars1.count {
            let start = max(0, i - matchWindow)
            let end = min(chars2.count - 1, i + matchWindow)
            guard start <= end else { continue }

            for j in start...end {
                if s2Matches[j] || chars1[i] != chars2[j] { continue }
                s1Matches[i] = true
                s2Matches[j] = true
                matches += 1
                break
            }
        }

        guard matches > 0 else { return 0.0 }

        // Count transpositions
        var k = 0
        for i in 0..<chars1.count {
            guard s1Matches[i] else { continue }
            while !s2Matches[k] { k += 1 }
            if chars1[i] != chars2[k] { transpositions += 1 }
            k += 1
        }

        let m = matches
        let t = transpositions / 2.0
        return (m / Double(chars1.count) + m / Double(chars2.count) + (m - t) / m) / 3.0
    }
}
