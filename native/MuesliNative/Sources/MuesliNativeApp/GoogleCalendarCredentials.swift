import Foundation

struct GoogleCalendarCredentials {
    let clientId: String
    let clientSecret: String
    /// Whether the OAuth app has passed Google's verification review.
    /// When false, only test users can connect. UI shows "verification pending".
    let verified: Bool

    /// Load credentials from app bundle (production) or ~/.config/muesli/ (dev).
    /// Returns nil if no credentials found — Google Calendar feature is disabled.
    static func load() -> GoogleCalendarCredentials? {
        // 1. Try app bundle (production builds embed via build script)
        if let bundleURL = Bundle.main.url(forResource: "google-oauth", withExtension: "json"),
           let creds = parse(url: bundleURL) {
            fputs("[google-cal] credentials loaded from app bundle\n", stderr)
            return creds
        }

        // 2. Try dev config file
        let devPath = NSString("~/.config/muesli/google-oauth.json").expandingTildeInPath
        let devURL = URL(fileURLWithPath: devPath)
        if let creds = parse(url: devURL) {
            fputs("[google-cal] credentials loaded from ~/.config/muesli/\n", stderr)
            return creds
        }

        fputs("[google-cal] no credentials found — Google Calendar integration disabled\n", stderr)
        return nil
    }

    private static func parse(url: URL) -> GoogleCalendarCredentials? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = json["client_id"] as? String,
              let clientSecret = json["client_secret"] as? String,
              !clientId.isEmpty, !clientSecret.isEmpty else {
            return nil
        }
        let verified = json["verified"] as? Bool ?? false
        return GoogleCalendarCredentials(clientId: clientId, clientSecret: clientSecret, verified: verified)
    }
}
