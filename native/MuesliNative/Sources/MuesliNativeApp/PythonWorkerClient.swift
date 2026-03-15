import Foundation

final class PythonWorkerClient {
    typealias ResponseCompletion = (Result<[String: Any], Error>) -> Void

    private let runtime: RuntimePaths
    private let ioQueue = DispatchQueue(label: "com.muesli.worker")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: ResponseCompletion] = [:]

    init(runtime: RuntimePaths) {
        self.runtime = runtime
    }

    func start() throws {
        if let process, process.isRunning {
            return
        }

        let process = Process()
        process.executableURL = runtime.pythonExecutable
        process.arguments = [runtime.workerScript.path]
        process.currentDirectoryURL = runtime.repoRoot

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONPATH"] = runtime.repoRoot.path
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeOutput(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            fputs(line, stderr)
        }

        process.terminationHandler = { [weak self] process in
            self?.handleTermination(reason: process.terminationReason, status: process.terminationStatus)
        }

        try process.run()
        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting
        self.outputHandle = outputPipe.fileHandleForReading
    }

    func stop() {
        ioQueue.async {
            guard let process = self.process else { return }
            if process.isRunning {
                self.send(method: "shutdown", params: [:]) { _ in }
            }
            process.terminate()
            self.process = nil
            self.inputHandle = nil
        }
    }

    func ping(completion: @escaping ResponseCompletion) {
        send(method: "ping", params: [:], completion: completion)
    }

    func preloadBackend(option: BackendOption, completion: @escaping ResponseCompletion) {
        send(
            method: "preload_backend",
            params: ["backend": option.backend, "model": option.model],
            completion: completion
        )
    }

    func transcribeFile(wavURL: URL, option: BackendOption, customWords: [[String: Any]] = [], completion: @escaping ResponseCompletion) {
        send(
            method: "transcribe_file",
            params: [
                "wav_path": wavURL.path,
                "backend": option.backend,
                "model": option.model,
                "custom_words": customWords,
            ],
            completion: completion
        )
    }

    func transcribeMeetingChunk(wavURL: URL, option: BackendOption, customWords: [[String: Any]] = [], completion: @escaping ResponseCompletion) {
        send(
            method: "transcribe_meeting_chunk",
            params: [
                "wav_path": wavURL.path,
                "backend": option.backend,
                "model": option.model,
                "custom_words": customWords,
            ],
            completion: completion
        )
    }

    private func send(method: String, params: [String: Any], completion: @escaping ResponseCompletion) {
        ioQueue.async {
            do {
                try self.start()
                let requestID = UUID().uuidString
                let payload: [String: Any] = [
                    "id": requestID,
                    "method": method,
                    "params": params,
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                guard let handle = self.inputHandle else {
                    throw NSError(domain: "MuesliWorker", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Worker stdin is not available.",
                    ])
                }
                self.pending[requestID] = completion
                handle.write(data)
                handle.write("\n".data(using: .utf8)!)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        ioQueue.async {
            self.outputBuffer.append(data)
            while let newline = self.outputBuffer.firstIndex(of: 0x0A) {
                let lineData = self.outputBuffer.prefix(upTo: newline)
                self.outputBuffer.removeSubrange(...newline)
                guard !lineData.isEmpty else { continue }
                do {
                    let object = try JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
                    let requestID = object?["id"] as? String ?? ""
                    let completion = self.pending.removeValue(forKey: requestID)
                    if let ok = object?["ok"] as? Bool, ok, let result = object?["result"] as? [String: Any] {
                        DispatchQueue.main.async {
                            completion?(.success(result))
                        }
                    } else {
                        let errorDict = object?["error"] as? [String: Any]
                        let message = errorDict?["message"] as? String ?? "Worker error"
                        let error = NSError(domain: "MuesliWorker", code: 2, userInfo: [
                            NSLocalizedDescriptionKey: message,
                        ])
                        DispatchQueue.main.async {
                            completion?(.failure(error))
                        }
                    }
                } catch {
                    fputs("[worker-client] failed to decode worker output: \(error)\n", stderr)
                }
            }
        }
    }

    private func handleTermination(reason: Process.TerminationReason, status: Int32) {
        ioQueue.async {
            let completions = self.pending.values
            self.pending.removeAll()
            self.process = nil
            self.inputHandle = nil
            self.outputHandle = nil
            let error = NSError(domain: "MuesliWorker", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Python worker terminated unexpectedly (\(reason), status \(status)).",
            ])
            DispatchQueue.main.async {
                completions.forEach { $0(.failure(error)) }
            }
        }
    }
}
