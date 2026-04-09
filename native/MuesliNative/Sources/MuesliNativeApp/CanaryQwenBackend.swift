import Accelerate
@preconcurrency import CoreML
import FluidAudio
import Foundation

private enum CanaryQwenConfig {
    static let repoId = "phequals/canary-qwen-2.5b-coreml-int8"
    static let envOverride = "MUESLI_CANARY_MODEL_DIR"

    static let encoderPackage = "encoder_int8.mlpackage"
    static let projectionPackage = "projection.mlpackage"
    static let prefillPackage = "canary_prefill_static.mlpackage"
    static let decodePackage = "canary_decode_static.mlpackage"
    static let lmHeadPackage = "canary_lm_head_int8.mlpackage"
    static let embeddingsFile = "canary_embeddings.bin"
    static let vocabFile = "vocab.json"
    static let melFilterFile = "canary_mel_filter_bank.bin"
    static let melWindowFile = "canary_mel_window.bin"

    static let maxCacheLen = 256
    static let hiddenSize = 2048
    static let headDim = 128
    static let ropeTheta: Float = 1_000_000
    static let encoderFrames = 500
    static let chunkOverlapFrames = 80
    static let maxNewTokens = 50
    static let staticPrefillLen = 164

    static let promptText =
        "Transcribe the spoken audio accurately. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription."
    static let beforePromptIds: [Int32] = [
        151644, 872, 198, 3167, 3114, 279, 21355, 7699, 29257, 13, 1416, 264, 3409, 374,
        24416, 11, 990, 279, 1429, 4363, 3409, 429, 18304, 1632, 2878, 279, 2266, 315,
        279, 8084, 11652, 45840, 13,
    ]
    static let afterPromptIds: [Int32] = [151645, 198, 151644, 77091, 198]
    static let stopTokenIds: Set<Int> = [151645]
    static let staticAudioFrames = staticPrefillLen - beforePromptIds.count - afterPromptIds.count

    static let requiredModelPackages: [String] = [
        encoderPackage,
        projectionPackage,
        prefillPackage,
        decodePackage,
        lmHeadPackage,
    ]

    static let requiredRelativeFiles: [String] = [
        embeddingsFile,
        vocabFile,
        melFilterFile,
        melWindowFile,
    ]

    static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models", isDirectory: true)
            .appendingPathComponent("canary-qwen-2.5b-coreml-int8", isDirectory: true)
    }

    static var profilingLogURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("canary-profiling.log")
    }
}

enum CanaryProfilingLog {
    private static let fileURL = CanaryQwenConfig.profilingLogURL

    static func write(_ message: String) {
        fputs("\(message)\n", stderr)
        appendToFile(message + "\n")
    }

    private static func appendToFile(_ line: String) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            fputs("[canary-qwen][profile-log-error] \(error)\n", stderr)
        }
    }
}

private struct CanaryChunkSpan {
    let index: Int
    let startFrame: Int
    let endFrame: Int
    let durationS: Double
}

struct CanaryProfilingSummary: Sendable {
    var audioDurationS: Double
    var resampleMs: Double = 0
    var melMs: Double = 0
    var chunkScheduleMs: Double = 0
    var mergeMs: Double = 0
    var encoderMs: Double = 0
    var projectionMs: Double = 0
    var decoderPrefillMs: Double = 0
    var lmHeadPrefillMs: Double = 0
    var decoderDecodeMs: Double = 0
    var lmHeadDecodeMs: Double = 0
    var chunkCount: Int = 0
    var generatedTokenCount: Int = 0
    var transcriptCharacterCount: Int = 0
    var totalProcessingMs: Double = 0

    var prefillMs: Double {
        decoderPrefillMs + lmHeadPrefillMs
    }

    var decodeMs: Double {
        decoderDecodeMs + lmHeadDecodeMs
    }

    var inferenceMs: Double {
        melMs + chunkScheduleMs + mergeMs + encoderMs + projectionMs + prefillMs + decodeMs
    }

    var speedX: Double {
        guard totalProcessingMs > 0 else { return 0 }
        return audioDurationS / (totalProcessingMs / 1000.0)
    }

    func logDescription(prefix: String = "[canary-qwen]") -> String {
        "\(prefix) total=\(String(format: "%.3f", totalProcessingMs / 1000.0))s " +
            "audio=\(String(format: "%.3f", audioDurationS))s " +
            "speed=\(String(format: "%.2f", speedX))x " +
            "chunks=\(chunkCount) tokens=\(generatedTokenCount) chars=\(transcriptCharacterCount) " +
            "resample=\(String(format: "%.0f", resampleMs))ms " +
            "mel=\(String(format: "%.0f", melMs))ms " +
            "schedule=\(String(format: "%.0f", chunkScheduleMs))ms " +
            "encoder=\(String(format: "%.0f", encoderMs))ms " +
            "projection=\(String(format: "%.0f", projectionMs))ms " +
            "prefill=\(String(format: "%.0f", prefillMs))ms " +
            "decode=\(String(format: "%.0f", decodeMs))ms " +
            "merge=\(String(format: "%.0f", mergeMs))ms"
    }
}

