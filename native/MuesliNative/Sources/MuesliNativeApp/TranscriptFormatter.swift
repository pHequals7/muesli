import FluidAudio
import Foundation
import MuesliCore

enum TranscriptFormatter {
    /// Backward-compatible merge without diarization.
    static func merge(micSegments: [SpeechSegment], systemSegments: [SpeechSegment], meetingStart: Date) -> String {
        merge(micSegments: micSegments, systemSegments: systemSegments, diarizationSegments: nil, meetingStart: meetingStart)
    }

    /// Merge with optional speaker diarization for system audio.
    static func merge(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment],
        diarizationSegments: [TimedSpeakerSegment]?,
        meetingStart: Date
    ) -> String {
        let displayMicSegments = prepareMicSegmentsForDisplay(
            micSegments: micSegments,
            systemSegments: systemSegments
        )
        let taggedMic = displayMicSegments.map { TaggedSegment(segment: $0, speaker: "You") }

        let taggedSystem: [TaggedSegment]
        if let diarizationSegments, !diarizationSegments.isEmpty {
            // Build speaker label map: raw ID → "Speaker 1", "Speaker 2", etc. in first-appearance order
            var speakerLabelMap: [String: String] = [:]
            var nextSpeakerNumber = 1
            for seg in diarizationSegments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
                if speakerLabelMap[seg.speakerId] == nil {
                    speakerLabelMap[seg.speakerId] = "Speaker \(nextSpeakerNumber)"
                    nextSpeakerNumber += 1
                }
            }

            taggedSystem = systemSegments.map { segment in
                let speaker = findSpeaker(for: segment, in: diarizationSegments, labelMap: speakerLabelMap)
                return TaggedSegment(segment: segment, speaker: speaker)
            }
        } else {
            taggedSystem = systemSegments.map { TaggedSegment(segment: $0, speaker: "Others") }
        }

        let tagged = (taggedMic + taggedSystem).sorted { $0.segment.start < $1.segment.start }

        // Consolidate consecutive segments from the same speaker into single lines
        let consolidated = filterLowSignalSegments(consolidate(tagged))

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"

        return consolidated.map { taggedSegment in
            let timestamp = meetingStart.addingTimeInterval(taggedSegment.segment.start)
            let text = taggedSegment.segment.text.trimmingCharacters(in: .whitespaces)
            return "[\(formatter.string(from: timestamp))] \(taggedSegment.speaker): \(text)"
        }.joined(separator: "\n")
    }

    /// Merge consecutive segments from the same speaker into single entries.
    /// Prevents token-level fragmentation (e.g., each token as a separate line).
    /// Caps merged duration to avoid monolithic blocks when mic fallback produces
    /// many sentence-level segments with no interleaved system turns.
    private static let maxConsolidatedDurationSeconds: TimeInterval = 30.0

    private static func consolidate(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TaggedSegment] = []
        var currentSpeaker = segments[0].speaker
        var currentStart = segments[0].segment.start
        var currentEnd = segments[0].segment.end
        var currentText = segments[0].segment.text

        for seg in segments.dropFirst() {
            let mergedDuration = seg.segment.end - currentStart
            if seg.speaker == currentSpeaker, mergedDuration <= maxConsolidatedDurationSeconds {
                // Same speaker within duration cap — accumulate text
                let gap = max(0, seg.segment.start - currentEnd)
                currentText = appendText(currentText, seg.segment.text, gap: gap)
                currentEnd = max(currentEnd, seg.segment.end)
            } else {
                // Speaker changed or duration cap reached — emit accumulated segment
                result.append(TaggedSegment(
                    segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
                    speaker: currentSpeaker
                ))
                currentSpeaker = seg.speaker
                currentStart = seg.segment.start
                currentEnd = seg.segment.end
                currentText = seg.segment.text
            }
        }
        // Emit last segment
        result.append(TaggedSegment(
            segment: SpeechSegment(start: currentStart, end: currentEnd, text: currentText),
            speaker: currentSpeaker
        ))

        return result
    }

    private static func filterLowSignalSegments(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        guard !segments.isEmpty else { return [] }

        return segments.enumerated().compactMap { index, segment in
            isLowSignalFragment(segment, at: index, in: segments) ? nil : segment
        }
    }

    private static func isLowSignalFragment(
        _ taggedSegment: TaggedSegment,
        at index: Int,
        in segments: [TaggedSegment]
    ) -> Bool {
        let normalized = normalizedText(taggedSegment.segment.text)
        let compact = normalized.replacingOccurrences(of: " ", with: "")
        let duration = max(taggedSegment.segment.end - taggedSegment.segment.start, 0)

        if compact.isEmpty {
            return true
        }

        if compact.count == 1 {
            return true
        }

        guard compact.count <= 2, duration <= 0.45 else { return false }

        return neighboringSegments(for: index, in: segments).contains { neighbor in
            let neighborText = normalizedText(neighbor.segment.text).replacingOccurrences(of: " ", with: "")
            guard neighborText.count >= 6 else { return false }
            return temporalDistance(between: taggedSegment.segment, and: neighbor.segment) <= 0.35
        }
    }

    /// Find the best-matching speaker for an ASR segment by time overlap with diarization segments.
    private static func findSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> String {
        if labelMap.count == 1 {
            return labelMap.values.first ?? "Others"
        }

        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1)) // ensure non-zero duration

        var bestOverlap: Float = 0
        var bestSpeakerId: String?

        for diarSeg in diarizationSegments {
            let overlapStart = max(segStart, diarSeg.startTimeSeconds)
            let overlapEnd = min(segEnd, diarSeg.endTimeSeconds)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerId = diarSeg.speakerId
            }
        }

        if let bestSpeakerId, bestOverlap > 0 {
            return labelMap[bestSpeakerId] ?? "Others"
        }

        if let nearestSpeakerId = nearestSpeaker(
            for: segment,
            in: diarizationSegments,
            maxGapSeconds: 2.0
        ) {
            return labelMap[nearestSpeakerId] ?? "Others"
        }
        return "Others"
    }

    private static func prepareMicSegmentsForDisplay(
        micSegments: [SpeechSegment],
        systemSegments: [SpeechSegment]
    ) -> [SpeechSegment] {
        micSegments.compactMap { micSegment in
            cleanedMicSegmentForDisplay(micSegment, systemSegments: systemSegments)
        }
    }

    private static func cleanedMicSegmentForDisplay(
        _ micSegment: SpeechSegment,
        systemSegments: [SpeechSegment]
    ) -> SpeechSegment? {
        let overlappingSystemSegments = systemSegments.filter {
            overlapDuration(between: micSegment, and: $0) > 0
        }
        guard !overlappingSystemSegments.isEmpty else { return micSegment }

        let normalizedMic = normalizedText(micSegment.text)
        guard !normalizedMic.isEmpty else { return nil }

        let combinedSystemText = normalizedText(overlappingSystemSegments.map(\.text).joined(separator: " "))
        guard !combinedSystemText.isEmpty else { return micSegment }

        let overlapCoverage = overlapCoverage(of: micSegment, across: overlappingSystemSegments)
        let micTokens = tokenSet(from: normalizedMic)
        let systemTokens = tokenSet(from: combinedSystemText)
        let tokenContainment = tokenContainmentRatio(source: micTokens, target: systemTokens)
        let isSubstringDuplicate =
            combinedSystemText.contains(normalizedMic) || normalizedMic.contains(combinedSystemText)

        guard overlapCoverage >= 0.65, tokenContainment >= 0.7 || isSubstringDuplicate else {
            return micSegment
        }

        let firstOverlapStart = overlappingSystemSegments.map(\.start).min() ?? micSegment.start
        let leadInDuration = max(0, firstOverlapStart - micSegment.start)
        let micDuration = max(micSegment.end - micSegment.start, 0.1)
        let leadInRatio = min(max(leadInDuration / micDuration, 0), 1)

        guard leadInDuration >= 0.75 else {
            return nil
        }

        let trimmedText = leadingPortion(of: micSegment.text, keepRatio: leadInRatio)
        guard visibleLength(of: trimmedText) >= 8 else { return nil }

        return SpeechSegment(
            start: micSegment.start,
            end: max(firstOverlapStart, micSegment.start + 0.1),
            text: trimmedText
        )
    }

    private static func leadingPortion(of text: String, keepRatio: Double) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return text }

        let clampedRatio = min(max(keepRatio, 0), 1)
        let keepCount = min(
            words.count,
            max(1, Int(ceil(Double(words.count) * clampedRatio)))
        )
        return words.prefix(keepCount).joined(separator: " ")
    }

    private static func nearestSpeaker(
        for segment: SpeechSegment,
        in diarizationSegments: [TimedSpeakerSegment],
        maxGapSeconds: Float
    ) -> String? {
        let segStart = Float(segment.start)
        let segEnd = Float(max(segment.end, segment.start + 0.1))
        let segMidpoint = (segStart + segEnd) / 2

        let nearest = diarizationSegments.min { lhs, rhs in
            temporalGap(between: segMidpoint, and: lhs) < temporalGap(between: segMidpoint, and: rhs)
        }

        guard let nearest else { return nil }
        return temporalGap(between: segMidpoint, and: nearest) <= maxGapSeconds ? nearest.speakerId : nil
    }

    private static func temporalGap(
        between point: Float,
        and diarizationSegment: TimedSpeakerSegment
    ) -> Float {
        if point < diarizationSegment.startTimeSeconds {
            return diarizationSegment.startTimeSeconds - point
        }
        if point > diarizationSegment.endTimeSeconds {
            return point - diarizationSegment.endTimeSeconds
        }
        return 0
    }

    private static func overlapDuration(
        between lhs: SpeechSegment,
        and rhs: SpeechSegment
    ) -> TimeInterval {
        max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
    }

    private static func overlapCoverage(
        of segment: SpeechSegment,
        across otherSegments: [SpeechSegment]
    ) -> Double {
        let duration = max(segment.end - segment.start, 0.1)
        let overlap = unionOverlapDuration(of: segment, across: otherSegments)
        return overlap / duration
    }

    private static func unionOverlapDuration(
        of segment: SpeechSegment,
        across otherSegments: [SpeechSegment]
    ) -> TimeInterval {
        let clippedIntervals = otherSegments.compactMap { otherSegment -> (TimeInterval, TimeInterval)? in
            let overlapStart = max(segment.start, otherSegment.start)
            let overlapEnd = min(segment.end, otherSegment.end)
            guard overlapEnd > overlapStart else { return nil }
            return (overlapStart, overlapEnd)
        }.sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1 < rhs.1
            }
            return lhs.0 < rhs.0
        }

        guard var current = clippedIntervals.first else { return 0 }
        var total: TimeInterval = 0

        for interval in clippedIntervals.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1 - current.0
                current = interval
            }
        }

        total += current.1 - current.0
        return total
    }

    private static func temporalDistance(
        between lhs: SpeechSegment,
        and rhs: SpeechSegment
    ) -> TimeInterval {
        if overlapDuration(between: lhs, and: rhs) > 0 {
            return 0
        }
        if lhs.end <= rhs.start {
            return rhs.start - lhs.end
        }
        return lhs.start - rhs.end
    }

    private static func neighboringSegments(for index: Int, in segments: [TaggedSegment]) -> [TaggedSegment] {
        var neighbors: [TaggedSegment] = []
        if index > 0 {
            neighbors.append(segments[index - 1])
        }
        if index + 1 < segments.count {
            neighbors.append(segments[index + 1])
        }
        return neighbors
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

    private static func appendText(_ lhs: String, _ rhs: String, gap: TimeInterval) -> String {
        if shouldConcatenateDirectly(lhs, rhs, gap: gap) {
            return lhs + rhs
        }
        return joinText(lhs, rhs)
    }

    private static func shouldConcatenateDirectly(_ lhs: String, _ rhs: String, gap: TimeInterval) -> Bool {
        guard gap <= 0.35 else { return false }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        guard !rhs.contains(where: \.isWhitespace) else { return false }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else { return false }
        guard !lhsLast.isWhitespace, !rhsFirst.isWhitespace, !rhsFirst.isPunctuation else { return false }

        let lhsLastToken = lhs.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? lhs
        guard !lhsLastToken.contains(where: \.isWhitespace) else { return false }

        let lhsVisibleLength = visibleLength(of: lhsLastToken)
        let rhsVisibleLength = visibleLength(of: rhs)
        return lhsVisibleLength + rhsVisibleLength <= 8
    }

    private static func joinText(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        guard let lhsLast = lhs.last, let rhsFirst = rhs.first else {
            return lhs + rhs
        }

        if lhsLast.isWhitespace || rhsFirst.isWhitespace || rhsFirst.isPunctuation {
            return lhs + rhs
        }

        if lhsLast.isPunctuation {
            return lhs + " " + rhs
        }

        return lhs + " " + rhs
    }

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
    }

    private static func tokenSet(from text: String) -> Set<String> {
        Set(text.split(separator: " ").map(String.init))
    }

    private static func tokenContainmentRatio(source: Set<String>, target: Set<String>) -> Double {
        guard !source.isEmpty else { return 0 }
        return Double(source.intersection(target).count) / Double(source.count)
    }
}

private struct TaggedSegment {
    let segment: SpeechSegment
    let speaker: String
}
