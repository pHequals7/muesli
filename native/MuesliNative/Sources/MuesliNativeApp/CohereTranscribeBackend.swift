import Accelerate
@preconcurrency import CoreML
import FluidAudio
import Foundation

// MARK: - Configuration

private enum CohereTranscribeConfig {
    static let repoId = "phequals/cohere-transcribe-coreml-int8"
    static let envOverride = "MUESLI_COHERE_MODEL_DIR"
    static let int8EncoderComputeUnitsOverrideEnv = "MUESLI_COHERE_INT8_ENCODER_COMPUTE_UNITS"
    static let int8EncoderUseCompiledOverrideEnv = "MUESLI_COHERE_INT8_ENCODER_USE_COMPILED"

    static let encoderPackage = "cohere_encoder_int8.mlpackage"
    static let dynamicEncoderPackage = "cohere_encoder_dynamic.mlpackage"
    static let prefillPackage = "cohere_decoder_prefill_int8.mlpackage"
    static let decodePackage = "cohere_decoder_decode_int8.mlpackage"
    static let tokenizerFile = "tokenizer.model"
    static let melFilterFile = "cohere_mel_filterbank.bin"
    static let melWindowFile = "cohere_mel_window.bin"

    static let melLength = 3500
    static let encLen = 438
    static let prefillLen = 10
    static let maxSeqLen = 512
    static let vocabSize = 16384
    static let eosTokenId = 3 // <|endoftext|>
    static let promptIds: [Int32] = [13764, 7, 4, 16, 62, 62, 5, 9, 11, 13]

    // Mel spectrogram parameters
    static let sampleRate = 16_000
    static let nFFT = 512
    static let hopLength = 160
    static let nMels = 128
    static let winLength = 400 // 0.025 * 16000

    // Audio chunking
    static let maxAudioSamples = 35 * 16_000
    static let chunkOverlapSamples = 5 * 16_000

    static let requiredModelPackages = [encoderPackage, prefillPackage, decodePackage]
    static let requiredRelativeFiles = [tokenizerFile, melFilterFile, melWindowFile]

    static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models", isDirectory: true)
            .appendingPathComponent("cohere-transcribe-coreml-int8", isDirectory: true)
    }

    static var profilingLogURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("cohere-profiling.log")
    }
}

// MARK: - Profiling

private enum CohereProfilingLog {
    private static let fileURL = CohereTranscribeConfig.profilingLogURL

    static func write(_ message: String) {
        fputs("\(message)\n", stderr)
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = "\(message)\n".data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        } catch {
            fputs("[cohere][profile-log-error] \(error)\n", stderr)
        }
    }
}

private func cohereComputeUnitsDescription(_ units: MLComputeUnits) -> String {
    switch units {
    case .cpuOnly:
        return "cpuOnly"
    case .cpuAndGPU:
        return "cpuAndGPU"
    case .cpuAndNeuralEngine:
        return "cpuAndNeuralEngine"
    case .all:
        return "all"
    @unknown default:
        return "unknown"
    }
}

private func cohereComputeUnits(from rawValue: String) -> MLComputeUnits? {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "cpuonly", "cpu":
        return .cpuOnly
    case "cpuandgpu", "gpu":
        return .cpuAndGPU
    case "cpuandneuralengine", "neuralengine", "ane":
        return .cpuAndNeuralEngine
    case "all":
        return .all
    default:
        return nil
    }
}

private func cohereBool(from rawValue: String) -> Bool? {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "y", "on":
        return true
    case "0", "false", "no", "n", "off":
        return false
    default:
        return nil
    }
}

struct CohereProfilingSummary: Sendable {
    var audioDurationS: Double
    var resampleMs: Double = 0
    var melMs: Double = 0
    var chunkScheduleMs: Double = 0
    var mergeMs: Double = 0
    var encoderMs: Double = 0
    var prefillMs: Double = 0
    var decodeMs: Double = 0
    var chunkCount: Int = 0
    var generatedTokenCount: Int = 0
    var transcriptCharacterCount: Int = 0
    var totalProcessingMs: Double = 0

    var inferenceMs: Double {
        melMs + chunkScheduleMs + mergeMs + encoderMs + prefillMs + decodeMs
    }

    var speedX: Double {
        guard totalProcessingMs > 0 else { return 0 }
        return audioDurationS / (totalProcessingMs / 1000.0)
    }

    func logDescription(prefix: String = "[cohere]") -> String {
        "\(prefix) total=\(String(format: "%.3f", totalProcessingMs / 1000.0))s " +
            "audio=\(String(format: "%.3f", audioDurationS))s " +
            "speed=\(String(format: "%.2f", speedX))x " +
            "chunks=\(chunkCount) tokens=\(generatedTokenCount) chars=\(transcriptCharacterCount) " +
            "resample=\(String(format: "%.0f", resampleMs))ms " +
            "mel=\(String(format: "%.0f", melMs))ms " +
            "encoder=\(String(format: "%.0f", encoderMs))ms " +
            "prefill=\(String(format: "%.0f", prefillMs))ms " +
            "decode=\(String(format: "%.0f", decodeMs))ms " +
            "merge=\(String(format: "%.0f", mergeMs))ms"
    }
}

private struct CohereTimingBreakdown {
    var encoderMs: Double = 0
    var prefillMs: Double = 0
    var decodeMs: Double = 0

    var totalMs: Double { encoderMs + prefillMs + decodeMs }
}

