import FluidAudio
import Foundation
import MuesliCore

struct ReconciledTranscriptInputs {
    let micSegments: [SpeechSegment]
    let systemSegments: [SpeechSegment]
    let diarizationSegments: [TimedSpeakerSegment]?
}

enum TranscriptReconciler {
    static func reconcile(
        micTurns: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?
    ) -> ReconciledTranscriptInputs {
        let orderedMicTurns = micTurns.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
        let dedupedSystemSegments = dedupeSystemSegments(systemSegments)
        let keptSystemSegments = dedupedSystemSegments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }
        var keptMicTurns: [SpeechSegment] = []

        for micTurn in orderedMicTurns {
            let overlappingSystemSegments = keptSystemSegments.filter { overlapDuration(between: micTurn, and: $0) > 0 }
            if shouldDropMicTurn(micTurn, overlappingSystemSegments: overlappingSystemSegments) {
                continue
            }

            keptMicTurns.append(micTurn)
        }

        return ReconciledTranscriptInputs(
            micSegments: keptMicTurns,
            systemSegments: keptSystemSegments,
            diarizationSegments: diarizationSegments
        )
    }

    private static func shouldDropMicTurn(
        _ micTurn: SpeechSegment,
        overlappingSystemSegments: [SpeechSegment]
    ) -> Bool {
        guard !overlappingSystemSegments.isEmpty else { return false }

        let normalizedMicText = normalizedText(micTurn.text)
        guard !normalizedMicText.isEmpty else { return true }

        let combinedSystemText = normalizedText(overlappingSystemSegments.map(\.text).joined(separator: " "))
        guard !combinedSystemText.isEmpty else { return false }

        let overlapCoverage = overlapCoverage(of: micTurn, across: overlappingSystemSegments)
        let micVisibleLength = visibleLength(of: micTurn.text)
        let micTokens = tokenSet(from: normalizedMicText)
        let systemTokens = tokenSet(from: combinedSystemText)
        let tokenContainment = tokenContainmentRatio(
            source: micTokens,
            target: systemTokens
        )
        let isSubstringDuplicate =
            combinedSystemText.contains(normalizedMicText) || normalizedMicText.contains(combinedSystemText)

        if overlapCoverage >= 0.5 && (tokenContainment >= 0.67 || isSubstringDuplicate) {
            return true
        }

        if micVisibleLength < 12 && overlapCoverage >= 0.5 {
            return true
        }

        let combinedSystemVisibleLength = visibleLength(of: overlappingSystemSegments.map(\.text).joined(separator: " "))
        if overlapCoverage >= 0.6,
           overlappingSystemSegments.count >= 2,
           micVisibleLength >= 18,
           combinedSystemVisibleLength >= 20,
           tokenContainment < 0.55 {
            return true
        }

        if overlapCoverage >= 0.75,
           overlappingSystemSegments.count >= 2,
           micVisibleLength >= 18,
           systemTokens.count >= micTokens.count + 4 {
            return true
        }

        return false
    }

    private static func dedupeSystemSegments(_ systemSegments: [SpeechSegment]) -> [SpeechSegment] {
        let orderedSegments = systemSegments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        return orderedSegments.enumerated().compactMap { index, segment in
            let normalizedSegmentText = normalizedText(segment.text)
            guard !normalizedSegmentText.isEmpty else { return nil }

            let shouldDrop = orderedSegments.enumerated().contains { otherIndex, otherSegment in
                guard otherIndex != index else { return false }
                let overlapCoverage = overlapCoverage(of: segment, across: [otherSegment])
                guard overlapCoverage >= 0.5 else { return false }

                let normalizedOtherText = normalizedText(otherSegment.text)
                guard !normalizedOtherText.isEmpty else { return false }

                let segmentVisibleLength = visibleLength(of: segment.text)
                guard segmentVisibleLength < 12 else { return false }

                if normalizedOtherText.contains(normalizedSegmentText) {
                    return true
                }

                let segmentTokens = tokenSet(from: normalizedSegmentText)
                let otherTokens = tokenSet(from: normalizedOtherText)
                return tokenContainmentRatio(source: segmentTokens, target: otherTokens) >= 0.67
            }

            return shouldDrop ? nil : segment
        }
    }

    private static func overlapCoverage(
        of segment: SpeechSegment,
        across otherSegments: [SpeechSegment]
    ) -> Double {
        let duration = max(segment.end - segment.start, 0.1)
        let overlap = otherSegments.reduce(0.0) { partialResult, otherSegment in
            partialResult + overlapDuration(between: segment, and: otherSegment)
        }
        return overlap / duration
    }

    private static func overlapDuration(
        between lhs: SpeechSegment,
        and rhs: SpeechSegment
    ) -> TimeInterval {
        max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
    }

    private static func normalizedText(_ text: String) -> String {
        let lowercase = text.lowercased()
        let replaced = lowercase.replacingOccurrences(
            of: #"[^a-z0-9\s]"#,
            with: " ",
            options: .regularExpression
        )
        return replaced.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenSet(from text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    private static func tokenContainmentRatio(source: Set<String>, target: Set<String>) -> Double {
        guard !source.isEmpty else { return 0 }
        return Double(source.intersection(target).count) / Double(source.count)
    }

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
    }
}
