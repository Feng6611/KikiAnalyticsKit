import Foundation

public struct KikiAnalyticsApp: Sendable {
    public enum Channel: String, Sendable { case appStore = "app_store", direct, setapp }

    public var id: String
    public var channel: Channel
    public var storagePrefix: String
    public var schemaVersion: Int

    public init(id: String, channel: Channel, storagePrefix: String, schemaVersion: Int = 1) {
        self.id = id
        self.channel = channel
        self.storagePrefix = storagePrefix
        self.schemaVersion = schemaVersion
    }
}

/// Both providers are evaluated per event, including the current time zone.
public struct KikiAnalyticsClock {
    public var now: () -> Date
    public var calendar: () -> Calendar

    public init(now: @escaping () -> Date, calendar: @escaping () -> Calendar = { .current }) {
        self.now = now
        self.calendar = calendar
    }

    public static let system = Self(now: Date.init)
}

public protocol KikiAnalyticsTransport: AnyObject {
    func send(name: String, distinctID: String, properties: [String: Any])
    func flush()
    func setOptedOut(_ optedOut: Bool)
}

/// The builder is deferred until enabled. Adapters receive the installation identity
/// and the Kit-owned common properties before initializing their SDK.
public struct KikiAnalyticsTransportFactory {
    private let builder: @MainActor (UUID, [String: Any]) -> (any KikiAnalyticsTransport)?

    public init(makeTransport: @escaping @MainActor (UUID, [String: Any]) -> (any KikiAnalyticsTransport)?) {
        builder = makeTransport
    }

    public static let none = Self { _, _ in nil }

    public static func custom(_ transport: any KikiAnalyticsTransport) -> Self {
        Self { _, _ in transport }
    }

    @MainActor
    internal func make(installationID: UUID, commonProperties: [String: Any]) -> (any KikiAnalyticsTransport)? {
        builder(installationID, commonProperties)
    }
}