// MARK: - Mel Spectrogram
//
// Matches Cohere's NeMo-style FilterbankFeatures exactly:
//   - Pre-emphasis (0.97)
//   - torch.stft with center=True, pad_mode="constant" (zero-pad, not reflect)
//   - Slaney-normalized mel filterbank (librosa.filters.mel norm='slaney')
//   - log(x + 2^-24) guard
//   - Per-feature normalization with Bessel-corrected std (/ (N-1)) + dither in std

private final class CohereMelSpectrogram {
    private let filterBank: [Float] // flat [nMels * nBins], loaded from librosa Slaney binary
    private let window: [Float]     // Hann window [winLength], loaded from torch-style binary
    private let nMels: Int
    private let nBins: Int
    private let nFFT: Int
    private let hop: Int
    private let winLength: Int
    private let fftSetup: FFTSetup
    private static let preemph: Float = 0.97
    private static let logZeroGuard: Float = 5.960464477539063e-08 // 2^-24
    private static let ditherConstant: Float = 1e-05

    init(directory: URL) throws {
        let nMels = CohereTranscribeConfig.nMels
        let nFFT = CohereTranscribeConfig.nFFT
        let winLength = CohereTranscribeConfig.winLength
        let hop = CohereTranscribeConfig.hopLength
        let nBins = nFFT / 2 + 1

        self.nMels = nMels
        self.nBins = nBins
        self.nFFT = nFFT
        self.hop = hop
        self.winLength = winLength

        // Load pre-computed librosa Slaney mel filterbank [128 x 257] float32
        let fbURL = directory.appendingPathComponent(CohereTranscribeConfig.melFilterFile)
        let fbData = try Data(contentsOf: fbURL)
        let expectedFBBytes = nMels * nBins * MemoryLayout<Float>.stride
        guard fbData.count >= expectedFBBytes else {
            throw NSError(domain: "CohereTranscribe", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Mel filterbank file too small: \(fbData.count) < \(expectedFBBytes)",
            ])
        }
        self.filterBank = fbData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(nMels * nBins))
        }

        // Load pre-computed torch hann_window(periodic=False) [400] float32
        let winURL = directory.appendingPathComponent(CohereTranscribeConfig.melWindowFile)
        let winData = try Data(contentsOf: winURL)
        let expectedWinBytes = winLength * MemoryLayout<Float>.stride
        guard winData.count >= expectedWinBytes else {
            throw NSError(domain: "CohereTranscribe", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Mel window file too small: \(winData.count) < \(expectedWinBytes)",
            ])
        }
        self.window = winData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(winLength))
        }

        let log2n = vDSP_Length(log2(Double(nFFT)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "CohereTranscribe", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create FFT setup for nFFT=\(nFFT)",
            ])
        }
        self.fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Compute log-mel spectrogram from raw 16kHz audio.
    /// Returns `(mel: [nMels][melLength], realFrameCount: Int)` — normalized over real frames,
    /// zero-padded to `melLength` (3500). `realFrameCount` is capped at `melLength`.
    func compute(audio: [Float]) -> (mel: [[Float]], realFrameCount: Int) {
        let count = audio.count
        let melLength = CohereTranscribeConfig.melLength

        // 1. Pre-emphasis: x[n] = x[n] - 0.97 * x[n-1]
        var preemph = [Float](repeating: 0, count: count)
        preemph[0] = audio[0]
        for i in 1..<count {
            preemph[i] = audio[i] - Self.preemph * audio[i - 1]
        }

        // 2. Center=True, pad_mode="constant" (zero-pad both sides by nFFT/2)
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: pad + count + pad)
        for i in 0..<count {
            padded[pad + i] = preemph[i]
        }
        // Left and right pads are already zero from initialization

        let nRealFrames = min(1 + (padded.count - nFFT) / hop, melLength)

        // 3. STFT → magnitude → power (mag_power=2.0)
        // magnitude = sqrt(re^2 + im^2), power = magnitude^2 = re^2 + im^2
        var powerSpec = [Float](repeating: 0, count: nRealFrames * nBins)
        var frame = [Float](repeating: 0, count: nFFT)

        for f in 0..<nRealFrames {
            let start = f * hop
            // Window the frame (window is winLength, zero-pad to nFFT)
            for i in 0..<nFFT {
                frame[i] = i < winLength ? padded[start + i] * window[i] : 0
            }
            let (re, im) = performRealFFT(frame)
            for b in 0..<nBins {
                powerSpec[f * nBins + b] = re[b] * re[b] + im[b] * im[b]
            }
        }

        // 4. Apply Slaney mel filterbank: mel = fb @ power_spec
        // fb is [nMels, nBins], powerSpec is [nRealFrames, nBins]
        // Result is [nMels, melLength] — only nRealFrames filled, rest zero
        var melSpec = [[Float]](repeating: [Float](repeating: 0, count: melLength), count: nMels)
        for m in 0..<nMels {
            let fbRow = m * nBins
            for f in 0..<nRealFrames {
                var sum: Float = 0
                let psRow = f * nBins
                for b in 0..<nBins {
                    sum += filterBank[fbRow + b] * powerSpec[psRow + b]
                }
                // 5. log(x + 2^-24) guard
                melSpec[m][f] = logf(sum + Self.logZeroGuard)
            }
        }

        // 6. Per-feature normalization using ONLY real frames (Bessel-corrected std)
        //    Then zero-mask all frames beyond nRealFrames (matching Cohere's pad_value=0.0)
        for m in 0..<nMels {
            var sum: Float = 0
            for f in 0..<nRealFrames {
                sum += melSpec[m][f]
            }
            let mean = sum / Float(nRealFrames)

            var sumSqDiff: Float = 0
            for f in 0..<nRealFrames {
                let diff = melSpec[m][f] - mean
                sumSqDiff += diff * diff
            }
            // Bessel correction: divide by (N-1), then add dither constant to prevent div-by-zero
            let std = sqrtf(sumSqDiff / Float(max(nRealFrames - 1, 1))) + Self.ditherConstant
            for f in 0..<nRealFrames {
                melSpec[m][f] = (melSpec[m][f] - mean) / std
            }
            // Frames beyond nRealFrames are already zero from initialization
        }

        return (melSpec, nRealFrames)
    }

    private func performRealFFT(_ input: [Float]) -> ([Float], [Float]) {
        let n = input.count
        let log2n = vDSP_Length(log2(Double(n)))
        let halfN = n / 2
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)

        input.withUnsafeBufferPointer { inputPtr in
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(
                        realp: realPtr.baseAddress!,
                        imagp: imagPtr.baseAddress!
                    )
                    inputPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
        }

        // Unpack: bin 0 real = realPart[0], bin N/2 real = imagPart[0]
        let nBins = halfN + 1
        var re = [Float](repeating: 0, count: nBins)
        var im = [Float](repeating: 0, count: nBins)
        re[0] = realPart[0]
        im[0] = 0
        re[halfN] = imagPart[0]
        im[halfN] = 0
        for i in 1..<halfN {
            re[i] = realPart[i]
            im[i] = imagPart[i]
        }
        return (re, im)
    }

    private func naiveDFT(_ input: [Float]) -> ([Float], [Float]) {
        let n = input.count
        let nBins = n / 2 + 1
        var re = [Float](repeating: 0, count: nBins)
        var im = [Float](repeating: 0, count: nBins)
        for k in 0..<nBins {
            var sumRe: Float = 0
            var sumIm: Float = 0
            for t in 0..<n {
                let angle = -2.0 * Float.pi * Float(k) * Float(t) / Float(n)
                sumRe += input[t] * cosf(angle)
                sumIm += input[t] * sinf(angle)
            }
            re[k] = sumRe
            im[k] = sumIm
        }
        return (re, im)
    }
}

