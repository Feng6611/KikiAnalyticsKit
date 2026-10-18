import Foundation
import KikiAnalytics
@_spi(PostHogInternal) import PostHog

public extension KikiAnalyticsTransportFactory {
    static func postHog(_ configuration: KikiPostHogConfiguration) -> Self {
        postHog(configuration) { config, installationID in
            let sdk = PostHogSDK.with(config)
            // getAnonymousId only generates NEW identities. Normalize a previous
            // SDK installation via its public storage setters too. Synchronous
            // setup lifecycle captures already use our ID through beforeSend.
            config.storageManager?.setAnonymousId(installationID.uuidString)
            config.storageManager?.setDistinctId(installationID.uuidString)
            config.storageManager?.setIdentified(false)
            config.storageManager?.setPersonProcessing(false)
            return KikiPostHogTransport(sdk: sdk)
        }
    }
}

internal extension KikiAnalyticsTransportFactory {
    /// Startup seam lets tests exercise token gating without constructing an SDK.
    static func postHog(
        _ configuration: KikiPostHogConfiguration,
        start: @escaping @MainActor (PostHogConfig, UUID) -> any KikiAnalyticsTransport
    ) -> Self {
        guard configuration.hasValidToken else { return .none }
        return Self { installationID, commonProperties in
            start(makePostHogConfig(configuration, installationID: installationID,
                                    commonProperties: commonProperties), installationID)
        }
    }
}

/// Pure configuration construction: no SDK, storage, setup or network activity.
internal func makePostHogConfig(
    _ configuration: KikiPostHogConfiguration,
    installationID: UUID,
    commonProperties: [String: Any]
) -> PostHogConfig {
    let config = PostHogConfig(projectToken: configuration.token, host: configuration.host)
    config.captureApplicationLifecycleEvents = true
    config.captureScreenViews = false
    config.enableSwizzling = false
    config.capturePushNotificationSubscriptions = false
    config.capturePushNotificationOpened = false
    config.errorTrackingConfig.autoCapture = false
    config.errorTrackingConfig.exceptionSteps.enabled = false
    config.personProfiles = .never
    config.setDefaultPersonProperties = false // Flag person context, NOT device event properties.
    config.preloadFeatureFlags = false
    config.sendFeatureFlagEvent = false
    config.disableGeoIp = true
    config.flushAt = 20
    config.flushIntervalSeconds = 900
    config.optOut = false
    // This pinned SDK exposes this as SPI. The Kit's prefixed setting is the
    // consent source; a second persisted SDK value must not override it on restart.
    config.persistOptOut = false
    config.getAnonymousId = { _ in installationID }
    // No macOS members for element autocapture or replay. Surveys is unavailable.
    #if os(iOS)
    config.captureElementInteractions = false
    config.captureSwiftUIElementInteractions = false
    config.sessionReplay = false
    config.surveys = false
    #endif
    let filter = PostHogEventFilter(installationID: installationID, commonProperties: commonProperties)
    config.setBeforeSend { event in filter.apply(to: event) }
    return config
}

/// Mirrors the macOS context/buildProperties paths in PostHog 3.89.0.
internal struct PostHogEventFilter {
    static let declaredKeysProperty = "__kiki_declared_keys"
    static let sdkKeys: Set<String> = [
        "$app_name", "$app_version", "$app_build", "$app_namespace", "$is_testflight", "$is_sideloaded",
        "$device_manufacturer", "$device_model", "$device_type", "$device_name", "$is_emulator",
        "$is_ios_running_on_mac", "$is_mac_catalyst_app", "$os_name", "$os_version",
        "$screen_width", "$screen_height", "$locale", "$timezone", "$network_wifi", "$network_cellular",
        "$lib", "$lib_version", "$is_identified", "$process_person_profile", "$geoip_disable",
        "$recording_status", "$session_id", "$sdk_debug_session_start",
        "$sdk_debug_current_session_duration", "$sdk_debug_pending_queue_size"
    ]
    static let commonKeys: Set<String> = [
        "app_id", "app_version", "build_number", "distribution_channel", "os_version", "app_locale", "schema_version"
    ]
    static let lifecycleNames: Set<String> = [
        "Application Installed", "Application Updated", "Application Opened", "Application Backgrounded"
    ]
    /// The SDK's own lifecycle fields: versions and launch kind, nothing user-derived.
    static let lifecycleKeys: Set<String> = ["version", "build", "previous_version", "previous_build", "from_background"]

    let installationID: UUID
    let commonProperties: [String: Any]

    func apply(to event: PostHogEvent) -> PostHogEvent {
        let declared: Set<String>
        if Self.lifecycleNames.contains(event.event) {
            declared = Self.lifecycleKeys
        } else {
            // Keys belong to this individual capture, never a growing per-name union.
            declared = Set(event.properties[Self.declaredKeysProperty] as? [String] ?? [])
                .filter { !$0.hasPrefix("$") && !$0.hasPrefix("__kiki_") }
        }
        let allowed = Self.sdkKeys.union(Self.commonKeys).union(declared)
        event.properties = event.properties.filter { allowed.contains($0.key) }
        for (key, value) in commonProperties where Self.commonKeys.contains(key) {
            // Preserve current per-event common values (locale may have changed).
            if event.properties[key] == nil { event.properties[key] = value }
        }
        event.properties["$geoip_disable"] = true
        event.properties["$process_person_profile"] = false
        event.properties["$is_identified"] = false
        event.distinctId = installationID.uuidString
        return event
    }
}

/// Narrow SDK boundary for offline adapter tests; setup is deliberately absent.
internal protocol PostHogCapturing: AnyObject {
    func capture(_ event: String, distinctId: String?, properties: [String: Any]?,
                 userProperties: [String: Any]?, userPropertiesSetOnce: [String: Any]?, groups: [String: String]?)
    func flush()
    func optIn()
    func optOut()
}

extension PostHogSDK: PostHogCapturing {}

internal final class KikiPostHogTransport: KikiAnalyticsTransport {
    private let sdk: any PostHogCapturing

    init(sdk: any PostHogCapturing) { self.sdk = sdk }

    func send(name: String, distinctID: String, properties: [String: Any]) {
        var marked = properties
        marked[PostHogEventFilter.declaredKeysProperty] = Array(properties.keys)
        sdk.capture(name, distinctId: distinctID, properties: marked,
                    userProperties: nil, userPropertiesSetOnce: nil, groups: nil)
    }

    func flush() { sdk.flush() }
    func setOptedOut(_ optedOut: Bool) {
        if optedOut { sdk.optOut() } else { sdk.optIn() }
    }
}
