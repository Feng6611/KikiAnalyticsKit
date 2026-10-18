import Foundation

public protocol KikiAnalyticsEvent {
    var name: String { get }
    var properties: KikiAnalyticsProperties { get }
    var frequency: KikiAnalyticsFrequency { get }
}

public extension KikiAnalyticsEvent {
    var properties: KikiAnalyticsProperties { [:] }
    var frequency: KikiAnalyticsFrequency { .always }
}

public enum KikiAnalyticsFrequency: Sendable, Equatable {
    case always
    case oncePerInstall
    case oncePerLocalDay
    case oncePerSession(id: String)
}

public typealias KikiAnalyticsProperties = [String: KikiAnalyticsValue]

/// Values deliberately have no arbitrary-string initializer or literal conformance.
public struct KikiAnalyticsValue: Sendable, Equatable {
    private enum Storage: Sendable, Equatable {
        case string(String), strings([String]), int(Int), bool(Bool)
    }
    private let storage: Storage

    public static func `enum`<E: RawRepresentable>(_ value: E) -> Self where E.RawValue == String {
        Self(storage: .string(value.rawValue))
    }

    public static func enums<E: RawRepresentable>(_ values: [E]) -> Self where E.RawValue == String {
        Self(storage: .strings(values.map(\.rawValue)))
    }

    public static func int(_ value: Int) -> Self { Self(storage: .int(value)) }
    public static func bool(_ value: Bool) -> Self { Self(storage: .bool(value)) }

    /// Negative counts are treated as zero.
    public static func bucket(_ count: Int) -> Self {
        let label: String
        switch count {
        case ...0: label = "0"
        case 1...2: label = "1_2"
        case 3...9: label = "3_9"
        case 10...29: label = "10_29"
        default: label = "30_plus"
        }
        return Self(storage: .string(label))
    }

    public static func durationMs(since start: Date) -> Self {
        let ms = max(0, Date().timeIntervalSince(start) * 1_000)
        return .int(ms.isFinite && ms < Double(Int.max) ? Int(ms) : Int.max)
    }

    public static func sessionID(_ id: KikiAnalyticsSessionID) -> Self {
        Self(storage: .string(id.rawValue))
    }

    internal var transportValue: Any {
        switch storage {
        case let .string(value): return value
        case let .strings(value): return value
        case let .int(value): return value
        case let .bool(value): return value
        }
    }
}

/// Only the Kit can mint session identities. Keep one for the semantic workflow.
public struct KikiAnalyticsSessionID: Sendable, Hashable {
    public let rawValue: String
    internal init() { rawValue = UUID().uuidString }
}
