import Foundation

struct OnboardingProgress: Codable {
    var currentStep: Int
    var userName: String
    var selectedBackendKey: String
    var selectedModelKey: String
    var hotkeyKeyCode: UInt16
    var hotkeyLabel: String

    private static var fileURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("onboarding-progress.json")
    }

    static func save(_ progress: OnboardingProgress) {
        do {
            let dir = AppIdentity.supportDirectoryURL
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(progress)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            fputs("[muesli-native] failed to save onboarding progress: \(error)\n", stderr)
        }
    }

    static func load() -> OnboardingProgress? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(OnboardingProgress.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