private struct CanaryTimingBreakdown {
    var encoderMs: Double = 0
    var projectionMs: Double = 0
    var decoderPrefillMs: Double = 0
    var lmHeadPrefillMs: Double = 0
    var decoderDecodeMs: Double = 0
    var lmHeadDecodeMs: Double = 0

    var totalMs: Double {
        encoderMs + projectionMs + decoderPrefillMs + lmHeadPrefillMs + decoderDecodeMs + lmHeadDecodeMs
    }
}

private final class CanaryEmbeddingWeights: @unchecked Sendable {
    let vocabSize: Int
    let hiddenSize: Int
    private let data: Data

    init(contentsOf url: URL) throws {
        let fileData = try Data(contentsOf: url)
        guard fileData.count >= 8 else {
            throw NSError(domain: "CanaryQwen", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Invalid embedding file at \(url.path)",
            ])
        }
        let vocab = fileData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let hidden = fileData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        self.vocabSize = Int(vocab)
        self.hiddenSize = Int(hidden)
        guard hiddenSize == CanaryQwenConfig.hiddenSize else {
            throw NSError(domain: "CanaryQwen", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected embedding hidden size \(hiddenSize)",
            ])
        }
        let expectedBytes = 8 + vocabSize * hiddenSize * MemoryLayout<Float16>.stride
        guard fileData.count >= expectedBytes else {
            throw NSError(domain: "CanaryQwen", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Embedding file is truncated: expected at least \(expectedBytes) bytes, found \(fileData.count)",
            ])
        }
        self.data = fileData
    }

    func embedding(for tokenId: Int) -> [Float] {
        var result = [Float](repeating: 0, count: hiddenSize)
        result.withUnsafeMutableBufferPointer { destination in
            copyEmbedding(for: tokenId, to: destination.baseAddress!)
        }
        return result
    }

    func copyEmbedding(for tokenId: Int, to destination: UnsafeMutablePointer<Float>) {
        guard tokenId >= 0, tokenId < vocabSize else {
            destination.initialize(repeating: 0, count: hiddenSize)
            return
        }

        let offset = 8 + tokenId * hiddenSize * 2
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Float16.self)
            for i in 0..<hiddenSize {
                destination[i] = Float(ptr[i])
            }
        }
    }

    func flatEmbeddings(for tokenIds: [Int32]) -> [Float] {
        var result = [Float]()
        result.reserveCapacity(tokenIds.count * hiddenSize)
        for tokenId in tokenIds {
            result.append(contentsOf: embedding(for: Int(tokenId)))
        }
        return result
    }
}

private struct CanaryQwenRoPE: Sendable {
    private let invFreq: [Float]
    private let headDim: Int = CanaryQwenConfig.headDim
    private let maxPosition: Int = CanaryQwenConfig.maxCacheLen
    private let cosTable: [Float]
    private let sinTable: [Float]

    init() {
        let theta = CanaryQwenConfig.ropeTheta
        let dim = Float(headDim)
        var freq = [Float](repeating: 0, count: headDim / 2)
        for i in stride(from: 0, to: headDim, by: 2) {
            let exponent = Float(i) / dim
            freq[i / 2] = 1.0 / powf(theta, exponent)
        }
        self.invFreq = freq

        var cosVals = [Float](repeating: 0, count: maxPosition * headDim)
        var sinVals = [Float](repeating: 0, count: maxPosition * headDim)
        let halfDim = headDim / 2
        for p in 0..<maxPosition {
            let pos = Float(p)
            let offset = p * headDim
            for i in 0..<halfDim {
                let angle = pos * freq[i]
                let c = cosf(angle)
                let s = sinf(angle)
                cosVals[offset + i] = c
                cosVals[offset + i + halfDim] = c
                sinVals[offset + i] = s
                sinVals[offset + i + halfDim] = s
            }
        }
        self.cosTable = cosVals
        self.sinTable = sinVals
    }

    func computeRange(startPosition: Int, count: Int) -> (cos: [Float], sin: [Float]) {
        let endPosition = startPosition + count
        if endPosition <= maxPosition {
            let start = startPosition * headDim
            let end = endPosition * headDim
            return (Array(cosTable[start..<end]), Array(sinTable[start..<end]))
        }
        return computeDynamicRange(startPosition: startPosition, count: count)
    }

    func fill(position: Int, cosPtr: UnsafeMutablePointer<Float>, sinPtr: UnsafeMutablePointer<Float>) {
        if position < maxPosition {
            let offset = position * headDim
            cosTable.withUnsafeBufferPointer { src in
                _ = memcpy(cosPtr, src.baseAddress!.advanced(by: offset), headDim * MemoryLayout<Float>.stride)
            }
            sinTable.withUnsafeBufferPointer { src in
                _ = memcpy(sinPtr, src.baseAddress!.advanced(by: offset), headDim * MemoryLayout<Float>.stride)
            }
            return
        }
        let dynamic = computeDynamic(position: position)
        dynamic.cos.withUnsafeBufferPointer { src in
            _ = memcpy(cosPtr, src.baseAddress!, headDim * MemoryLayout<Float>.stride)
        }
        dynamic.sin.withUnsafeBufferPointer { src in
            _ = memcpy(sinPtr, src.baseAddress!, headDim * MemoryLayout<Float>.stride)
        }
    }