// MARK: - SentencePiece Tokenizer

private final class CohereSentencePieceDecoder {
    private let vocabulary: [Int: String]

    init(modelURL: URL) throws {
        let data = try Data(contentsOf: modelURL)
        self.vocabulary = try Self.parseVocabulary(from: data)
    }

    func decode(tokenIds: [Int]) -> String {
        let pieces = tokenIds.compactMap { vocabulary[$0] }
        let raw = pieces.joined()
        return raw.replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Minimal protobuf parser for SentencePiece ModelProto.
    /// The .model file is: ModelProto { repeated SentencePiece pieces = 1; ... }
    /// Each SentencePiece has: string piece = 1; float score = 2; Type type = 3;
    private static func parseVocabulary(from data: Data) throws -> [Int: String] {
        var vocab: [Int: String] = [:]
        var index = 0
        var tokenId = 0

        while index < data.count {
            // Read field tag
            let (tag, newIndex) = readVarint(data: data, offset: index)
            index = newIndex
            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            if fieldNumber == 1 && wireType == 2 {
                // Length-delimited: this is a SentencePiece message
                let (msgLen, msgStart) = readVarint(data: data, offset: index)
                index = msgStart
                let msgEnd = index + Int(msgLen)

                // Parse the inner SentencePiece message to extract field 1 (piece string)
                var innerIndex = index
                var piece: String?
                while innerIndex < msgEnd {
                    let (innerTag, innerNew) = readVarint(data: data, offset: innerIndex)
                    innerIndex = innerNew
                    let innerField = innerTag >> 3
                    let innerWire = innerTag & 0x07

                    if innerField == 1 && innerWire == 2 {
                        // string piece
                        let (strLen, strStart) = readVarint(data: data, offset: innerIndex)
                        innerIndex = strStart
                        let strEnd = innerIndex + Int(strLen)
                        if strEnd <= data.count {
                            piece = String(data: data[innerIndex..<strEnd], encoding: .utf8)
                        }
                        innerIndex = strEnd
                    } else if innerWire == 0 {
                        // varint — skip
                        let (_, next) = readVarint(data: data, offset: innerIndex)
                        innerIndex = next
                    } else if innerWire == 2 {
                        // length-delimited — skip
                        let (skipLen, skipStart) = readVarint(data: data, offset: innerIndex)
                        innerIndex = skipStart + Int(skipLen)
                    } else if innerWire == 5 {
                        // 32-bit fixed (float score) — skip 4 bytes
                        innerIndex += 4
                    } else if innerWire == 1 {
                        // 64-bit fixed — skip 8 bytes
                        innerIndex += 8
                    } else {
                        break
                    }
                }

                if let piece {
                    vocab[tokenId] = piece
                }
                tokenId += 1
                index = msgEnd
            } else if wireType == 0 {
                let (_, next) = readVarint(data: data, offset: index)
                index = next
            } else if wireType == 2 {
                let (skipLen, skipStart) = readVarint(data: data, offset: index)
                index = skipStart + Int(skipLen)
            } else if wireType == 5 {
                index += 4
            } else if wireType == 1 {
                index += 8
            } else {
                break
            }
        }

        guard !vocab.isEmpty else {
            throw NSError(domain: "CohereTranscribe", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Failed to parse SentencePiece vocabulary",
            ])
        }
        return vocab
    }

