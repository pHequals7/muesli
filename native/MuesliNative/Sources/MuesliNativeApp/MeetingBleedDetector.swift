import FluidAudio
import Foundation

enum MeetingBleedDetector {
    /// Maximum cosine distance for a mic chunk to be classified as bleed.
    /// Lower = more conservative (fewer false drops of user speech).
    /// 0.4 cosine distance ≈ 0.6 cosine similarity.
    static let bleedDistanceThreshold: Float = 0.4

    /// Minimum segment duration for reliable embedding extraction.
    static let minimumSegmentDuration: TimeInterval = 0.5

    struct Result {
        let keptSegments: [SpeechSegment]
        let droppedCount: Int
    }

    /// Compute per-speaker centroid embeddings from diarization segments.
    static func systemSpeakerCentroids(
        from diarizationSegments: [TimedSpeakerSegment]
    ) -> [[Float]] {
        var embeddingsBySpeaker: [String: [[Float]]] = [:]
        for seg in diarizationSegments {
            guard !seg.embedding.isEmpty else { continue }
            embeddingsBySpeaker[seg.speakerId, default: []].append(seg.embedding)
        }
        return embeddingsBySpeaker.values.compactMap { embeddings in
            averageEmbeddings(embeddings)
        }
    }

    /// Filter mic segments by comparing speaker embeddings against system speakers.
    /// Segments whose embedding is close to a system speaker are bleed — drop them.
    /// Segments that don't match any system speaker are user speech — keep them.
    static func filterBleed(
        micSegments: [SpeechSegment],
        fullMicSamples: [Float],
        systemSpeakerCentroids: [[Float]],
        diarizerManager: DiarizerManager
    ) -> Result {
        guard !systemSpeakerCentroids.isEmpty else {
            return Result(keptSegments: micSegments, droppedCount: 0)
        }

        let sampleRate = 16_000
        var kept: [SpeechSegment] = []
        var dropped = 0

        for segment in micSegments {
            let duration = segment.end - segment.start
            // Keep very short segments unconditionally — embedding unreliable
            guard duration >= minimumSegmentDuration else {
                kept.append(segment)
                continue
            }

            let startIdx = max(0, Int(segment.start * Double(sampleRate)))
            let endIdx = min(fullMicSamples.count, Int(segment.end * Double(sampleRate)))
            guard endIdx > startIdx else {
                kept.append(segment)
                continue
            }

            let segmentSamples = Array(fullMicSamples[startIdx..<endIdx])

            do {
                let embedding = try diarizerManager.extractSpeakerEmbedding(from: segmentSamples)

                // Find minimum cosine distance to any system speaker
                let minDistance = systemSpeakerCentroids.reduce(Float.infinity) { minSoFar, centroid in
                    min(minSoFar, SpeakerUtilities.cosineDistance(embedding, centroid))
                }

                if minDistance <= bleedDistanceThreshold {
                    // Mic embedding matches a system speaker — this is bleed
                    dropped += 1
                    fputs("[bleed-detect] dropped mic segment \(String(format: "%.1f", segment.start))-\(String(format: "%.1f", segment.end))s (distance=\(String(format: "%.3f", minDistance)) to system speaker)\n", stderr)
                } else {
                    kept.append(segment)
                }
            } catch {
                // Embedding extraction failed — keep the segment to be safe
                kept.append(segment)
            }
        }

        return Result(keptSegments: kept, droppedCount: dropped)
    }

    // MARK: - Helpers

    private static func averageEmbeddings(_ embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first else { return nil }
        let dim = first.count
        guard dim > 0 else { return nil }

        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            guard emb.count == dim else { continue }
            for i in 0..<dim {
                sum[i] += emb[i]
            }
        }
        let count = Float(embeddings.count)
        return sum.map { $0 / count }
    }
}
