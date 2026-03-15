import Foundation

struct RuntimePaths {
    let repoRoot: URL
    let pythonExecutable: URL
    let workerScript: URL
    let pasteScript: URL
    let systemAudioTool: URL?
    let menuIcon: URL?
    let appIcon: URL?
    let bundlePath: URL?

    static func resolve() throws -> RuntimePaths {
        let fileManager = FileManager.default

        if let bundleResource = Bundle.main.resourceURL {
            let runtimeURL = bundleResource.appendingPathComponent("runtime.json")
            if fileManager.fileExists(atPath: runtimeURL.path) {
                let data = try Data(contentsOf: runtimeURL)
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let isBundled = payload?["bundled"] as? String == "true" || payload?["bundled"] as? Bool == true

                // When bundled, use the actual bundle Resources path (not the hardcoded one from runtime.json)
                // so the app works from any install location, not just /Applications
                let repoRoot = isBundled ? bundleResource : URL(fileURLWithPath: payload?["repo_root"] as? String ?? "")

                let pythonExecutable: URL
                if isBundled {
                    // Bundled: python path is relative to Resources
                    let relativePython = payload?["python_executable"] as? String ?? "python-runtime/bin/python3"
                    pythonExecutable = bundleResource.appendingPathComponent(relativePython)
                } else {
                    pythonExecutable = URL(fileURLWithPath: payload?["python_executable"] as? String ?? "")
                }

                let workerScript = bundleResource.appendingPathComponent("worker.py")
                return RuntimePaths(
                    repoRoot: repoRoot,
                    pythonExecutable: pythonExecutable,
                    workerScript: workerScript,
                    pasteScript: bundleResource.appendingPathComponent("paste_text.py"),
                    systemAudioTool: {
                        let tool = bundleResource.appendingPathComponent("MuesliSystemAudio")
                        return fileManager.fileExists(atPath: tool.path) ? tool : nil
                    }(),
                    menuIcon: bundleResource.appendingPathComponent("menu_m_template.png"),
                    appIcon: bundleResource.appendingPathComponent("muesli.icns"),
                    bundlePath: Bundle.main.bundleURL
                )
            }
        }

        var searchURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = searchURL.appendingPathComponent("bridge/worker.py")
            if fileManager.fileExists(atPath: candidate.path) {
                let pythonExecutable = searchURL.appendingPathComponent(".venv/bin/python")
                let systemAudioCandidates = [
                    searchURL.appendingPathComponent("native/MuesliNative/.build/release/MuesliSystemAudio"),
                    searchURL.appendingPathComponent("native/MuesliNative/.build/apple/Products/release/MuesliSystemAudio"),
                    searchURL.appendingPathComponent("native/MuesliNative/.build/apple/Products/Release/MuesliSystemAudio"),
                ]
                return RuntimePaths(
                    repoRoot: searchURL,
                    pythonExecutable: pythonExecutable,
                    workerScript: candidate,
                    pasteScript: searchURL.appendingPathComponent("bridge/paste_text.py"),
                    systemAudioTool: systemAudioCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
                    menuIcon: searchURL.appendingPathComponent("assets/menu_m_template.png"),
                    appIcon: searchURL.appendingPathComponent("assets/muesli.icns"),
                    bundlePath: nil
                )
            }
            searchURL.deleteLastPathComponent()
        }

        throw NSError(domain: "MuesliRuntime", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root or bundled runtime metadata.",
        ])
    }
}