    private static func readVarint(data: Data, offset: Int) -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift = 0
        var pos = offset
        while pos < data.count {
            let byte = data[pos]
            result |= UInt64(byte & 0x7F) << shift
            pos += 1
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return (result, pos)
    }
}

// MARK: - Model Store

enum CohereTranscribeModelStore {
    static func isAvailableLocally() -> Bool {
        if let overrideDir = localOverrideDirectory(), modelsExist(at: overrideDir) {
            return true
        }
        return modelsExist(at: cacheDirectory())
    }

    static func resolvedDirectory(progress: ((Double, String?) -> Void)? = nil) async throws -> URL {
        if let overrideDir = localOverrideDirectory(), modelsExist(at: overrideDir) {
            progress?(1.0, "Using local Cohere model override")
            return overrideDir
        }

        let target = CohereTranscribeConfig.defaultCacheDirectory
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if modelsExist(at: target) {
            progress?(1.0, "Cohere Transcribe already downloaded")
            return target
        }
        try await downloadMissingFiles(to: target, progress: progress)
        return target
    }

    static func modelsExist(at directory: URL) -> Bool {
        let fm = FileManager.default
        let modelsPresent = CohereTranscribeConfig.requiredModelPackages.allSatisfy { packageName in
            let packageURL = directory.appendingPathComponent(packageName, isDirectory: true)
            let compiledURL = directory.appendingPathComponent(
                packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"),
                isDirectory: true
            )
            let compiledData = compiledURL.appendingPathComponent("coremldata.bin")
            return fm.fileExists(atPath: packageURL.path) || fm.fileExists(atPath: compiledData.path)
        }
        guard modelsPresent else { return false }
        return CohereTranscribeConfig.requiredRelativeFiles.allSatisfy { relativePath in
            fm.fileExists(atPath: directory.appendingPathComponent(relativePath).path)
        }
    }

    static func localOverrideDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[CohereTranscribeConfig.envOverride], !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func cacheDirectory() -> URL {
        CohereTranscribeConfig.defaultCacheDirectory
    }

    private static func remoteURL(for relativePath: String) -> URL {
        var url = URL(string: "https://huggingface.co/\(CohereTranscribeConfig.repoId)/resolve/main")!
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "download", value: "1")]
        return components.url!
    }

    private static func downloadMissingFiles(to directory: URL, progress: ((Double, String?) -> Void)?) async throws {
        let fm = FileManager.default
        let modelPackageFiles = CohereTranscribeConfig.requiredModelPackages.flatMap { packageName in
            [
                "\(packageName)/Manifest.json",
                "\(packageName)/Data/com.apple.CoreML/model.mlmodel",
                "\(packageName)/Data/com.apple.CoreML/weights/weight.bin",
            ]
        }
        let required = modelPackageFiles + CohereTranscribeConfig.requiredRelativeFiles
        let missing = required.filter { relativePath in
            if let packageName = CohereTranscribeConfig.requiredModelPackages.first(where: { relativePath.hasPrefix("\($0)/") }) {
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
            progress?(Double(index) / Double(total), "Downloading Cohere Transcribe...")
            let destination = directory.appendingPathComponent(relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sourceURL = remoteURL(for: relativePath)
            let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw NSError(domain: "CohereTranscribe", code: 13, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to download \(relativePath)",
                ])
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: tempURL, to: destination)
        }
        progress?(1.0, "Cohere Transcribe download complete")
    }
}

// MARK: - Model Loading

private struct CohereTranscribeModels {
    let encoder: MLModel
    let encoderUsesDynamicLength: Bool
    let prefillDecoder: MLModel
    let decodeDecoder: MLModel
    let tokenizer: CohereSentencePieceDecoder
    let melExtractor: CohereMelSpectrogram

    static func load(from directory: URL, computeUnits: MLComputeUnits = .all) async throws -> CohereTranscribeModels {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        CohereProfilingLog.write("[cohere][load] start computeUnits=\(cohereComputeUnitsDescription(computeUnits)) dir=\(directory.path)")
        let encoder = try await loadModel(packageName: CohereTranscribeConfig.encoderPackage, from: directory, configuration: config)
        let prefill = try await loadModel(packageName: CohereTranscribeConfig.prefillPackage, from: directory, configuration: config)
        let decode = try await loadModel(packageName: CohereTranscribeConfig.decodePackage, from: directory, configuration: config)
        let tokenizer = try CohereSentencePieceDecoder(modelURL: directory.appendingPathComponent(CohereTranscribeConfig.tokenizerFile))
        let melExtractor = try CohereMelSpectrogram(directory: directory)
        let encoderUsesDynamicLength = encoder.modelDescription.inputDescriptionsByName.keys.contains("length")
        CohereProfilingLog.write("[cohere] encoderPackage=\(preferredEncoderPackageName(in: directory)) lengthAware=\(encoderUsesDynamicLength)")

        return CohereTranscribeModels(
            encoder: encoder,
            encoderUsesDynamicLength: encoderUsesDynamicLength,
            prefillDecoder: prefill,
            decodeDecoder: decode,
            tokenizer: tokenizer,
            melExtractor: melExtractor
        )
    }

