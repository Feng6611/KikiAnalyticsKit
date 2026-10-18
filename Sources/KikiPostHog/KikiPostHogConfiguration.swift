import Foundation

public struct KikiPostHogConfiguration: Sendable {
    public let token: String
    public let host: String

    public static let defaultHost = "https://us.i.posthog.com"

    /// A blank host (an empty build setting) falls back to the default.
    public init(token: String, host: String = defaultHost) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = trimmedHost.isEmpty ? Self.defaultHost : trimmedHost
    }

    public static func fromInfoPlist(bundle: Bundle = .main) -> Self {
        Self(token: bundle.object(forInfoDictionaryKey: "KikiPostHogProjectToken") as? String ?? "",
             host: bundle.object(forInfoDictionaryKey: "KikiPostHogHost") as? String ?? defaultHost)
    }

    internal var hasValidToken: Bool {
        token.hasPrefix("phc_") && !token.contains("$(") && !token.lowercased().contains("your")
            && !token.lowercased().contains("placeholder")
    }
}
