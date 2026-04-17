import Foundation

struct OnboardingProgress: Codable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = currentSchemaVersion
    var currentStep: Int
    var userName: String
    var selectedBackendKey: String
    var selectedModelKey: String
    var hotkeyKeyCode: UInt16
    var hotkeyLabel: String
    var systemAudioRequested: Bool = false

    init(
        schemaVersion: Int = currentSchemaVersion,
        currentStep: Int,
        userName: String,
        selectedBackendKey: String,
        selectedModelKey: String,
        hotkeyKeyCode: UInt16,
        hotkeyLabel: String,
        systemAudioRequested: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.currentStep = currentStep
        self.userName = userName
        self.selectedBackendKey = selectedBackendKey
        self.selectedModelKey = selectedModelKey
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyLabel = hotkeyLabel
        self.systemAudioRequested = systemAudioRequested
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        currentStep = try c.decode(Int.self, forKey: .currentStep)
        userName = try c.decode(String.self, forKey: .userName)
        selectedBackendKey = try c.decode(String.self, forKey: .selectedBackendKey)
        selectedModelKey = try c.decode(String.self, forKey: .selectedModelKey)
        hotkeyKeyCode = try c.decode(UInt16.self, forKey: .hotkeyKeyCode)
        hotkeyLabel = try c.decode(String.self, forKey: .hotkeyLabel)
        systemAudioRequested = try c.decodeIfPresent(Bool.self, forKey: .systemAudioRequested) ?? false
    }

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
        guard var progress = try? JSONDecoder().decode(OnboardingProgress.self, from: data) else {
            // Stale or incompatible schema — discard and start fresh
            clear()
            return nil
        }
        guard progress.schemaVersion <= currentSchemaVersion else {
            clear()
            return nil
        }
        if progress.schemaVersion < currentSchemaVersion {
            progress.schemaVersion = currentSchemaVersion
            save(progress)
        }
        return progress
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
