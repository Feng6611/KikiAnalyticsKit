import Combine
import Foundation
import os

public protocol KikiAnalyticsTracking: AnyObject {
    @MainActor func track(_ event: any KikiAnalyticsEvent)
}

@MainActor
public final class KikiAnalytics: KikiAnalyticsTracking, ObservableObject {
    @Published public var isEnabled: Bool {
        didSet {
            guard defaults != nil, isEnabled != oldValue else { return }
            defaults?.set(isEnabled, forKey: key("enabled"))
            if isEnabled {
                if let transport { transport.setOptedOut(false) }
                else { makeTransport() }
            } else {
                transport?.setOptedOut(true)
            }
        }
    }

    public let installationID: UUID
    public let firstOpenDate: Date

    private let app: KikiAnalyticsApp
    private let factory: KikiAnalyticsTransportFactory
    private let defaults: UserDefaults?
    private let clock: KikiAnalyticsClock
    private let context: () -> KikiAnalyticsProperties
    private var transport: (any KikiAnalyticsTransport)?
    /// Sessions end with the process, so their dedupe state is never persisted.
    private var sentSessions: [String: Set<String>] = [:]
    #if DEBUG
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "KikiAnalytics", category: "Analytics")
    #endif

    public convenience init(
        app: KikiAnalyticsApp,
        transport: KikiAnalyticsTransportFactory,
        defaults: UserDefaults = .standard,
        clock: KikiAnalyticsClock = .system,
        isExistingUser: (() -> Bool)? = nil,
        context: @escaping () -> KikiAnalyticsProperties = { [:] }
    ) {
        self.init(app: app, transport: transport, store: defaults, clock: clock,
                  isExistingUser: isExistingUser, context: context)
    }

    private init(
        app: KikiAnalyticsApp,
        transport: KikiAnalyticsTransportFactory,
        store: UserDefaults?,
        clock: KikiAnalyticsClock,
        isExistingUser: (() -> Bool)?,
        context: @escaping () -> KikiAnalyticsProperties
    ) {
        self.app = app
        factory = transport
        defaults = store
        self.clock = clock
        self.context = context
        let prefix = app.storagePrefix + "."
        installationID = store?.string(forKey: prefix + "installationID").flatMap(UUID.init(uuidString:)) ?? UUID()
        firstOpenDate = store?.object(forKey: prefix + "firstOpenDate") as? Date ?? clock.now()
        isEnabled = store?.object(forKey: prefix + "enabled") as? Bool ?? true
        guard let store else { isEnabled = false; return }
        store.set(installationID.uuidString, forKey: prefix + "installationID")
        store.set(firstOpenDate, forKey: prefix + "firstOpenDate")
        if isEnabled { makeTransport() }
        // Persist the decision even when disabled or unconfigured: never backfill.
        if !store.bool(forKey: key("firstOpenRecorded")) {
            store.set(true, forKey: key("firstOpenRecorded"))
            track(KikiStandardEvent.appFirstOpened(kind: isExistingUser?() == true ? .analyticsRollout : .freshInstall))
        }
    }

    public func track(_ event: any KikiAnalyticsEvent) {
        guard defaults != nil else { return }
        let now = clock.now()
        let calendar = clock.calendar()
        guard let additions = advance(name: event.name, frequency: event.frequency, now: now, calendar: calendar) else { return }
        guard isEnabled else { return }
        var properties = commonProperties()
        for (key, value) in Self.allowed(context()) { properties[key] = value.transportValue }
        for (key, value) in Self.allowed(event.properties) { properties[key] = value.transportValue }
        properties.merge(additions) { _, automatic in automatic }
        #if DEBUG
        logger.debug("\(event.name, privacy: .public) \(String(describing: properties), privacy: .public)")
        #endif
        transport?.send(name: event.name, distinctID: installationID.uuidString, properties: properties)
    }

    public func newSession() -> KikiAnalyticsSessionID { KikiAnalyticsSessionID() }

    public func flush() {
        guard isEnabled else { return }
        transport?.flush()
    }

    /// No UserDefaults writes, transport construction, logging or dedupe work.
    public static let disabled = KikiAnalytics(
        app: .init(id: "disabled", channel: .direct, storagePrefix: "disabled"),
        transport: .none, store: nil, clock: .system, isExistingUser: nil, context: { [:] }
    )

    private func makeTransport() {
        transport = factory.make(installationID: installationID, commonProperties: commonProperties())
    }

    internal static let commonKeys: Set<String> = [
        "app_id", "app_version", "build_number", "distribution_channel", "os_version", "app_locale", "schema_version"
    ]

    private static func allowed(_ properties: KikiAnalyticsProperties) -> KikiAnalyticsProperties {
        properties.filter { key, _ in
            let reserved = commonKeys.contains(key) || key == "active_day_index" || key == "days_since_first_open"
                || key.hasPrefix("$") || key.hasPrefix("__kiki_")
            if reserved {
                assertionFailure("KikiAnalytics reserved property: \(key)")
            }
            return !reserved
        }
    }

    private func commonProperties() -> [String: Any] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "app_id": app.id,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "build_number": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            "distribution_channel": app.channel.rawValue,
            "os_version": "macOS \(version.majorVersion).\(version.minorVersion)",
            "app_locale": Locale.current.identifier,
            "schema_version": app.schemaVersion
        ]
    }

    private func key(_ suffix: String) -> String { app.storagePrefix + "." + suffix }

    /// Read persistent state at each call so recreated instances share dedupe decisions.
    private func advance(name: String, frequency: KikiAnalyticsFrequency, now: Date, calendar: Calendar) -> [String: Any]? {
        guard let defaults else { return nil }
        switch frequency {
        case .always: return [:]
        case .oncePerInstall:
            var names = defaults.stringArray(forKey: key("oncePerInstall")) ?? []
            guard !names.contains(name) else { return nil }
            names.append(name)
            defaults.set(names, forKey: key("oncePerInstall"))
            return [:]
        case let .oncePerSession(id):
            guard sentSessions[name, default: []].insert(id).inserted else { return nil }
            return [:]
        case .oncePerLocalDay:
            let components = calendar.dateComponents([.era, .year, .month, .day], from: now)
            // Civil date, intentionally without a zone identifier. A zone change on
            // the same local date does not create another active day.
            let day = "\(components.era ?? 0)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
            var days = defaults.dictionary(forKey: key("oncePerLocalDay")) as? [String: [String]] ?? [:]
            guard !days[name, default: []].contains(day) else { return nil }
            days[name, default: []].append(day)
            defaults.set(days, forKey: key("oncePerLocalDay"))
            let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstOpenDate),
                                                   to: calendar.startOfDay(for: now)).day ?? 0
            return ["active_day_index": days[name, default: []].count, "days_since_first_open": max(0, elapsed)]
        }
    }
}
