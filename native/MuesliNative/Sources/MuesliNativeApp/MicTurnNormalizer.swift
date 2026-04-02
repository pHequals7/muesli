import FluidAudio
import Foundation

enum MicTurnNormalizer {
    private static let maxMergeGapSeconds: TimeInterval = 0.35
    private static let shortSegmentVisibleLength = 8
    private static let fragmentationVisibleLength = 4

    static func normalize(
        result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return [] }

        let clampedEndTime = max(endTime, startTime + 0.1)
        let timedSegments = timedSegments(from: result, startTime: startTime, endTime: clampedEndTime)

        guard !timedSegments.isEmpty else {
            return [SpeechSegment(start: startTime, end: clampedEndTime, text: trimmedText)]
        }

        if isFragmented(timedSegments) {
            return [SpeechSegment(start: startTime, end: clampedEndTime, text: trimmedText)]
        }

        let mergedSegments = mergeAdjacentSegments(timedSegments)
        guard !isFragmented(mergedSegments) else {
            return [SpeechSegment(start: startTime, end: clampedEndTime, text: trimmedText)]
        }

        return mergedSegments
    }

    private static func timedSegments(
        from result: SpeechTranscriptionResult,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> [SpeechSegment] {
        let hasMeaningfulTimings = result.segments.contains { segment in
            segment.end > segment.start || segment.start > 0
        }
        guard hasMeaningfulTimings else { return [] }

        return result.segments.compactMap { segment in
            let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return nil }

            let absoluteStart = min(endTime, max(startTime, startTime + max(segment.start, 0)))
            let absoluteEnd = min(endTime, max(absoluteStart, startTime + max(segment.end, segment.start)))

            return SpeechSegment(start: absoluteStart, end: absoluteEnd, text: trimmedText)
        }
    }

    private static func mergeAdjacentSegments(_ segments: [SpeechSegment]) -> [SpeechSegment] {
        guard !segments.isEmpty else { return [] }

        let orderedSegments = segments.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.text < rhs.text
            }
            return lhs.start < rhs.start
        }

        var merged: [SpeechSegment] = [orderedSegments[0]]

        for segment in orderedSegments.dropFirst() {
            guard let previous = merged.last else {
                merged.append(segment)
                continue
            }

            let gap = max(0, segment.start - previous.end)
            let shouldMerge = gap <= maxMergeGapSeconds
                || visibleLength(of: previous.text) < shortSegmentVisibleLength
                || visibleLength(of: segment.text) < shortSegmentVisibleLength

            if shouldMerge {
                merged[merged.count - 1] = SpeechSegment(
                    start: previous.start,
                    end: max(previous.end, segment.end),
                    text: joinText(previous.text, segment.text)
                )
            } else {
                merged.append(segment)
            }
        }

        return merged
    }

    private static func isFragmented(_ segments: [SpeechSegment]) -> Bool {
        guard segments.count > 3 else { return false }

        let visibleLengths = segments.map { visibleLength(of: $0.text) }
        let shortSegmentCount = visibleLengths.filter { $0 <= fragmentationVisibleLength }.count
        let averageVisibleLength = Double(visibleLengths.reduce(0, +)) / Double(visibleLengths.count)

        return Double(shortSegmentCount) / Double(segments.count) >= 0.5 || averageVisibleLength < 8
    }

    private static func visibleLength(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : 1)
        }
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
}
