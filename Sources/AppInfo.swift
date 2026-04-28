import Foundation

enum AppInfo {
    /// Marketing version (CFBundleShortVersionString). Falls back to "dev"
    /// when read in a non-bundle context (e.g. Previews, CLI typecheck).
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Build number (CFBundleVersion). Set by CI from the git short SHA.
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Compact display: "v0.1.0 · 1a2b3c4"
    static var displayString: String {
        "v\(version) · \(build)"
    }
}
