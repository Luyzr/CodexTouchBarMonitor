import XCTest
@testable import MonitorCore
final class StatusTests: XCTestCase {
    func testNetworkBoundaries() {
        XCTAssertEqual(NetworkStatus(latency: 99).color, .green)
        XCTAssertEqual(NetworkStatus(latency: 100).color, .yellow)
        XCTAssertEqual(NetworkStatus(latency: 250).color, .yellow)
        XCTAssertEqual(NetworkStatus(latency: 251).color, .red)
        XCTAssertEqual(NetworkStatus(checked: true).title, "OFF")
        XCTAssertEqual(NetworkStatus().title, "--ms")
    }
    func testRecoveryNeedsThreeSuccessesAndResetsOnFailure() {
        var s = RecoverySchedule()
        XCTAssertEqual(s.interval(reachable: true), 10)
        XCTAssertEqual(s.interval(reachable: false), 3)
        XCTAssertEqual(s.interval(reachable: true), 3)
        XCTAssertEqual(s.interval(reachable: false), 3)
        XCTAssertEqual(s.interval(reachable: true), 3)
        XCTAssertEqual(s.interval(reachable: true), 3)
        XCTAssertEqual(s.interval(reachable: true), 10)
    }
    func testQuotaSelectsWeeklyByDuration() {
        let value: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 90, "windowDurationMins": 300], "secondary": ["usedPercent": 28, "windowDurationMins": 10080]]]
        XCTAssertEqual(QuotaStatus.parse(value)?.remainingPercent, 72)
        XCTAssertNil(QuotaStatus.parse(["rateLimits": ["secondary": ["usedPercent": 28]]]))
    }
    func testBucketPrecedenceAndClamping() {
        let legacy: [String: Any] = ["secondary": ["usedPercent": 28, "windowDurationMins": 10080]]
        XCTAssertNil(QuotaStatus.parse(["rateLimits": legacy, "rateLimitsByLimitId": ["other": legacy]]))
        XCTAssertEqual(QuotaStatus.parse(["rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 120, "windowDurationMins": 10080]]]])?.remainingPercent, 0)
        XCTAssertEqual(QuotaStatus().title, "7D--")
    }
}
