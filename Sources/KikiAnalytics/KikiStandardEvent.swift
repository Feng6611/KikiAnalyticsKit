import Foundation

/// Shared vocabulary, with product meaning and typed classifications supplied by apps.
public enum KikiStandardEvent: KikiAnalyticsEvent {
    public enum FirstOpenKind: String, Sendable { case freshInstall = "fresh_install", analyticsRollout = "analytics_rollout" }

    case appFirstOpened(kind: FirstOpenKind)
    case onboardingStarted(session: KikiAnalyticsSessionID)
    case onboardingCompleted(method: KikiAnalyticsValue, durationMs: Int)
    case valueDay(changes: Int)
    case paywallViewed(session: KikiAnalyticsSessionID, source: KikiAnalyticsValue)
    case paywallAction(session: KikiAnalyticsSessionID, action: KikiAnalyticsValue)
    case purchaseResult(session: KikiAnalyticsSessionID, result: KikiAnalyticsValue)

    public static func onboardingCompleted<E: RawRepresentable>(method: E, durationMs: Int) -> Self where E.RawValue == String {
        .onboardingCompleted(method: .enum(method), durationMs: durationMs)
    }

    public static func paywallViewed<E: RawRepresentable>(session: KikiAnalyticsSessionID, source: E) -> Self where E.RawValue == String {
        .paywallViewed(session: session, source: .enum(source))
    }

    public static func paywallAction<E: RawRepresentable>(session: KikiAnalyticsSessionID, action: E) -> Self where E.RawValue == String {
        .paywallAction(session: session, action: .enum(action))
    }

    public static func purchaseResult<E: RawRepresentable>(session: KikiAnalyticsSessionID, result: E) -> Self where E.RawValue == String {
        .purchaseResult(session: session, result: .enum(result))
    }

    public var name: String {
        switch self {
        case .appFirstOpened: return "app first opened"
        case .onboardingStarted: return "onboarding started"
        case .onboardingCompleted: return "onboarding completed"
        case .valueDay: return "value day"
        case .paywallViewed: return "paywall viewed"
        case .paywallAction: return "paywall action"
        case .purchaseResult: return "purchase result"
        }
    }

    public var properties: KikiAnalyticsProperties {
        switch self {
        case let .appFirstOpened(kind): return ["first_open_kind": .enum(kind)]
        case let .onboardingStarted(session): return ["session_id": .sessionID(session)]
        case let .onboardingCompleted(method, duration): return ["method": method, "duration_ms": .int(duration)]
        case let .valueDay(changes): return ["value_bucket": .bucket(changes)]
        case let .paywallViewed(session, source): return ["session_id": .sessionID(session), "source": source]
        case let .paywallAction(session, action): return ["session_id": .sessionID(session), "action": action]
        case let .purchaseResult(session, result): return ["session_id": .sessionID(session), "result": result]
        }
    }

    public var frequency: KikiAnalyticsFrequency {
        switch self {
        case .appFirstOpened, .onboardingCompleted: return .oncePerInstall
        case .valueDay: return .oncePerLocalDay
        case let .onboardingStarted(session), let .paywallViewed(session, _):
            return .oncePerSession(id: session.rawValue)
        case .paywallAction, .purchaseResult: return .always
        }
    }
}