    private func computeDynamic(position: Int) -> (cos: [Float], sin: [Float]) {
        let halfDim = headDim / 2
        let pos = Float(position)
        var cosVals = [Float](repeating: 0, count: headDim)
        var sinVals = [Float](repeating: 0, count: headDim)
        for i in 0..<halfDim {
            let angle = pos * invFreq[i]
            let c = cosf(angle)
            let s = sinf(angle)
            cosVals[i] = c
            cosVals[i + halfDim] = c
            sinVals[i] = s
            sinVals[i + halfDim] = s
        }
        return (cosVals, sinVals)
    }

    private func computeDynamicRange(startPosition: Int, count: Int) -> (cos: [Float], sin: [Float]) {
        var cosVals = [Float](repeating: 0, count: count * headDim)
        var sinVals = [Float](repeating: 0, count: count * headDim)
        for index in 0..<count {
            let dynamic = computeDynamic(position: startPosition + index)
            let offset = index * headDim
            cosVals.replaceSubrange(offset..<(offset + headDim), with: dynamic.cos)
            sinVals.replaceSubrange(offset..<(offset + headDim), with: dynamic.sin)
        }
        return (cosVals, sinVals)
    }
}

private struct CanaryQwenModels {
    let encoder: MLModel
    let projection: MLModel
    let prefillDecoder: MLModel
    let decodeDecoder: MLModel
    let lmHead: MLModel
    let embeddings: CanaryEmbeddingWeights
    let vocabulary: [Int: String]
    let melExtractor: CanaryMelSpectrogram

    static func load(from directory: URL, computeUnits: MLComputeUnits = .all) async throws -> CanaryQwenModels {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let encoder = try await loadModel(packageName: CanaryQwenConfig.encoderPackage, from: directory, configuration: config)
        let projection = try await loadModel(packageName: CanaryQwenConfig.projectionPackage, from: directory, configuration: config)
        let prefillDecoder = try await loadModel(packageName: CanaryQwenConfig.prefillPackage, from: directory, configuration: config)
        let decodeDecoder = try await loadModel(packageName: CanaryQwenConfig.decodePackage, from: directory, configuration: config)
        let lmHead = try await loadModel(packageName: CanaryQwenConfig.lmHeadPackage, from: directory, configuration: config)

        let embeddings = try CanaryEmbeddingWeights(contentsOf: directory.appendingPathComponent(CanaryQwenConfig.embeddingsFile))
        let vocabulary = try loadVocabulary(from: directory.appendingPathComponent(CanaryQwenConfig.vocabFile))
        let melExtractor = try CanaryMelSpectrogram(
            filterBankURL: directory.appendingPathComponent(CanaryQwenConfig.melFilterFile),
            windowURL: directory.appendingPathComponent(CanaryQwenConfig.melWindowFile)
        )

        return CanaryQwenModels(
            encoder: encoder,
            projection: projection,
            prefillDecoder: prefillDecoder,
            decodeDecoder: decodeDecoder,
            lmHead: lmHead,
            embeddings: embeddings,
            vocabulary: vocabulary,
            melExtractor: melExtractor
        )
    }

    private static func loadModel(packageName: String, from directory: URL, configuration: MLModelConfiguration) async throws -> MLModel {
        let packageURL = directory.appendingPathComponent(packageName, isDirectory: true)
        let compiledURL = directory.appendingPathComponent(packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"), isDirectory: true)

        let modelURL: URL
        if FileManager.default.fileExists(atPath: compiledURL.path) {
            modelURL = compiledURL
        } else {
            let compiledTemp = try await MLModel.compileModel(at: packageURL)
            try? FileManager.default.removeItem(at: compiledURL)
            try FileManager.default.copyItem(at: compiledTemp, to: compiledURL)
            try? FileManager.default.removeItem(at: compiledTemp)
            modelURL = compiledURL
        }

        return try await MLModel.load(contentsOf: modelURL, configuration: configuration)
    }

    private static func loadVocabulary(from url: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: url)
        guard let tokenToId = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw NSError(domain: "CanaryQwen", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Invalid vocab file at \(url.path)",
            ])
        }
        var idToToken: [Int: String] = [:]
        idToToken.reserveCapacity(tokenToId.count)
        for (token, id) in tokenToId {
            idToToken[id] = token
        }
        return idToToken
    }
}

enum CanaryQwenModelStore {
    static func isAvailableLocally() -> Bool {
        if let overrideDir = localOverrideDirectory(), modelsExist(at: overrideDir) {
            return true
        }
        return modelsExist(at: cacheDirectory())
    }

    static func resolvedDirectory(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        if let overrideDir = localOverrideDirectory(), modelsExist(at: overrideDir) {
            progress?(1.0, "Using local Canary model override")
            return overrideDir
        }

        let target = CanaryQwenConfig.defaultCacheDirectory
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if modelsExist(at: target) {
            progress?(1.0, "Canary Qwen already downloaded")
            return target
        }
        try await downloadMissingFiles(to: target, progress: progress)
        return target
    }

