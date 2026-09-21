import Foundation
public enum HealthColor: String { case green, yellow, red, neutral }
public struct NetworkStatus: Equatable {
    public enum Source: String { case icmp, https }
    public var latency: Int?
    public var source: Source?
    public var checked: Bool
    public init(latency: Int? = nil, source: Source? = nil, checked: Bool = false) {
        self.latency = latency; self.source = source; self.checked = checked
    }
    public var title: String { latency.map { "\($0)ms" } ?? (checked ? "OFF" : "--ms") }
    public var color: HealthColor {
        guard let latency else { return checked ? .red : .neutral }
        return latency < 100 ? .green : latency <= 250 ? .yellow : .red
    }
}
public struct RecoverySchedule {
    private var recovering = false
    private var successes = 0
    public init() {}
    public mutating func interval(reachable: Bool) -> Double {
        if !reachable { recovering = true; successes = 0; return 3 }
        if recovering { successes += 1; if successes >= 3 { recovering = false } }
        return recovering ? 3 : 10
    }
}
public struct QuotaStatus: Codable, Equatable {
    public var remainingPercent: Int?
    public var resetAt: Date?
    public var updatedAt: Date?
    public var stale: Bool
    public init(remainingPercent: Int? = nil, resetAt: Date? = nil, updatedAt: Date? = nil, stale: Bool = true) {
        self.remainingPercent = remainingPercent; self.resetAt = resetAt; self.updatedAt = updatedAt; self.stale = stale
    }
    public var title: String { remainingPercent.map { "7D\($0)%" } ?? "7D--" }
    public static func parse(_ value: [String: Any], now: Date = Date()) -> QuotaStatus? {
        let buckets = value["rateLimitsByLimitId"] as? [String: Any]
        let snapshot: [String: Any]?
        if let buckets { snapshot = buckets["codex"] as? [String: Any] }
        else { snapshot = value["rateLimits"] as? [String: Any] }
        guard let snapshot, snapshot["limitId"] as? String == nil || snapshot["limitId"] as? String == "codex" else { return nil }
        for name in ["primary", "secondary"] {
            guard let window = snapshot[name] as? [String: Any],
                  (window["windowDurationMins"] as? NSNumber)?.intValue == 10080,
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite else { continue }
            return QuotaStatus(remainingPercent: Int(max(0, min(100, 100-used))), resetAt: (window["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)), updatedAt: now, stale: false)
        }
        return nil
    }
}