    private static func loadModel(packageName: String, from directory: URL, configuration: MLModelConfiguration) async throws -> MLModel {
        let resolvedPackageName = packageName == CohereTranscribeConfig.encoderPackage
            ? preferredEncoderPackageName(in: directory)
            : packageName
        let packageURL = directory.appendingPathComponent(resolvedPackageName, isDirectory: true)
        let compiledURL = directory.appendingPathComponent(resolvedPackageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"), isDirectory: true)
        let isInt8Encoder = packageName == CohereTranscribeConfig.encoderPackage
            && resolvedPackageName == CohereTranscribeConfig.encoderPackage

        let effectiveConfiguration: MLModelConfiguration
        let shouldPreferCompiled: Bool
        if isInt8Encoder {
            let overrideComputeUnits = ProcessInfo.processInfo.environment[CohereTranscribeConfig.int8EncoderComputeUnitsOverrideEnv]
                .flatMap(cohereComputeUnits(from:))
            let overrideUseCompiled = ProcessInfo.processInfo.environment[CohereTranscribeConfig.int8EncoderUseCompiledOverrideEnv]
                .flatMap(cohereBool(from:))
            let encoderConfig = MLModelConfiguration()
            encoderConfig.computeUnits = overrideComputeUnits ?? .cpuAndGPU
            effectiveConfiguration = encoderConfig
            shouldPreferCompiled = overrideUseCompiled ?? false
            CohereProfilingLog.write(
                "[cohere][loadModel] int8 encoder override computeUnits=\(cohereComputeUnitsDescription(effectiveConfiguration.computeUnits)) useCompiled=\(shouldPreferCompiled)"
            )
        } else {
            effectiveConfiguration = configuration
            shouldPreferCompiled = true
        }

        CohereProfilingLog.write(
            "[cohere][loadModel] package=\(packageName) resolved=\(resolvedPackageName) computeUnits=\(cohereComputeUnitsDescription(effectiveConfiguration.computeUnits)) packageExists=\(FileManager.default.fileExists(atPath: packageURL.path)) compiledExists=\(FileManager.default.fileExists(atPath: compiledURL.path))"
        )

        let modelURL: URL
        if shouldPreferCompiled && FileManager.default.fileExists(atPath: compiledURL.path) {
            CohereProfilingLog.write("[cohere][loadModel] using compiled model \(compiledURL.lastPathComponent)")
            modelURL = compiledURL
        } else {
            if shouldPreferCompiled {
                let compileStart = CFAbsoluteTimeGetCurrent()
                CohereProfilingLog.write("[cohere][loadModel] compiling \(resolvedPackageName)")
                let compiledTemp = try await MLModel.compileModel(at: packageURL)
                try? FileManager.default.removeItem(at: compiledURL)
                try FileManager.default.copyItem(at: compiledTemp, to: compiledURL)
                try? FileManager.default.removeItem(at: compiledTemp)
                let compileMs = (CFAbsoluteTimeGetCurrent() - compileStart) * 1000
                CohereProfilingLog.write("[cohere][loadModel] compiled \(resolvedPackageName) in \(String(format: "%.0f", compileMs))ms")
                modelURL = compiledURL
            } else {
                CohereProfilingLog.write("[cohere][loadModel] using package model \(packageURL.lastPathComponent)")
                modelURL = packageURL
            }
        }

        let loadStart = CFAbsoluteTimeGetCurrent()
        CohereProfilingLog.write("[cohere][loadModel] loading \(modelURL.lastPathComponent)")
        let model = try await MLModel.load(contentsOf: modelURL, configuration: effectiveConfiguration)
        let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
        CohereProfilingLog.write("[cohere][loadModel] loaded \(modelURL.lastPathComponent) in \(String(format: "%.0f", loadMs))ms")
        return model
    }

    private static func preferredEncoderPackageName(in directory: URL) -> String {
        let dynamicURL = directory.appendingPathComponent(CohereTranscribeConfig.dynamicEncoderPackage, isDirectory: true)
        if FileManager.default.fileExists(atPath: dynamicURL.path) {
            return CohereTranscribeConfig.dynamicEncoderPackage
        }
        return CohereTranscribeConfig.encoderPackage
    }
}

// MARK: - Inference Manager

@available(macOS 15, *)
private final class CohereTranscribeManager {
    private let models: CohereTranscribeModels
    private let decodeUpdateMasks: [Int: MLMultiArray]
    private let decodeValidMasks: [Int: MLMultiArray]

    init(models: CohereTranscribeModels) throws {
        self.models = models
        var updateMasks: [Int: MLMultiArray] = [:]
        var validMasks: [Int: MLMultiArray] = [:]
        for position in 0..<CohereTranscribeConfig.maxSeqLen {
            updateMasks[position] = try Self.createUpdateMask(position: position)
            validMasks[position] = try Self.createValidMask(lastValidPosition: position)
        }
        self.decodeUpdateMasks = updateMasks
        self.decodeValidMasks = validMasks
    }

