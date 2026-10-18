import Foundation

public struct KikiPostHogConfiguration: Sendable {
    public let token: String
    public let host: String

    public init(token: String, host: String = "https://us.i.posthog.com") {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.host = host
    }

    public static func fromInfoPlist(bundle: Bundle = .main) -> Self {
        Self(token: bundle.object(forInfoDictionaryKey: "KikiPostHogProjectToken") as? String ?? "",
             host: bundle.object(forInfoDictionaryKey: "KikiPostHogHost") as? String ?? "https://us.i.posthog.com")
    }

    internal var hasValidToken: Bool {
        token.hasPrefix("phc_") && !token.contains("$(") && !token.lowercased().contains("your")
            && !token.lowercased().contains("placeholder")
    }
}