    static func modelsExist(at directory: URL) -> Bool {
        let fm = FileManager.default
        let modelsPresent = CanaryQwenConfig.requiredModelPackages.allSatisfy { packageName in
            let packageURL = directory.appendingPathComponent(packageName, isDirectory: true)
            let compiledURL = directory.appendingPathComponent(
                packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"),
                isDirectory: true
            )
            let compiledData = compiledURL.appendingPathComponent("coremldata.bin")
            return fm.fileExists(atPath: packageURL.path) || fm.fileExists(atPath: compiledData.path)
        }
        guard modelsPresent else { return false }
        return CanaryQwenConfig.requiredRelativeFiles.allSatisfy { relativePath in
            fm.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
        }
    }

    static func localOverrideDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[CanaryQwenConfig.envOverride], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func cacheDirectory() -> URL {
        CanaryQwenConfig.defaultCacheDirectory
    }

    private static func remoteURL(for relativePath: String) -> URL {
        var url = URL(string: "https://huggingface.co/\(CanaryQwenConfig.repoId)/resolve/main")!
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "download", value: "1")]
        return components.url!
    }

    private static func downloadMissingFiles(to directory: URL, progress: ((Double, String?) -> Void)?) async throws {
        let fm = FileManager.default
        let modelPackageFiles = CanaryQwenConfig.requiredModelPackages.flatMap { packageName in
            [
                "\(packageName)/Manifest.json",
                "\(packageName)/Data/com.apple.CoreML/model.mlmodel",
                "\(packageName)/Data/com.apple.CoreML/weights/weight.bin",
            ]
        }
        let required = modelPackageFiles + CanaryQwenConfig.requiredRelativeFiles
        let missing = required.filter { relativePath in
            if let packageName = CanaryQwenConfig.requiredModelPackages.first(where: { relativePath.hasPrefix("\($0)/") }) {
                let compiledURL = directory.appendingPathComponent(
                    packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"),
                    isDirectory: true
                )
                let compiledData = compiledURL.appendingPathComponent("coremldata.bin")
                if fm.fileExists(atPath: compiledData.path) {
                    return false
                }
            }
            return !fm.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
        }
        let total = max(missing.count, 1)
        for (index, relativePath) in missing.enumerated() {
            progress?(Double(index) / Double(total), "Downloading Canary Qwen...")
            let destination = directory.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sourceURL = remoteURL(for: relativePath)
            try await downloadWithRetry(from: sourceURL, to: destination)
        }
        progress?(1.0, "Canary Qwen download complete")
    }
}

@available(macOS 15, *)
private final class CanaryQwenManager {
    private let models: CanaryQwenModels
    private let beforePromptEmbeds: [Float]
    private let afterPromptEmbeds: [Float]
    private let decodeUpdateMasks: [Int: MLMultiArray]
    private let decodeValidMasks: [Int: MLMultiArray]

    init(models: CanaryQwenModels) throws {
        self.models = models
        self.beforePromptEmbeds = models.embeddings.flatEmbeddings(for: CanaryQwenConfig.beforePromptIds)
        self.afterPromptEmbeds = models.embeddings.flatEmbeddings(for: CanaryQwenConfig.afterPromptIds)
        var updateMasks: [Int: MLMultiArray] = [:]
        var validMasks: [Int: MLMultiArray] = [:]
        for position in 0..<CanaryQwenConfig.maxCacheLen {
            updateMasks[position] = try Self.createDecodeUpdateMask(position: position)
            validMasks[position] = try Self.createDecodeValidMask(lastValidPosition: position)
        }
        self.decodeUpdateMasks = updateMasks
        self.decodeValidMasks = validMasks
    }

    func transcribe(audioSamples: [Float]) async throws -> (text: String, profile: CanaryProfilingSummary) {
        let start = CFAbsoluteTimeGetCurrent()
        let duration = Double(audioSamples.count) / 16_000.0
        var profile = CanaryProfilingSummary(audioDurationS: duration)

        let melStart = CFAbsoluteTimeGetCurrent()
        let mel = models.melExtractor.compute(audio: audioSamples)
        profile.melMs = (CFAbsoluteTimeGetCurrent() - melStart) * 1000

        let scheduleStart = CFAbsoluteTimeGetCurrent()
        let chunks = scheduleChunks(mel: mel)
        profile.chunkScheduleMs = (CFAbsoluteTimeGetCurrent() - scheduleStart) * 1000
        profile.chunkCount = chunks.count

        var transcripts: [String] = []
        var aggregate = CanaryTimingBreakdown()
        var generatedTokenCount = 0

        for chunk in chunks {
            let result = try transcribeChunk(span: chunk.0, melChunk: chunk.1)
            if !result.transcript.isEmpty {
                transcripts.append(result.transcript)
            }
            generatedTokenCount += result.generatedTokenCount
            aggregate.encoderMs += result.timing.encoderMs
            aggregate.projectionMs += result.timing.projectionMs
            aggregate.decoderPrefillMs += result.timing.decoderPrefillMs
            aggregate.lmHeadPrefillMs += result.timing.lmHeadPrefillMs
            aggregate.decoderDecodeMs += result.timing.decoderDecodeMs
            aggregate.lmHeadDecodeMs += result.timing.lmHeadDecodeMs
            CanaryProfilingLog.write(
                "[canary-qwen][chunk \(chunk.0.index)] frames=\(chunk.0.startFrame)-\(chunk.0.endFrame) duration=\(String(format: "%.2f", chunk.0.durationS))s tokens=\(result.generatedTokenCount) encoder=\(String(format: "%.0f", result.timing.encoderMs))ms projection=\(String(format: "%.0f", result.timing.projectionMs))ms prefill=\(String(format: "%.0f", result.timing.decoderPrefillMs + result.timing.lmHeadPrefillMs))ms decode=\(String(format: "%.0f", result.timing.decoderDecodeMs + result.timing.lmHeadDecodeMs))ms"
            )
        }

        let mergeStart = CFAbsoluteTimeGetCurrent()
        let merged = mergeChunkTranscripts(transcripts)
        profile.mergeMs = (CFAbsoluteTimeGetCurrent() - mergeStart) * 1000
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        profile.encoderMs = aggregate.encoderMs
        profile.projectionMs = aggregate.projectionMs
        profile.decoderPrefillMs = aggregate.decoderPrefillMs
        profile.lmHeadPrefillMs = aggregate.lmHeadPrefillMs
        profile.decoderDecodeMs = aggregate.decoderDecodeMs
        profile.lmHeadDecodeMs = aggregate.lmHeadDecodeMs
        profile.generatedTokenCount = generatedTokenCount
        profile.transcriptCharacterCount = merged.count
        profile.totalProcessingMs = elapsed * 1000
        CanaryProfilingLog.write(profile.logDescription())
        return (merged, profile)
    }

