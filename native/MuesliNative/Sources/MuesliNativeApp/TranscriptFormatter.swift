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
        let filteredMicSegments = filterEchoLikeMicSegments(micSegments, against: systemSegments)
        let taggedMic = filteredMicSegments.map { TaggedSegment(segment: $0, speaker: "You") }

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
    private static func consolidate(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        guard !segments.isEmpty else { return [] }

        var result: [TaggedSegment] = []
        var currentSpeaker = segments[0].speaker
        var currentStart = segments[0].segment.start
        var currentEnd = segments[0].segment.end
        var currentText = segments[0].segment.text

        for seg in segments.dropFirst() {
            if seg.speaker == currentSpeaker {
                // Same speaker — accumulate text
                currentText += seg.segment.text
                currentEnd = max(currentEnd, seg.segment.end)
            } else {
                // Speaker changed — emit accumulated segment
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

    private static func filterEchoLikeMicSegments(
        _ micSegments: [SpeechSegment],
        against systemSegments: [SpeechSegment]
    ) -> [SpeechSegment] {
        guard !micSegments.isEmpty, !systemSegments.isEmpty else { return micSegments }
        return micSegments.filter { !isEchoLikeMicSegment($0, against: systemSegments) }
    }

    private static func isEchoLikeMicSegment(
        _ micSegment: SpeechSegment,
        against systemSegments: [SpeechSegment]
    ) -> Bool {
        let micDuration = max(micSegment.end - micSegment.start, 0.1)
        let overlappingSystemSegments = systemSegments.filter {
            overlapDuration(between: micSegment, and: $0) >= min(0.15, micDuration * 0.5)
        }
        guard !overlappingSystemSegments.isEmpty else { return false }

        let normalizedMicText = normalizedText(micSegment.text)
        guard !normalizedMicText.isEmpty else { return false }

        let combinedSystemText = normalizedText(
            overlappingSystemSegments.map(\.text).joined(separator: " ")
        )
        guard !combinedSystemText.isEmpty else { return false }

        let overlapCoverage = overlappingSystemSegments.reduce(0.0) { partial, systemSegment in
            partial + overlapDuration(between: micSegment, and: systemSegment)
        } / micDuration

        let micTokens = tokenSet(from: normalizedMicText)
        let systemTokens = tokenSet(from: combinedSystemText)
        let tokenContainment = tokenContainmentRatio(source: micTokens, target: systemTokens)
        let isSubstringDuplicate =
            combinedSystemText.contains(normalizedMicText) || normalizedMicText.contains(combinedSystemText)

        if normalizedMicText.count <= 24 && isSubstringDuplicate && overlapCoverage >= 0.35 {
            return true
        }

        if micTokens.count <= 3 && tokenContainment >= 0.67 && overlapCoverage >= 0.35 {
            return true
        }

        if tokenContainment >= 0.8 && overlapCoverage >= 0.6 {
            return true
        }

        return false
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
        return "Others"
    }

    private static func overlapDuration(
        between lhs: SpeechSegment,
        and rhs: SpeechSegment
    ) -> TimeInterval {
        max(0, min(lhs.end, rhs.end) - max(lhs.start, rhs.start))
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
