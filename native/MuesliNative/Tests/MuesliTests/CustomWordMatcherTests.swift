import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Jaro-Winkler Similarity")
struct JaroWinklerTests {

    @Test("identical strings return 1.0")
    func identical() {
        #expect(CustomWordMatcher.jaroWinklerSimilarity("hello", "hello") == 1.0)
    }

    @Test("completely different strings return low score")
    func different() {
        let score = CustomWordMatcher.jaroWinklerSimilarity("abc", "xyz")
        #expect(score < 0.5)
    }

    @Test("similar strings score high")
    func similar() {
        let score = CustomWordMatcher.jaroWinklerSimilarity("pranav", "pranab")
        #expect(score > 0.85)
    }

    @Test("empty strings")
    func empty() {
        #expect(CustomWordMatcher.jaroWinklerSimilarity("", "") == 1.0)
        #expect(CustomWordMatcher.jaroWinklerSimilarity("hello", "") == 0.0)
        #expect(CustomWordMatcher.jaroWinklerSimilarity("", "hello") == 0.0)
    }

    @Test("single character strings don't crash")
    func singleChar() {
        let score = CustomWordMatcher.jaroWinklerSimilarity("a", "b")
        #expect(score >= 0 && score <= 1)
        let score2 = CustomWordMatcher.jaroWinklerSimilarity("a", "a")
        #expect(score2 == 1.0)
        let score3 = CustomWordMatcher.jaroWinklerSimilarity("I", "muesli")
        #expect(score3 >= 0 && score3 <= 1)
    }

    @Test("short vs long strings don't crash")
    func shortVsLong() {
        let score = CustomWordMatcher.jaroWinklerSimilarity("a", "abcdefghij")
        #expect(score >= 0 && score <= 1)
    }

    @Test("common prefix boosts score")
    func prefixBoost() {
        let withPrefix = CustomWordMatcher.jaroWinklerSimilarity("muesli", "muesly")
        let noPrefix = CustomWordMatcher.jaroWinklerSimilarity("xuesli", "muesly")
        #expect(withPrefix > noPrefix)
    }
}

@Suite("Custom Word Matcher")
struct CustomWordMatcherApplyTests {

    @Test("exact match replaces word")
    func exactMatch() {
        let words = [CustomWord(word: "museli", replacement: "muesli")]
        let result = CustomWordMatcher.apply(text: "I love museli", customWords: words)
        #expect(result == "I love muesli")
    }

    @Test("case-insensitive exact match")
    func caseInsensitive() {
        let words = [CustomWord(word: "Pranav", replacement: "Pranav")]
        let result = CustomWordMatcher.apply(text: "hello pranav", customWords: words)
        #expect(result == "hello Pranav")
    }

    @Test("preserves punctuation")
    func preservesPunctuation() {
        let words = [CustomWord(word: "museli", replacement: "muesli")]
        let result = CustomWordMatcher.apply(text: "I love museli!", customWords: words)
        #expect(result == "I love muesli!")
    }

    @Test("fuzzy match replaces similar word")
    func fuzzyMatch() {
        let words = [CustomWord(word: "kubernetes", replacement: "Kubernetes")]
        let result = CustomWordMatcher.apply(text: "deploy to kubernete", customWords: words)
        // "kubernete" vs "kubernetes" should be > 0.85 Jaro-Winkler
        #expect(result == "deploy to Kubernetes")
    }

    @Test("no match leaves word unchanged")
    func noMatch() {
        let words = [CustomWord(word: "muesli", replacement: "Muesli")]
        let result = CustomWordMatcher.apply(text: "hello world", customWords: words)
        #expect(result == "hello world")
    }

    @Test("empty text returns empty")
    func emptyText() {
        let words = [CustomWord(word: "test", replacement: "Test")]
        #expect(CustomWordMatcher.apply(text: "", customWords: words) == "")
    }

    @Test("empty custom words returns original")
    func emptyWords() {
        #expect(CustomWordMatcher.apply(text: "hello", customWords: []) == "hello")
    }

    @Test("word with no replacement uses word itself")
    func noReplacement() {
        let words = [CustomWord(word: "muesli", replacement: nil)]
        let result = CustomWordMatcher.apply(text: "I love museli", customWords: words)
        // "museli" fuzzy matches "muesli", replacement is nil so uses word "muesli"
        #expect(result == "I love muesli")
    }

    @Test("per-word lower threshold allows aggressive fuzzy correction")
    func lowerThresholdAllowsCorrection() {
        let words = [CustomWord(word: "Caivex", replacement: "Caivex", matchingThreshold: 0.70)]
        let result = CustomWordMatcher.apply(text: "talk to Kvex tomorrow", customWords: words)
        #expect(result == "talk to Caivex tomorrow")
    }

    @Test("higher threshold blocks over-eager fuzzy correction")
    func higherThresholdPreventsCorrection() {
        let words = [CustomWord(word: "Caivex", replacement: "Caivex", matchingThreshold: 0.92)]
        let result = CustomWordMatcher.apply(text: "talk to Kvex tomorrow", customWords: words)
        #expect(result == "talk to Kvex tomorrow")
    }
}