    func transcribe(audioSamples: [Float]) async throws -> (text: String, profile: CohereProfilingSummary) {
        let start = CFAbsoluteTimeGetCurrent()
        let duration = Double(audioSamples.count) / Double(CohereTranscribeConfig.sampleRate)
        var profile = CohereProfilingSummary(audioDurationS: duration)

        let scheduleStart = CFAbsoluteTimeGetCurrent()
        let chunks = scheduleChunks(samples: audioSamples)
        profile.chunkScheduleMs = (CFAbsoluteTimeGetCurrent() - scheduleStart) * 1000
        profile.chunkCount = chunks.count

        var transcripts: [String] = []
        var aggregate = CohereTimingBreakdown()
        var generatedTokenCount = 0
        var totalMelMs: Double = 0

        for (chunkIndex, chunkSamples) in chunks.enumerated() {
            let melStart = CFAbsoluteTimeGetCurrent()
            let (chunkMel, realFrameCount) = models.melExtractor.compute(audio: chunkSamples)
            totalMelMs += (CFAbsoluteTimeGetCurrent() - melStart) * 1000
            let result = try transcribeChunk(mel: chunkMel, realMelFrames: realFrameCount, chunkIndex: chunkIndex)
            if !result.transcript.isEmpty {
                transcripts.append(result.transcript)
            }
            generatedTokenCount += result.generatedTokenCount
            aggregate.encoderMs += result.timing.encoderMs
            aggregate.prefillMs += result.timing.prefillMs
            aggregate.decodeMs += result.timing.decodeMs
        }

        let mergeStart = CFAbsoluteTimeGetCurrent()
        let merged = transcripts.joined(separator: " ")
        profile.mergeMs = (CFAbsoluteTimeGetCurrent() - mergeStart) * 1000

        profile.melMs = totalMelMs
        profile.encoderMs = aggregate.encoderMs
        profile.prefillMs = aggregate.prefillMs
        profile.decodeMs = aggregate.decodeMs
        profile.generatedTokenCount = generatedTokenCount
        profile.transcriptCharacterCount = merged.count
        profile.totalProcessingMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        return (merged, profile)
    }

    private func transcribeChunk(mel: [[Float]], realMelFrames: Int, chunkIndex: Int) throws -> (transcript: String, generatedTokenCount: Int, timing: CohereTimingBreakdown) {
        var timing = CohereTimingBreakdown()
        let melLength = CohereTranscribeConfig.melLength
        let nMels = CohereTranscribeConfig.nMels
        let encLen = CohereTranscribeConfig.encLen

        // Build mel MLMultiArray [1, 128, 3500] — mel is already normalized & zero-padded to melLength
        let melArray = try MLMultiArray(shape: [1, NSNumber(value: nMels), NSNumber(value: melLength)], dataType: .float32)
        let melPtr = melArray.dataPointer.bindMemory(to: Float.self, capacity: nMels * melLength)
        for m in 0..<nMels {
            for f in 0..<melLength {
                melPtr[m * melLength + f] = mel[m][f]
            }
        }

        // Build encoder mask [1, enc_len]: 1.0 for real positions, 0.0 for padded
        // Subsampling factor = melLength / encLen = 3500 / 438 ≈ 8
        let realEncPositions = min((realMelFrames + 7) / 8, encLen)
        let encoderMask = try MLMultiArray(shape: [1, NSNumber(value: encLen)], dataType: .float32)
        let maskPtr = encoderMask.dataPointer.bindMemory(to: Float.self, capacity: encLen)
        for i in 0..<encLen {
            maskPtr[i] = i < realEncPositions ? 1.0 : 0.0
        }

        // Encoder
        let encStart = CFAbsoluteTimeGetCurrent()
        var encInputs: [String: MLFeatureValue] = [
            "mel": MLFeatureValue(multiArray: melArray),
        ]
        if models.encoderUsesDynamicLength {
            let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
            lengthArray[0] = NSNumber(value: Int32(realMelFrames))
            encInputs["length"] = MLFeatureValue(multiArray: lengthArray)
        }
        let encInput = try MLDictionaryFeatureProvider(dictionary: encInputs)
        let encOutput = try models.encoder.prediction(from: encInput)
        guard let encoderHidden = encOutput.featureValue(for: "encoder_hidden")?.multiArrayValue else {
            throw NSError(domain: "CohereTranscribe", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "Missing encoder_hidden output",
            ])
        }
        timing.encoderMs = (CFAbsoluteTimeGetCurrent() - encStart) * 1000

        // Prefill — pass encoder_mask so cross-attention ignores padded positions
        let prefillStart = CFAbsoluteTimeGetCurrent()
        let promptArray = try MLMultiArray(shape: [1, NSNumber(value: CohereTranscribeConfig.prefillLen)], dataType: .int32)
        let promptPtr = promptArray.dataPointer.bindMemory(to: Int32.self, capacity: CohereTranscribeConfig.prefillLen)
        for (i, id) in CohereTranscribeConfig.promptIds.enumerated() {
            promptPtr[i] = id
        }

        let state = models.prefillDecoder.makeState()
        let prefillInput = try MLDictionaryFeatureProvider(dictionary: [
            "encoder_hidden": MLFeatureValue(multiArray: encoderHidden),
            "input_ids": MLFeatureValue(multiArray: promptArray),
            "encoder_mask": MLFeatureValue(multiArray: encoderMask),
        ])
        let prefillOutput = try models.prefillDecoder.prediction(from: prefillInput, using: state)
        guard let prefillLogits = prefillOutput.featureValue(for: "logits")?.multiArrayValue else {
            throw NSError(domain: "CohereTranscribe", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "Missing logits from prefill decoder",
            ])
        }
        timing.prefillMs = (CFAbsoluteTimeGetCurrent() - prefillStart) * 1000

        // Argmax on last position of prefill logits
        var nextToken = argmaxLastPosition(logits: prefillLogits, seqLen: CohereTranscribeConfig.prefillLen)
        var generatedIds: [Int] = []
        var currentPosition = CohereTranscribeConfig.prefillLen