    private func transcribeChunk(span: CanaryChunkSpan, melChunk: [[Float]]) throws -> (transcript: String, timing: CanaryTimingBreakdown, generatedTokenCount: Int) {
        var timing = CanaryTimingBreakdown()
        let melInput = try createEncoderInput(melChunk)

        let encoderStart = CFAbsoluteTimeGetCurrent()
        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: melInput)
        ])
        let encoderOutput = try models.encoder.prediction(from: encoderInput)
        guard let encOut = encoderOutput.featureValue(for: "encoder_output")?.multiArrayValue else {
            throw NSError(domain: "CanaryQwen", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "Missing encoder_output from Canary encoder",
            ])
        }
        timing.encoderMs = (CFAbsoluteTimeGetCurrent() - encoderStart) * 1000

        let projectionStart = CFAbsoluteTimeGetCurrent()
        let projectionInput = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_output": MLFeatureValue(multiArray: encOut)
        ])
        let projectionOutput = try models.projection.prediction(from: projectionInput)
        guard let projected = projectionOutput.featureValue(for: "projected_output")?.multiArrayValue else {
            throw NSError(domain: "CanaryQwen", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "Missing projected_output from Canary projection",
            ])
        }
        timing.projectionMs = (CFAbsoluteTimeGetCurrent() - projectionStart) * 1000

        let audioFrames = projected.shape[1].intValue
        let maxNewTokens = tokenBudget(for: span.durationS)
        let (text, genTiming, generatedTokenCount) = try generate(projectedAudioEmbeds: projected, audioFrames: audioFrames, maxNewTokens: maxNewTokens)
        timing.decoderPrefillMs = genTiming.decoderPrefillMs
        timing.lmHeadPrefillMs = genTiming.lmHeadPrefillMs
        timing.decoderDecodeMs = genTiming.decoderDecodeMs
        timing.lmHeadDecodeMs = genTiming.lmHeadDecodeMs
        return (text, timing, generatedTokenCount)
    }

    private func generate(projectedAudioEmbeds: MLMultiArray, audioFrames: Int, maxNewTokens: Int) throws -> (String, CanaryTimingBreakdown, Int) {
        var timing = CanaryTimingBreakdown()

        let beforeCount = CanaryQwenConfig.beforePromptIds.count
        let afterCount = CanaryQwenConfig.afterPromptIds.count
        let staticAudioFrames = CanaryQwenConfig.staticAudioFrames
        let totalSeq = CanaryQwenConfig.staticPrefillLen
        guard audioFrames <= staticAudioFrames else {
            throw NSError(domain: "CanaryQwen", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Projected audio frames \(audioFrames) exceed static prefill budget \(staticAudioFrames)",
            ])
        }
        guard totalSeq <= CanaryQwenConfig.maxCacheLen else {
            throw NSError(domain: "CanaryQwen", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Static prefill length \(totalSeq) exceeds cache limit \(CanaryQwenConfig.maxCacheLen)",
            ])
        }
        let hiddenSize = CanaryQwenConfig.hiddenSize

        let hiddenArray = try MLMultiArray(shape: [1, NSNumber(value: totalSeq), NSNumber(value: hiddenSize)], dataType: .float32)
        let hiddenPtr = hiddenArray.dataPointer.bindMemory(to: Float.self, capacity: totalSeq * hiddenSize)
        hiddenPtr.initialize(repeating: 0, count: totalSeq * hiddenSize)

        beforePromptEmbeds.withUnsafeBufferPointer { src in
            _ = memcpy(hiddenPtr, src.baseAddress!, beforePromptEmbeds.count * MemoryLayout<Float>.stride)
        }
        copyProjectedAudioEmbeds(projectedAudioEmbeds, to: hiddenPtr.advanced(by: beforePromptEmbeds.count))
        afterPromptEmbeds.withUnsafeBufferPointer { src in
            _ = memcpy(
                hiddenPtr.advanced(by: beforePromptEmbeds.count + (staticAudioFrames * hiddenSize)),
                src.baseAddress!,
                afterPromptEmbeds.count * MemoryLayout<Float>.stride
            )
        }

        let state = models.prefillDecoder.makeState()
        let prefillInput = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": MLFeatureValue(multiArray: hiddenArray),
        ])

        let prefillStart = CFAbsoluteTimeGetCurrent()
        let decoderOutput = try models.prefillDecoder.prediction(from: prefillInput, using: state)
        guard let prefillHidden = decoderOutput.featureValue(for: "output_hidden")?.multiArrayValue else {
            throw NSError(domain: "CanaryQwen", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "Missing output_hidden from Canary prefill decoder",
            ])
        }
        timing.decoderPrefillMs = (CFAbsoluteTimeGetCurrent() - prefillStart) * 1000

        let lastHidden = try sliceLastHidden(prefillHidden, seqLen: totalSeq)
        let lmPrefillStart = CFAbsoluteTimeGetCurrent()
        let lmPrefillInput = try MLDictionaryFeatureProvider(dictionary: [
            "hidden_states": MLFeatureValue(multiArray: lastHidden)
        ])
        let lmPrefillOutput = try models.lmHead.prediction(from: lmPrefillInput)
        guard let prefillLogits = lmPrefillOutput.featureValue(for: "logits")?.multiArrayValue else {
            throw NSError(domain: "CanaryQwen", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "Missing logits from Canary lm head",
            ])
        }
        timing.lmHeadPrefillMs = (CFAbsoluteTimeGetCurrent() - lmPrefillStart) * 1000

        var nextToken = argmax(logits: prefillLogits)
        var generatedIds: [Int] = []
        var currentPosition = totalSeq

        let decodeHidden = try MLMultiArray(shape: [1, 1, NSNumber(value: hiddenSize)], dataType: .float32)
        let decodeHiddenPtr = decodeHidden.dataPointer.bindMemory(to: Float.self, capacity: hiddenSize)

        for _ in 0..<maxNewTokens {
            if CanaryQwenConfig.stopTokenIds.contains(nextToken) { break }
            generatedIds.append(nextToken)

            guard currentPosition < CanaryQwenConfig.maxCacheLen else { break }
            models.embeddings.copyEmbedding(for: nextToken, to: decodeHiddenPtr)
            guard
                let decodeUpdateMask = decodeUpdateMasks[currentPosition],
                let decodeValidMask = decodeValidMasks[currentPosition]
            else {
                break
            }

            // autoreleasepool prevents CoreML GPU/ANE buffer accumulation in long decode loops
            try autoreleasepool {
                let decodeInput = try MLDictionaryFeatureProvider(dictionary: [
                    "hidden_states": MLFeatureValue(multiArray: decodeHidden),
                    "cache_update_mask": MLFeatureValue(multiArray: decodeUpdateMask),
                    "cache_valid_mask": MLFeatureValue(multiArray: decodeValidMask),
                ])

                let decodeStart = CFAbsoluteTimeGetCurrent()
                let decodeOutput = try models.decodeDecoder.prediction(from: decodeInput, using: state)
                guard let decodeHiddenOut = decodeOutput.featureValue(for: "output_hidden")?.multiArrayValue else {
                    throw NSError(domain: "CanaryQwen", code: 18, userInfo: [
                        NSLocalizedDescriptionKey: "Missing decode output_hidden from Canary decode model",
                    ])
                }
                timing.decoderDecodeMs += (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000

                let lmStart = CFAbsoluteTimeGetCurrent()
                let lmInput = try MLDictionaryFeatureProvider(dictionary: [
                    "hidden_states": MLFeatureValue(multiArray: decodeHiddenOut)
                ])
                let lmOutput = try models.lmHead.prediction(from: lmInput)
                guard let logits = lmOutput.featureValue(for: "logits")?.multiArrayValue else {
                    throw NSError(domain: "CanaryQwen", code: 19, userInfo: [
                        NSLocalizedDescriptionKey: "Missing decode logits from Canary lm head",
                    ])
                }
                timing.lmHeadDecodeMs += (CFAbsoluteTimeGetCurrent() - lmStart) * 1000

                nextToken = argmax(logits: logits)
            }
            currentPosition += 1
        }

        return (decodeTokens(generatedIds), timing, generatedIds.count)
    }

    private func tokenBudget(for chunkSeconds: Double) -> Int {
        let estimate = Int(ceil(chunkSeconds * 6.0)) + 8
        return min(CanaryQwenConfig.maxNewTokens, max(8, estimate))
    }

    private func scheduleChunks(mel: [[Float]]) -> [(CanaryChunkSpan, [[Float]])] {
        guard let totalFrames = mel.first?.count else { return [] }
        if totalFrames <= CanaryQwenConfig.encoderFrames {
            let span = CanaryChunkSpan(index: 0, startFrame: 0, endFrame: totalFrames, durationS: Double(totalFrames) * 0.01)
            return [(span, mel)]
        }

        let stride = CanaryQwenConfig.encoderFrames - CanaryQwenConfig.chunkOverlapFrames
        let lastFullStart = max(totalFrames - CanaryQwenConfig.encoderFrames, 0)
        var starts: [Int] = []
        var start = 0
        while true {
            starts.append(start)
            let nextStart = start + stride
            if nextStart + CanaryQwenConfig.encoderFrames >= totalFrames {
                if lastFullStart > starts.last! {
                    starts.append(lastFullStart)
                }
                break
            }
            start = nextStart
        }

        var scheduled: [(CanaryChunkSpan, [[Float]])] = []
        for (index, chunkStart) in starts.enumerated() {
            let end = min(chunkStart + CanaryQwenConfig.encoderFrames, totalFrames)
            let span = CanaryChunkSpan(index: index, startFrame: chunkStart, endFrame: end, durationS: Double(end - chunkStart) * 0.01)
            let chunk = mel.map { Array($0[chunkStart..<end]) }
            scheduled.append((span, chunk))
        }
        return scheduled
    }

    private func mergeChunkTranscripts(_ texts: [String]) -> String {
        var mergedWords: [String] = []
        for text in texts {
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.isEmpty { continue }
            if mergedWords.isEmpty {
                mergedWords.append(contentsOf: words)
                continue
            }

            let lowerExisting = mergedWords.map(normalizeMergeToken)
            let lowerNew = words.map(normalizeMergeToken)
            let maxOverlap = min(lowerExisting.count, lowerNew.count, 12)
            var overlap = 0
            if maxOverlap > 0 {
                for k in stride(from: maxOverlap, through: 1, by: -1) {
                    if Array(lowerExisting.suffix(k)) == Array(lowerNew.prefix(k)) {
                        overlap = k
                        break
                    }
                }
            }
            if overlap > 0 && overlap < words.count && !mergedWords.isEmpty {
                mergedWords[mergedWords.count - 1] = mergedWords.last!.replacingOccurrences(of: #"[,.!?;:]+$"#, with: "", options: .regularExpression)
            }
            mergedWords.append(contentsOf: words.dropFirst(overlap))
        }
        return mergedWords.joined(separator: " ")
    }

    private func normalizeMergeToken(_ token: String) -> String {
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let scalars = token.unicodeScalars.filter { !punctuation.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    private func decodeTokens(_ tokenIds: [Int]) -> String {
        var pieces: [String] = []
        pieces.reserveCapacity(tokenIds.count)
        for tokenId in tokenIds {
            if let piece = models.vocabulary[tokenId] {
                pieces.append(piece)
            }
        }
        let raw = pieces.joined()
        let bytes = raw.unicodeScalars.compactMap { scalar -> UInt8? in
            Self.bpeUnicodeToByte[scalar.value]
        }
        let decoded = String(bytes: bytes, encoding: .utf8) ?? String(raw.filter(\.isASCII))
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let bpeUnicodeToByte: [UInt32: UInt8] = {
        var printable = [Int]()
        printable.append(contentsOf: 33...126)
        printable.append(contentsOf: 161...172)
        printable.append(contentsOf: 174...255)
        let printableSet = Set(printable)

        var mapping: [UInt32: UInt8] = [:]
        for value in printable {
            mapping[UInt32(value)] = UInt8(value)
        }
        var extra: UInt32 = 256
        for value in 0...255 where !printableSet.contains(value) {
            mapping[extra] = UInt8(value)
            extra += 1
        }
        return mapping
    }()

    private func argmax(logits: MLMultiArray) -> Int {
        if let ptr = contiguousFloatPointer(for: logits) {
            var maxValue: Float = -.infinity
            var maxIndex: vDSP_Length = 0
            vDSP_maxvi(ptr, 1, &maxValue, &maxIndex, vDSP_Length(logits.count))
            return Int(maxIndex)
        }

        let count = logits.count
        var maxValue = -Float.infinity
        var maxIndex = 0
        for idx in 0..<count {
            let value = logits[idx].floatValue
            if value > maxValue {
                maxValue = value
                maxIndex = idx
            }
        }
        return maxIndex
    }

    private func copyProjectedAudioEmbeds(_ source: MLMultiArray, to destination: UnsafeMutablePointer<Float>) {
        if let src = contiguousFloatPointer(for: source) {
            _ = memcpy(destination, src, source.count * MemoryLayout<Float>.stride)
            return
        }

        let count = source.count
        for idx in 0..<count {
            destination[idx] = source[idx].floatValue
        }
    }

    private func createEncoderInput(_ melChunk: [[Float]]) throws -> MLMultiArray {
        let paddedFrames = CanaryQwenConfig.encoderFrames
        let array = try MLMultiArray(shape: [1, 128, NSNumber(value: paddedFrames)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 128 * paddedFrames)
        ptr.initialize(repeating: 0, count: 128 * paddedFrames)
        for melBin in 0..<128 {
            let row = melChunk[melBin]
            let count = min(row.count, paddedFrames)
            row.withUnsafeBufferPointer { src in
                _ = memcpy(
                    ptr.advanced(by: melBin * paddedFrames),
                    src.baseAddress!,
                    count * MemoryLayout<Float>.stride
                )
            }
        }
        return array
    }

    private static func createDecodeUpdateMask(position: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: CanaryQwenConfig.maxCacheLen)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: CanaryQwenConfig.maxCacheLen)
        ptr.initialize(repeating: 0, count: CanaryQwenConfig.maxCacheLen)
        ptr[position] = 1
        return array
    }

    private static func createDecodeValidMask(lastValidPosition: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: CanaryQwenConfig.maxCacheLen)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: CanaryQwenConfig.maxCacheLen)
        ptr.initialize(repeating: 0, count: CanaryQwenConfig.maxCacheLen)
        for index in 0...lastValidPosition {
            ptr[index] = 1
        }
        return array
    }

    private func sliceLastHidden(_ hidden: MLMultiArray, seqLen: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: CanaryQwenConfig.hiddenSize)], dataType: .float32)
        let dst = array.dataPointer.bindMemory(to: Float.self, capacity: CanaryQwenConfig.hiddenSize)
        let offset = (seqLen - 1) * CanaryQwenConfig.hiddenSize
        if let src = contiguousFloatPointer(for: hidden) {
            _ = memcpy(
                dst,
                src.advanced(by: offset),
                CanaryQwenConfig.hiddenSize * MemoryLayout<Float>.stride
            )
            return array
        }

        for i in 0..<CanaryQwenConfig.hiddenSize {
            dst[i] = hidden[offset + i].floatValue
        }
        return array
    }

    private func contiguousFloatPointer(for array: MLMultiArray) -> UnsafePointer<Float>? {
        guard array.dataType == .float32, Self.isCContiguous(array) else {
            return nil
        }
        return UnsafePointer(array.dataPointer.bindMemory(to: Float.self, capacity: array.count))
    }

    private static func isCContiguous(_ array: MLMultiArray) -> Bool {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count == strides.count else { return false }

        var expectedStride = 1
        for index in shape.indices.reversed() {
            let dimension = shape[index]
            let stride = strides[index]
            if dimension > 1 && stride != expectedStride {
                return false
            }
            expectedStride *= max(dimension, 1)
        }
        return true
    }
}

