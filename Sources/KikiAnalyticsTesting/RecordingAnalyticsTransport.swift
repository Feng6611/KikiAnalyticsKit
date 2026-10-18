import Foundation
import KikiAnalytics
import XCTest

/// Intended for serial test/preview use, like the main-actor analytics entry point.
public final class RecordingAnalyticsTransport: KikiAnalyticsTransport {
    public struct Event {
        public let name: String
        public let distinctID: String
        public let properties: [String: Any]
    }

    public private(set) var events: [Event] = []
    public var names: [String] { events.map(\.name) }
    public private(set) var flushCallCount = 0
    public private(set) var optOutCalls: [Bool] = []

    public init() {}

    public func send(name: String, distinctID: String, properties: [String: Any]) {
        events.append(Event(name: name, distinctID: distinctID, properties: properties))
    }

    public func flush() { flushCallCount += 1 }
    public func setOptedOut(_ optedOut: Bool) { optOutCalls.append(optedOut) }

    /// Checks keys and recursively checks values. XCTest reports failures at the
    /// caller's source location; use this product only in tests.
    public func assertNoProperty(containing fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(events.contains { Self.contains(fragment, in: $0.properties) },
                       "Analytics property contains forbidden fragment: \(fragment)", file: file, line: line)
    }

    private static func contains(_ fragment: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { $0.key.contains(fragment) || contains(fragment, in: $0.value) }
        }
        if let array = value as? [Any] { return array.contains { contains(fragment, in: $0) } }
        return String(describing: value).contains(fragment)
    }
}
