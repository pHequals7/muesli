import Foundation

// MARK: - PWAConfig

/// Per-PWA opt-in state for the v2 PWA discovery feature. Nested into
/// `AutoCaptureConfig` under the `pwa` JSON key. All fields default to empty
/// so config files written by v0/v1 builds decode cleanly with `pwa == .empty`.
struct PWAConfig: Codable, Equatable {

    /// Per-bundle-ID toggle state. PWAs not present in this map are treated as
    /// disabled — adding a key with `true` opts that PWA into auto-capture by
    /// adding its bundle ID to `AutoCaptureConfig.allowedAppBundleIDs` via the
    /// Settings view's mutation helpers.
    var enabled: [String: Bool]

    /// Cached scan results so the Settings pane has something to render before
    /// a fresh scan completes. Refreshed on app launch and whenever the user
    /// hits the Refresh button.
    var cachedEntries: [PWAEntry]

    static let empty = PWAConfig()

    init(enabled: [String: Bool] = [:], cachedEntries: [PWAEntry] = []) {
        self.enabled = enabled
        self.cachedEntries = cachedEntries
    }

    /// True if the supplied bundle ID has been toggled on.
    func isEnabled(bundleID: String) -> Bool {
        enabled[bundleID] ?? false
    }

    /// Bundle IDs the user has currently toggled on, in a stable order.
    var enabledBundleIDs: [String] {
        enabled.compactMap { key, value in value ? key : nil }.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case cachedEntries = "cached_entries"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PWAConfig()
        self.enabled = (try? c.decode([String: Bool].self, forKey: .enabled)) ?? defaults.enabled
        self.cachedEntries = (try? c.decode([PWAEntry].self, forKey: .cachedEntries)) ?? defaults.cachedEntries
    }
}
