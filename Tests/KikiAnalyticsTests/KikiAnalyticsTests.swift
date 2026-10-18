import XCTest
import SwiftUI
@testable import KikiAnalytics
import KikiAnalyticsTesting

private struct Event: KikiAnalyticsEvent {
    var name = "test performed"
    var properties: KikiAnalyticsProperties = [:]
    var frequency: KikiAnalyticsFrequency = .always
}

private enum Choice: String { case manual, automatic }

@MainActor
final class KikiAnalyticsTests: XCTestCase {
    private var suites: [String] = []

    private func store() -> UserDefaults {
        let suite = "KikiAnalyticsTests." + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        try await super.tearDown()
    }

    private let app = KikiAnalyticsApp(id: "test_app", channel: .appStore, storagePrefix: "test.analytics")

    private func analytics(_ recorder: RecordingAnalyticsTransport, defaults: UserDefaults,
                           clock: KikiAnalyticsClock = .system) -> KikiAnalytics {
        KikiAnalytics(app: app, transport: .custom(recorder), defaults: defaults, clock: clock)
    }

    func testCommonPropertiesAndContext() async {
        let recorder = RecordingAnalyticsTransport()
        var state = Choice.manual
        let kit = KikiAnalytics(app: app, transport: .custom(recorder), defaults: store(),
                                context: { ["state": .enum(state)] })
        state = .automatic
        kit.track(Event(properties: ["count": .int(3), "ready": .bool(true)]))
        let event = recorder.events.last!
        XCTAssertEqual(event.distinctID, kit.installationID.uuidString)
        XCTAssertEqual(event.properties["app_id"] as? String, "test_app")
        XCTAssertEqual(event.properties["distribution_channel"] as? String, "app_store")
        XCTAssertEqual(event.properties["schema_version"] as? Int, 1)
        for key in ["app_version", "build_number", "os_version", "app_locale"] {
            XCTAssertNotNil(event.properties[key], key)
        }
        XCTAssertTrue((event.properties["os_version"] as! String).range(of: #"^macOS \d+\.\d+$"#, options: .regularExpression) != nil)
        XCTAssertEqual(event.properties["state"] as? String, "automatic")
        XCTAssertEqual(event.properties["count"] as? Int, 3)
        XCTAssertEqual(event.properties["ready"] as? Bool, true)
    }

    func testInstallationAndFirstOpenDateAreStableAcrossInstances() async {
        let defaults = store()
        let one = analytics(RecordingAnalyticsTransport(), defaults: defaults)
        let two = analytics(RecordingAnalyticsTransport(), defaults: defaults)
        XCTAssertEqual(one.installationID, two.installationID)
        XCTAssertEqual(one.firstOpenDate, two.firstOpenDate)
    }

    func testStoragePrefixesIsolateIdentityAndDedupe() async {
        let defaults = store()
        let one = analytics(RecordingAnalyticsTransport(), defaults: defaults)
        let recorder = RecordingAnalyticsTransport()
        let two = KikiAnalytics(app: .init(id: "other", channel: .direct, storagePrefix: "other"),
                                transport: .custom(recorder), defaults: defaults)
        XCTAssertNotEqual(one.installationID, two.installationID)
        XCTAssertEqual(recorder.names, ["app first opened"])
    }

    func testFirstOpenedIsAutomaticOnceAndBeforeTheFirstAppEvent() async {
        let defaults = store()
        let recorder = RecordingAnalyticsTransport()
        let one = analytics(recorder, defaults: defaults)
        one.track(Event())
        let two = analytics(recorder, defaults: defaults)
        two.track(Event())
        XCTAssertEqual(recorder.names, ["app first opened", "test performed", "test performed"])
        XCTAssertEqual(recorder.events.first?.properties["first_open_kind"] as? String, "fresh_install")
    }

    func testExistingUserFirstOpenKindIsEvaluatedOnlyOnce() async {
        let defaults = store()
        let recorder = RecordingAnalyticsTransport()
        var calls = 0
        for _ in 0..<2 {
            _ = KikiAnalytics(app: app, transport: .custom(recorder), defaults: defaults,
                              isExistingUser: { calls += 1; return true })
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(recorder.names, ["app first opened"])
        XCTAssertEqual(recorder.events[0].properties["first_open_kind"] as? String, "analytics_rollout")
    }

    func testOncePerInstallPersistsAcrossRecreation() async {
        let defaults = store()
        let recorder = RecordingAnalyticsTransport()
        let event = Event(frequency: .oncePerInstall)
        let one = analytics(recorder, defaults: defaults)
        one.track(event)
        one.track(event)
        analytics(recorder, defaults: defaults).track(event)
        XCTAssertEqual(recorder.names.filter { $0 == event.name }.count, 1)
    }

    func testOncePerSessionIsPerEventAndIdentityAndPersists() async {
        let defaults = store()
        let recorder = RecordingAnalyticsTransport()
        let one = analytics(recorder, defaults: defaults)
        let session = one.newSession()
        let other = one.newSession()
        XCTAssertNotEqual(session, other)
        let event = Event(frequency: .oncePerSession(id: session.rawValue))
        one.track(event)
        one.track(event)
        one.track(Event(name: "other performed", frequency: event.frequency))
        one.track(Event(frequency: .oncePerSession(id: other.rawValue)))
        XCTAssertEqual(recorder.names, ["app first opened", "test performed", "other performed", "test performed"])
        XCTAssertNil(defaults.object(forKey: "test.analytics.oncePerSession"), "session dedupe must not grow UserDefaults")
    }

    func testOncePerLocalDayPersistsAndCrossesMidnightWithCounters() async {
        let defaults = store()
        let recorder = RecordingAnalyticsTransport()
        var now = date("2026-10-18T23:59:00Z")
        let clock = KikiAnalyticsClock(now: { now }, calendar: { self.calendar("UTC") })
        let event = Event(frequency: .oncePerLocalDay)
        analytics(recorder, defaults: defaults, clock: clock).track(event)
        analytics(recorder, defaults: defaults, clock: clock).track(event)
        now = date("2026-10-19T00:01:00Z")
        analytics(recorder, defaults: defaults, clock: clock).track(event)
        now = date("2026-10-22T12:00:00Z")
        analytics(recorder, defaults: defaults, clock: clock).track(event)
        let daily = recorder.events.filter { $0.name == event.name }
        XCTAssertEqual(daily.count, 3)
        XCTAssertEqual(daily.map { $0.properties["active_day_index"] as! Int }, [1, 2, 3])
        XCTAssertEqual(daily.map { $0.properties["days_since_first_open"] as! Int }, [0, 1, 4])
    }

    func testTimeZoneChangeUsesCivilDatesAndDoesNotRecountVisitedDay() async {
        let defaults = store()
        let recorder = RecordingAnalyticsTransport()
        let now = date("2026-10-18T20:00:00Z")
        var zone = "UTC"
        let clock = KikiAnalyticsClock(now: { now }, calendar: { self.calendar(zone) })
        let event = Event(frequency: .oncePerLocalDay)
        let kit = analytics(recorder, defaults: defaults, clock: clock)
        kit.track(event)
        zone = "America/Los_Angeles" // Still Oct 18: no second event.
        analytics(recorder, defaults: defaults, clock: clock).track(event)
        zone = "Asia/Shanghai" // Oct 19: new civil date.
        analytics(recorder, defaults: defaults, clock: clock).track(event)
        zone = "UTC" // Revisit Oct 18: no third event.
        kit.track(event)
        let daily = recorder.events.filter { $0.name == event.name }
        XCTAssertEqual(daily.count, 2)
        XCTAssertEqual(daily.map { $0.properties["active_day_index"] as! Int }, [1, 2])
    }

    func testLocalDayUsesCalendarAcrossDST() async {
        let recorder = RecordingAnalyticsTransport()
        let defaults = store()
        var now = date("2026-03-08T07:30:00Z")
        let clock = KikiAnalyticsClock(now: { now }, calendar: { self.calendar("America/New_York") })
        let kit = analytics(recorder, defaults: defaults, clock: clock)
        kit.track(Event(frequency: .oncePerLocalDay))
        now = date("2026-03-09T04:01:00Z") // Less than 24h, but next local day.
        kit.track(Event(frequency: .oncePerLocalDay))
        XCTAssertEqual(recorder.events.last?.properties["days_since_first_open"] as? Int, 1)
        XCTAssertEqual(recorder.events.last?.properties["active_day_index"] as? Int, 2)
    }

    func testDisabledAtInitDoesNotConstructTransportOrBackfillFirstOpen() async {
        let defaults = store()
        defaults.set(false, forKey: "test.analytics.enabled")
        let recorder = RecordingAnalyticsTransport()
        var builds = 0
        let kit = KikiAnalytics(app: app, transport: .init { _, _ in builds += 1; return recorder }, defaults: defaults)
        kit.track(Event(frequency: .oncePerInstall))
        kit.flush()
        XCTAssertEqual(builds, 0)
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertTrue(recorder.optOutCalls.isEmpty)
        XCTAssertEqual(recorder.flushCallCount, 0)
        kit.isEnabled = true
        kit.track(Event(frequency: .oncePerInstall))
        XCTAssertEqual(builds, 1)
        XCTAssertTrue(recorder.events.isEmpty)
        kit.track(Event(name: "new action"))
        XCTAssertEqual(recorder.names, ["new action"])
    }

    func testDisabledEventsStillAdvanceAllDedupeState() async {
        let defaults = store()
        defaults.set(false, forKey: "test.analytics.enabled")
        let recorder = RecordingAnalyticsTransport()
        let kit = analytics(recorder, defaults: defaults)
        let session = kit.newSession()
        let events = [Event(name: "install", frequency: .oncePerInstall),
                      Event(name: "daily", frequency: .oncePerLocalDay),
                      Event(name: "session", frequency: .oncePerSession(id: session.rawValue))]
        events.forEach { kit.track($0) }
        kit.isEnabled = true
        events.forEach { kit.track($0) }
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testEnablementPersistsAndCallsOptOutAndFlush() async {
        let defaults = store()
        let recorder = RecordingAnalyticsTransport()
        let kit = analytics(recorder, defaults: defaults)
        kit.flush()
        kit.isEnabled = false
        kit.flush()
        kit.track(Event())
        XCTAssertEqual(recorder.flushCallCount, 1)
        XCTAssertEqual(recorder.names, ["app first opened"])
        XCTAssertFalse(analytics(RecordingAnalyticsTransport(), defaults: defaults).isEnabled)
        kit.isEnabled = true
        kit.track(Event())
        XCTAssertEqual(recorder.optOutCalls, [true, false])
        XCTAssertEqual(recorder.names.last, "test performed")
    }

    func testNoneFactoryReturnsNoTransport() async {
        XCTAssertNil(KikiAnalyticsTransportFactory.none.make(installationID: UUID(), commonProperties: [:]))
        let kit = KikiAnalytics(app: app, transport: .none, defaults: store())
        kit.track(Event())
        kit.flush()
    }

    func testDisabledSingletonAndEnvironmentAreNoOps() async {
        let disabled = KikiAnalytics.disabled
        disabled.track(Event())
        disabled.flush()
        // Even mutation cannot enable the permanent no-op's transport or storage.
        disabled.isEnabled = true
        disabled.track(Event())
        disabled.isEnabled = false
        EnvironmentValues().kikiAnalytics.track(Event())
        _ = Text("Test").kikiAnalytics(disabled)
    }

    func testBucketBoundariesAndNegativeCounts() async {
        let counts = [-1, 0, 1, 2, 3, 9, 10, 29, 30]
        XCTAssertEqual(counts.map { KikiAnalyticsValue.bucket($0).transportValue as! String },
                       ["0", "0", "1_2", "1_2", "3_9", "3_9", "10_29", "10_29", "30_plus"])
    }

    func testSafeValueFactories() async {
        XCTAssertEqual(KikiAnalyticsValue.enum(Choice.manual).transportValue as? String, "manual")
        XCTAssertEqual(KikiAnalyticsValue.enums([Choice.manual, .automatic]).transportValue as? [String], ["manual", "automatic"])
        XCTAssertEqual(KikiAnalyticsValue.int(7), .int(7))
        XCTAssertEqual(KikiAnalyticsValue.bool(false).transportValue as? Bool, false)
        XCTAssertEqual(KikiAnalyticsValue.durationMs(since: .distantFuture), .int(0))
        let duration = KikiAnalyticsValue.durationMs(since: Date().addingTimeInterval(-1)).transportValue as! Int
        XCTAssertTrue((1_000...2_000).contains(duration))
        let session = KikiAnalytics.disabled.newSession()
        XCTAssertNotNil(UUID(uuidString: session.rawValue))
        XCTAssertEqual(KikiAnalyticsValue.sessionID(session).transportValue as? String, session.rawValue)
    }

    func testStandardVocabulary() async {
        let session = KikiAnalytics.disabled.newSession()
        let events: [KikiStandardEvent] = [
            .appFirstOpened(kind: .freshInstall), .onboardingStarted(session: session),
            .onboardingCompleted(method: Choice.manual, durationMs: 100), .valueDay(changes: 3),
            .paywallViewed(session: session, source: Choice.manual), .paywallAction(session: session, action: Choice.manual),
            .purchaseResult(session: session, result: Choice.manual)
        ]
        XCTAssertEqual(events.map(\.name), ["app first opened", "onboarding started", "onboarding completed", "value day", "paywall viewed", "paywall action", "purchase result"])
        XCTAssertEqual(events[4].frequency, .oncePerSession(id: session.rawValue))
        XCTAssertEqual(events[4].properties["source"], .enum(Choice.manual))
    }

    #if !DEBUG
    func testReservedPropertiesAreDroppedInRelease() async {
        let recorder = RecordingAnalyticsTransport()
        let kit = KikiAnalytics(app: app, transport: .custom(recorder), defaults: store(),
                                context: { ["app_id": .int(5), "$ip": .int(1), "context_ok": .bool(true)] })
        kit.track(Event(properties: ["app_id": .bool(false), "active_day_index": .int(9),
                                    "days_since_first_open": .int(8), "$os": .int(1),
                                    "__kiki_declared_keys": .int(1), "safe": .bool(true)]))
        let properties = recorder.events.last!.properties
        XCTAssertEqual(properties["app_id"] as? String, "test_app")
        for key in ["$ip", "$os", "active_day_index", "days_since_first_open", "__kiki_declared_keys"] { XCTAssertNil(properties[key]) }
        XCTAssertEqual(properties["context_ok"] as? Bool, true)
        XCTAssertEqual(properties["safe"] as? Bool, true)
    }
    #endif

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }
}
