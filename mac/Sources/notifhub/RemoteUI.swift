import Foundation


struct FeedUI: Codable, Hashable, Sendable {
    struct Word: Codable, Hashable, Sendable {
        var label: String? = nil
        var icon: String? = nil
        var tone: String? = nil
    }
    var copy: [String: String]? = nil
    var vocab: [String: Word]? = nil
    var order: [String]? = nil
    var limits: [String: Double]? = nil
}

enum Remote {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: FeedUI?

    static var ui: FeedUI? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    static func seconds(_ key: String, _ fallback: Double, in range: ClosedRange<Double>) -> Double {
        guard let v = ui?.limits?[key], v.isFinite else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    static func count(_ key: String, _ fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard let v = ui?.limits?[key], v.isFinite else { return fallback }
        return min(max(Int(v.rounded()), range.lowerBound), range.upperBound)
    }

    static func label(_ state: String, _ fallback: String) -> String {
        guard let s = ui?.vocab?[state]?.label, !s.isEmpty else { return fallback }
        return s
    }

    static func icon(_ state: String, _ fallback: String) -> String {
        guard let s = ui?.vocab?[state]?.icon, !s.isEmpty else { return fallback }
        return s
    }

    static func tone(_ state: String) -> String? {
        guard let s = ui?.vocab?[state]?.tone, !s.isEmpty else { return nil }
        return s
    }

    static func order(_ fallback: [String]) -> [String] {
        guard let o = ui?.order, !o.isEmpty else { return fallback }
        return o
    }
}

func T(_ key: String, _ fallback: String) -> String {
    guard let s = Remote.ui?.copy?[key], !s.isEmpty else { return fallback }
    return s
}

func T(_ key: String, _ fallback: String, _ values: [String: String]) -> String {
    Remote.fill(T(key, fallback), values)
}

extension Remote {
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = values[String(after[..<close])] {
                out += value
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        return out + rest
    }
}

struct Lenient<Wrapped: Codable>: Codable {
    var value: Wrapped?
    init(_ value: Wrapped? = nil) { self.value = value }
    init(from decoder: Decoder) throws { value = try? Wrapped(from: decoder) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value { try c.encode(value) } else { try c.encodeNil() }
    }
}

extension Lenient: Equatable where Wrapped: Equatable {}
extension Lenient: Hashable where Wrapped: Hashable {}
extension Lenient: Sendable where Wrapped: Sendable {}
