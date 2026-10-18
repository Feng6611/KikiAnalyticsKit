import SwiftUI

private final class DisabledAnalyticsTracking: KikiAnalyticsTracking {
    @MainActor func track(_ event: any KikiAnalyticsEvent) {}
}

private struct KikiAnalyticsEnvironmentKey: EnvironmentKey {
    static let defaultValue: any KikiAnalyticsTracking = DisabledAnalyticsTracking()
}

public extension EnvironmentValues {
    var kikiAnalytics: any KikiAnalyticsTracking {
        get { self[KikiAnalyticsEnvironmentKey.self] }
        set { self[KikiAnalyticsEnvironmentKey.self] = newValue }
    }
}

public extension View {
    func kikiAnalytics(_ analytics: any KikiAnalyticsTracking) -> some View {
        environment(\.kikiAnalytics, analytics)
    }
}