        // Autoregressive decode — encoder_mask passed each step for cross-attention masking
        let decodeStart = CFAbsoluteTimeGetCurrent()
        let audioSeconds = Double(realMelFrames * CohereTranscribeConfig.hopLength) / Double(CohereTranscribeConfig.sampleRate)
        let tokenBudget = max(15, Int(audioSeconds * 7.0))
        // Token budget: speech produces ~5-6 tokens/sec (from profiling). Cap at 7 tok/s
        // with minimum 15. The CoreML encoder can't do internal length masking, so the
        // decoder doesn't get a clean EOS signal — this caps hallucination/repetition.
        let maxNewTokens = models.encoderUsesDynamicLength
            ? (CohereTranscribeConfig.maxSeqLen - CohereTranscribeConfig.prefillLen)
            : min(CohereTranscribeConfig.maxSeqLen - CohereTranscribeConfig.prefillLen, tokenBudget)
        let tokenIdArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let tokenIdPtr = tokenIdArray.dataPointer.bindMemory(to: Int32.self, capacity: 1)

        for _ in 0..<maxNewTokens {
            if nextToken == CohereTranscribeConfig.eosTokenId { break }
            generatedIds.append(nextToken)
            guard currentPosition < CohereTranscribeConfig.maxSeqLen else { break }
            guard let updateMask = decodeUpdateMasks[currentPosition],
                  let validMask = decodeValidMasks[currentPosition] else { break }

            tokenIdPtr[0] = Int32(nextToken)
            let decodeInput = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: tokenIdArray),
                "cache_update_mask": MLFeatureValue(multiArray: updateMask),
                "cache_valid_mask": MLFeatureValue(multiArray: validMask),
                "encoder_mask": MLFeatureValue(multiArray: encoderMask),
            ])
            let decodeOutput = try models.decodeDecoder.prediction(from: decodeInput, using: state)
            guard let logits = decodeOutput.featureValue(for: "logits")?.multiArrayValue else {
                throw NSError(domain: "CohereTranscribe", code: 16, userInfo: [
                    NSLocalizedDescriptionKey: "Missing logits from decode decoder",
                ])
            }

            // Copy logits to a local buffer — CoreML output MLMultiArray may be read-only
            let vocabSize = CohereTranscribeConfig.vocabSize
            let srcPtr = logits.dataPointer.bindMemory(to: Float.self, capacity: vocabSize)
            var localLogits = [Float](unsafeUninitializedCapacity: vocabSize) { buf, count in
                buf.baseAddress!.initialize(from: srcPtr, count: vocabSize)
                count = vocabSize
            }

            if !models.encoderUsesDynamicLength {
                // EOS promotion: if EOS is in the top-3 logits, the model is "trying to stop"
                // but the contaminated encoder isn't giving a strong enough signal. Treat as EOS.
                // This uses the model's own confidence rather than external heuristics.
                let eosLogit = localLogits[CohereTranscribeConfig.eosTokenId]
                var countAboveEos = 0
                for i in 0..<vocabSize {
                    if localLogits[i] > eosLogit { countAboveEos += 1 }
                    if countAboveEos >= 3 { break }
                }
                if countAboveEos < 3 { break } // EOS in top-3 → stop

                // No-repeat n-gram: ban any token that would complete a repeated 4-gram.
                let noRepeatNgram = 4
                if generatedIds.count >= noRepeatNgram {
                    let prefix = Array(generatedIds.suffix(noRepeatNgram - 1))
                    for i in 0...(generatedIds.count - noRepeatNgram) {
                        if Array(generatedIds[i..<(i + noRepeatNgram - 1)]) == prefix {
                            localLogits[generatedIds[i + noRepeatNgram - 1]] = -.greatestFiniteMagnitude
                        }
                    }
                }
            }

            nextToken = argmaxLocal(logits: localLogits)
            currentPosition += 1
        }
        timing.decodeMs = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000

        let rawTranscript = models.tokenizer.decode(tokenIds: generatedIds)
        let transcript = Self.cleanTranscript(rawTranscript)
        return (transcript, generatedIds.count, timing)
    }

    /// Strip hallucinated tails: text after <|endoftext|> and repeated sentence fragments.
    private static func cleanTranscript(_ text: String) -> String {
        // Strip anything after <|endoftext|>
        var cleaned = text
        if let range = cleaned.range(of: "<|endoftext|>") {
            cleaned = String(cleaned[cleaned.startIndex..<range.lowerBound])
        }
        // Strip other special tokens
        for token in ["<|nospeech|>", "<|startofcontext|>", "<|startoftranscript|>",
                       "<|notimestamp|>", "<|nodiarize|>", "<|pnc|>", "<|noitn|>",
                       "<|emo:undefined|>"] {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }
        // Detect and remove repeated sentence fragments.
        // If the same sentence-ending pattern (. or , followed by space) repeats 3+ times,
        // keep only the content up to the second occurrence.
        cleaned = Self.trimRepeatedSuffix(cleaned)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimRepeatedSuffix(_ text: String) -> String {
        // Split by sentence boundaries and detect repetition
        let sentences = text.components(separatedBy: ". ")
        guard sentences.count >= 4 else { return text }

        // Check if the last few sentences repeat
        var uniqueEnd = sentences.count
        for i in 1..<sentences.count {
            let current = sentences[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !current.isEmpty else { continue }
            // Look for this sentence appearing earlier
            for j in 0..<i {
                let earlier = sentences[j].trimmingCharacters(in: .whitespacesAndNewlines)
                if current == earlier && i - j <= 3 {
                    // Found a repeat — truncate here
                    uniqueEnd = i
                    let kept = sentences[0..<uniqueEnd].joined(separator: ". ")
                    // Add period if the last kept sentence doesn't end with punctuation
                    if !kept.hasSuffix(".") && !kept.hasSuffix("!") && !kept.hasSuffix("?") {
                        return kept + "."
                    }
                    return kept
                }
            }
        }
        return text
    }

    private func scheduleChunks(samples: [Float]) -> [[Float]] {
        let maxSamples = CohereTranscribeConfig.maxAudioSamples
        if samples.count <= maxSamples {
            return [samples]
        }

        let overlap = CohereTranscribeConfig.chunkOverlapSamples
        let stride = maxSamples - overlap
        var chunks: [[Float]] = []
        var start = 0
        while start < samples.count {
            let end = min(start + maxSamples, samples.count)
            chunks.append(Array(samples[start..<end]))
            start += stride
            if end == samples.count { break }
        }
        return chunks
    }

    private func argmax(logits: MLMultiArray) -> Int {
        let count = logits.count
        guard count > 0 else { return 0 }
        let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: count)
        var maxVal = ptr[0]
        var maxIdx = 0
        for i in 1..<count {
            if ptr[i] > maxVal {
                maxVal = ptr[i]
                maxIdx = i
            }
        }
        return maxIdx
    }

    private func argmaxLocal(logits: [Float]) -> Int {
        guard !logits.isEmpty else { return 0 }
        var maxVal = logits[0]
        var maxIdx = 0
        for i in 1..<logits.count {
            if logits[i] > maxVal {
                maxVal = logits[i]
                maxIdx = i
            }
        }
        return maxIdx
    }

    private func argmaxLastPosition(logits: MLMultiArray, seqLen: Int) -> Int {
        let vocabSize = CohereTranscribeConfig.vocabSize
        let offset = (seqLen - 1) * vocabSize
        let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: seqLen * vocabSize)
        var maxVal = ptr[offset]
        var maxIdx = 0
        for i in 1..<vocabSize {
            if ptr[offset + i] > maxVal {
                maxVal = ptr[offset + i]
                maxIdx = i
            }
        }
        return maxIdx
    }

    private static func createUpdateMask(position: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: CohereTranscribeConfig.maxSeqLen)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: CohereTranscribeConfig.maxSeqLen)
        ptr.initialize(repeating: 0, count: CohereTranscribeConfig.maxSeqLen)
        if position < CohereTranscribeConfig.maxSeqLen {
            ptr[position] = 1
        }
        return array
    }

    private static func createValidMask(lastValidPosition: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: CohereTranscribeConfig.maxSeqLen)], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: CohereTranscribeConfig.maxSeqLen)
        ptr.initialize(repeating: 0, count: CohereTranscribeConfig.maxSeqLen)
        for index in 0...lastValidPosition {
            ptr[index] = 1
        }
        return array
    }
}