/// Native Swift transcription backend using the split Canary CoreML model stack.
/// Uses Swift-side embedding lookup and a stateful decoder. Requires macOS 15+ for MLState support.
@available(macOS 15, *)
actor CanaryQwenTranscriber {
    private var manager: CanaryQwenManager?
    private var loadTask: Task<CanaryQwenManager, Error>?
    private var warmupTask: Task<Void, Never>?
    private var hasCompletedWarmup = false

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Canary Qwen models not loaded. Call loadModels() first."
            }
        }
    }

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if manager != nil { return }
        if let loadTask {
            self.manager = try await loadTask.value
            return
        }

        let task = Task<CanaryQwenManager, Error> {
            CanaryProfilingLog.write("[canary-qwen] downloading/loading models...")
            let modelDir = try await CanaryQwenModelStore.resolvedDirectory(progress: progress)
            let models = try await CanaryQwenModels.load(from: modelDir)
            let loadedManager = try CanaryQwenManager(models: models)
            CanaryProfilingLog.write("[canary-qwen] models loaded, ready")
            return loadedManager
        }

        self.loadTask = task
        do {
            let loadedManager = try await task.value
            self.manager = loadedManager
            self.loadTask = nil
        } catch {
            self.loadTask = nil
            throw error
        }
    }

    func prepare(progress: ((Double, String?) -> Void)? = nil) async throws {
        try await loadModels(progress: progress)
        scheduleWarmupIfNeeded()
    }

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double, profile: CanaryProfilingSummary) {
        try await loadModels()
        if let warmupTask {
            CanaryProfilingLog.write("[canary-qwen] waiting for background warmup to finish before dictation...")
            await warmupTask.value
        }
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let converter = AudioConverter()
        let resampleStart = CFAbsoluteTimeGetCurrent()
        let samples = try converter.resampleAudioFile(wavURL)
        let resampleMs = (CFAbsoluteTimeGetCurrent() - resampleStart) * 1000
        let inference = try await manager.transcribe(audioSamples: samples)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        var profile = inference.profile
        profile.resampleMs = resampleMs
        profile.totalProcessingMs = processingTime * 1000
        CanaryProfilingLog.write(profile.logDescription(prefix: "[canary-qwen][dictation]"))
        return (inference.text, processingTime, profile)
    }

    func shutdown() {
        manager = nil
        warmupTask?.cancel()
        warmupTask = nil
        hasCompletedWarmup = false
    }

    private func scheduleWarmupIfNeeded() {
        guard !hasCompletedWarmup, warmupTask == nil, manager != nil else { return }
        warmupTask = Task { await self.runWarmup() }
    }

    private func runWarmup() async {
        guard let manager else {
            warmupTask = nil
            return
        }

        CanaryProfilingLog.write("[canary-qwen] background warmup started")
        let warmupSamples = [Float](repeating: 0, count: 16_000)
        do {
            let result = try await manager.transcribe(audioSamples: warmupSamples)
            hasCompletedWarmup = true
            CanaryProfilingLog.write(
                result.profile.logDescription(prefix: "[canary-qwen][warmup]")
            )
            CanaryProfilingLog.write("[canary-qwen] background warmup complete")
        } catch {
            CanaryProfilingLog.write("[canary-qwen] background warmup failed: \(error)")
        }
        warmupTask = nil
    }
}
