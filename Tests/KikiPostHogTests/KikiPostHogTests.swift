import XCTest
@testable import KikiAnalytics
@testable import KikiPostHog
import KikiAnalyticsTesting
@_spi(PostHogInternal) @testable import PostHog

@MainActor
final class KikiPostHogTests: XCTestCase {
    private let installationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let common: [String: Any] = [
        "app_id": "test_app", "app_version": "1.0", "build_number": "1",
        "distribution_channel": "direct", "os_version": "macOS 15.4",
        "app_locale": "en_US", "schema_version": 1
    ]

    func testInvalidTokensReturnNoneAndNeverStartSDK() async {
        let recorder = RecordingAnalyticsTransport()
        for token in ["", "  \n", "$(TOKEN)", "phc_$(TOKEN)", "YOUR_TOKEN", "phc_YOUR_TOKEN",
                      "phc_placeholder", "phc_PlaceHolder", "wrong", "phx_abc", "PHC_abc"] {
            var starts = 0
            let factory = KikiAnalyticsTransportFactory.postHog(.init(token: token)) { _, _ in
                starts += 1
                return recorder
            }
            XCTAssertNil(factory.make(installationID: installationID, commonProperties: common), token)
            XCTAssertEqual(starts, 0, token)
            // Also exercises the public factory, safe precisely because invalid tokens are no-ops.
            XCTAssertNil(KikiAnalyticsTransportFactory.postHog(.init(token: token))
                .make(installationID: installationID, commonProperties: common))
        }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testValidTokenTrimsWhitespaceAndDefersStartup() async {
        var starts = 0
        let recorder = RecordingAnalyticsTransport()
        let factory = KikiAnalyticsTransportFactory.postHog(.init(token: " phc_test123 \n")) { config, id in
            starts += 1
            XCTAssertEqual(config.projectToken, "phc_test123")
            XCTAssertEqual(id, self.installationID)
            return recorder
        }
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(factory.make(installationID: installationID, commonProperties: common) === recorder)
        XCTAssertEqual(starts, 1)
    }

    func testConfigurationFromInfoPlistAndMissingToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = ["CFBundleIdentifier": "test.kikianalytics", "KikiPostHogProjectToken": "phc_test123",
                          "KikiPostHogHost": "https://eu.i.posthog.com"]
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(path: directory.path))
        let configuration = KikiPostHogConfiguration.fromInfoPlist(bundle: bundle)
        XCTAssertEqual(configuration.token, "phc_test123")
        XCTAssertEqual(configuration.host, "https://eu.i.posthog.com")
        XCTAssertTrue(configuration.hasValidToken)
        XCTAssertFalse(KikiPostHogConfiguration.fromInfoPlist(bundle: Bundle(for: Self.self)).hasValidToken)
    }

    func testEveryMacOSLockedConfigurationValueWithoutSetup() async {
        let config = makePostHogConfig(.init(token: "phc_test", host: "https://eu.i.posthog.com"),
                                      installationID: installationID, commonProperties: common)
        XCTAssertEqual(config.projectToken, "phc_test")
        XCTAssertEqual(config.host.absoluteString, "https://eu.i.posthog.com")
        XCTAssertTrue(config.captureApplicationLifecycleEvents)
        XCTAssertFalse(config.captureScreenViews)
        XCTAssertFalse(config.enableSwizzling)
        XCTAssertFalse(config.capturePushNotificationSubscriptions)
        XCTAssertFalse(config.capturePushNotificationOpened)
        XCTAssertFalse(config.errorTrackingConfig.autoCapture)
        XCTAssertFalse(config.errorTrackingConfig.exceptionSteps.enabled)
        XCTAssertEqual(config.personProfiles, .never)
        XCTAssertFalse(config.setDefaultPersonProperties)
        XCTAssertFalse(config.preloadFeatureFlags)
        XCTAssertFalse(config.sendFeatureFlagEvent)
        XCTAssertTrue(config.disableGeoIp)
        XCTAssertEqual(config.flushAt, 20)
        XCTAssertEqual(config.flushIntervalSeconds, 900)
        XCTAssertFalse(config.optOut)
        XCTAssertFalse(config.persistOptOut)
        XCTAssertEqual(config.getAnonymousId(UUID()), installationID)
        XCTAssertNil(config.storageManager) // Building config must not touch SDK identity storage.
        XCTAssertNil(config.bootstrap)
        // Element capture/replay do not compile on macOS; surveys is unavailable.
    }

    func testBeforeSendDropsUnknownAndKeepsEveryAllowlistedSDKKey() async throws {
        let config = makePostHogConfig(.init(token: "phc_test"), installationID: installationID, commonProperties: common)
        var properties: [String: Any] = Dictionary(uniqueKeysWithValues: PostHogEventFilter.sdkKeys.map { ($0, "sdk" as Any) })
        properties["unknown"] = "secret"
        properties["$unknown"] = "secret"
        properties["$set"] = ["email": "secret"]
        let event = PostHogEvent(event: "Application Opened", distinctId: "old-sdk-id", properties: properties)
        let filtered = try XCTUnwrap(config.runBeforeSend(event))
        XCTAssertNil(filtered.properties["unknown"])
        XCTAssertNil(filtered.properties["$unknown"])
        XCTAssertNil(filtered.properties["$set"])
        for key in PostHogEventFilter.sdkKeys { XCTAssertNotNil(filtered.properties[key], key) }
        for key in PostHogEventFilter.commonKeys { XCTAssertNotNil(filtered.properties[key], key) }
        XCTAssertEqual(filtered.properties["$geoip_disable"] as? Bool, true)
        XCTAssertEqual(filtered.properties["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(filtered.properties["$is_identified"] as? Bool, false)
        XCTAssertEqual(filtered.distinctId, installationID.uuidString)
    }

    func testDeclaredKeysArePerCaptureAndMarkerIsRemoved() async throws {
        let config = makePostHogConfig(.init(token: "phc_test"), installationID: installationID, commonProperties: common)
        let one = PostHogEvent(event: "test performed", distinctId: "id", properties: [
            "count": 3, "unknown": "secret", "$unknown": true,
            PostHogEventFilter.declaredKeysProperty: ["count", "$unknown"]
        ])
        let first = try XCTUnwrap(config.runBeforeSend(one))
        XCTAssertEqual(first.properties["count"] as? Int, 3)
        XCTAssertNil(first.properties["unknown"])
        XCTAssertNil(first.properties["$unknown"])
        XCTAssertNil(first.properties[PostHogEventFilter.declaredKeysProperty])
        let two = PostHogEvent(event: "test performed", distinctId: "id", properties: ["count": 9])
        XCTAssertNil(config.runBeforeSend(two)?.properties["count"])
    }

    func testLifecycleAllowsOnlySDKLifecycleAndCommonPropertiesEvenWithMarker() async {
        let config = makePostHogConfig(.init(token: "phc_test"), installationID: installationID, commonProperties: common)
        for name in PostHogEventFilter.lifecycleNames {
            let event = PostHogEvent(event: name, distinctId: "id", properties: [
                "version": "1", "build": 1, "previous_version": "0", "from_background": true,
                "app_context": "secret", PostHogEventFilter.declaredKeysProperty: ["app_context"], "$locale": "en"
            ])
            let result = config.runBeforeSend(event)!
            XCTAssertEqual(Set(result.properties.keys), PostHogEventFilter.commonKeys.union([
                "$locale", "$geoip_disable", "$process_person_profile", "$is_identified",
                "version", "build", "previous_version", "from_background"
            ]))
        }
    }

    func testTransportUsesExplicitDistinctIDAndDoesNotSetPersonProperties() async {
        let spy = SDKSpy()
        let transport = KikiPostHogTransport(sdk: spy)
        transport.send(name: "test performed", distinctID: installationID.uuidString, properties: ["count": 2])
        XCTAssertEqual(spy.name, "test performed")
        XCTAssertEqual(spy.distinctID, installationID.uuidString)
        XCTAssertEqual(spy.properties?["count"] as? Int, 2)
        XCTAssertEqual(spy.properties?[PostHogEventFilter.declaredKeysProperty] as? [String], ["count"])
        XCTAssertNil(spy.personProperties)
        XCTAssertNil(spy.personPropertiesOnce)
        XCTAssertNil(spy.groups)
        transport.flush()
        transport.setOptedOut(true)
        transport.setOptedOut(false)
        XCTAssertEqual(spy.flushCalls, 1)
        XCTAssertEqual(spy.optOutCalls, [true, false])
    }

    func testCoreAdapterAndSDKFilterTogetherWithoutSetup() async throws {
        struct Event: KikiAnalyticsEvent {
            var name: String { "test performed" }
            var properties: KikiAnalyticsProperties { ["count": .int(2)] }
        }
        let suite = "KikiPostHogTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let spy = SDKSpy()
        let factory = KikiAnalyticsTransportFactory.postHog(.init(token: "phc_test")) { config, _ in
            spy.config = config
            return KikiPostHogTransport(sdk: spy)
        }
        let kit = KikiAnalytics(app: .init(id: "test", channel: .direct, storagePrefix: "test.analytics"),
                                transport: factory, defaults: defaults)
        kit.track(Event())
        let captured = try XCTUnwrap(spy.filtered)
        XCTAssertEqual(captured.event, "test performed")
        XCTAssertEqual(captured.distinctId, kit.installationID.uuidString)
        XCTAssertEqual(captured.properties["app_id"] as? String, "test")
        XCTAssertEqual(captured.properties["count"] as? Int, 2)
        XCTAssertEqual(captured.properties["$os_name"] as? String, "macOS")
        XCTAssertNil(captured.properties["sdk_unexpected"])
        XCTAssertNil(captured.properties[PostHogEventFilter.declaredKeysProperty])
    }
}

private final class SDKSpy: PostHogCapturing {
    var config: PostHogConfig?
    var name: String?
    var distinctID: String?
    var properties: [String: Any]?
    var personProperties: [String: Any]?
    var personPropertiesOnce: [String: Any]?
    var groups: [String: String]?
    var filtered: PostHogEvent?
    var flushCalls = 0
    var optOutCalls: [Bool] = []

    func capture(_ event: String, distinctId: String?, properties: [String: Any]?,
                 userProperties: [String: Any]?, userPropertiesSetOnce: [String: Any]?, groups: [String: String]?) {
        name = event
        distinctID = distinctId
        self.properties = properties
        personProperties = userProperties
        personPropertiesOnce = userPropertiesSetOnce
        self.groups = groups
        var enriched = properties ?? [:]
        enriched["$os_name"] = "macOS"
        enriched["sdk_unexpected"] = "secret"
        filtered = config?.runBeforeSend(PostHogEvent(event: event, distinctId: distinctId ?? "", properties: enriched))
    }

    func flush() { flushCalls += 1 }
    func optIn() { optOutCalls.append(false) }
    func optOut() { optOutCalls.append(true) }
}