// MARK: - Public Transcriber Actor

@available(macOS 15, *)
actor CohereTranscribeTranscriber {
    private var manager: CohereTranscribeManager?
    private var loadTask: Task<CohereTranscribeManager, Error>?
    private var warmupTask: Task<Void, Never>?
    private var hasCompletedWarmup = false

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Cohere Transcribe models not loaded. Call loadModels() first."
            }
        }
    }

    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if manager != nil { return }
        if let loadTask {
            self.manager = try await loadTask.value
            return
        }

        let task = Task<CohereTranscribeManager, Error> {
            CohereProfilingLog.write("[cohere] downloading/loading models...")
            let dirStart = CFAbsoluteTimeGetCurrent()
            let modelDir = try await CohereTranscribeModelStore.resolvedDirectory(progress: progress)
            let dirMs = (CFAbsoluteTimeGetCurrent() - dirStart) * 1000
            CohereProfilingLog.write("[cohere][load] resolvedDirectory in \(String(format: "%.0f", dirMs))ms path=\(modelDir.path)")
            let modelsStart = CFAbsoluteTimeGetCurrent()
            let models = try await CohereTranscribeModels.load(from: modelDir)
            let modelsMs = (CFAbsoluteTimeGetCurrent() - modelsStart) * 1000
            CohereProfilingLog.write("[cohere][load] CohereTranscribeModels.load finished in \(String(format: "%.0f", modelsMs))ms")
            let managerStart = CFAbsoluteTimeGetCurrent()
            let loadedManager = try CohereTranscribeManager(models: models)
            let managerMs = (CFAbsoluteTimeGetCurrent() - managerStart) * 1000
            CohereProfilingLog.write("[cohere][load] manager init finished in \(String(format: "%.0f", managerMs))ms")
            CohereProfilingLog.write("[cohere] models loaded, ready")
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

    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double, profile: CohereProfilingSummary) {
        try await loadModels()
        if let warmupTask {
            CohereProfilingLog.write("[cohere] waiting for background warmup to finish before dictation...")
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
        CohereProfilingLog.write(profile.logDescription(prefix: "[cohere][dictation]"))
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

        CohereProfilingLog.write("[cohere] background warmup started")
        let warmupSamples = [Float](repeating: 0, count: 16_000)
        do {
            let result = try await manager.transcribe(audioSamples: warmupSamples)
            hasCompletedWarmup = true
            CohereProfilingLog.write(result.profile.logDescription(prefix: "[cohere][warmup]"))
            CohereProfilingLog.write("[cohere] background warmup complete")
        } catch {
            CohereProfilingLog.write("[cohere] background warmup failed: \(error)")
        }
        warmupTask = nil
    }
}
