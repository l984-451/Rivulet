import XCTest
@testable import Rivulet

@MainActor
final class RecentReadsTests: XCTestCase {
    func test_callersWithinTheLifetimeShareOneRead() async throws {
        let reads = RecentReads<Int>(lifetime: 10)
        var loads = 0
        let start = Date()
        let first = try await reads.value(for: "a", now: start) { loads += 1; return loads }
        let second = try await reads.value(for: "a", now: start.addingTimeInterval(9)) { loads += 1; return loads }
        XCTAssertEqual([first, second], [1, 1])
        XCTAssertEqual(loads, 1)
    }

    func test_anExpiredOrForgottenReadLoadsAgain() async throws {
        let reads = RecentReads<Int>(lifetime: 10)
        var loads = 0
        let start = Date()
        _ = try await reads.value(for: "a", now: start) { loads += 1; return loads }
        let later = try await reads.value(for: "a", now: start.addingTimeInterval(11)) { loads += 1; return loads }
        XCTAssertEqual(later, 2)
        reads.removeAll()
        let afterWrite = try await reads.value(for: "a", now: start.addingTimeInterval(12)) { loads += 1; return loads }
        XCTAssertEqual(afterWrite, 3)
    }

    func test_keysDoNotShare() async throws {
        let reads = RecentReads<String>(lifetime: 10)
        let a = try await reads.value(for: "a") { "A" }
        let b = try await reads.value(for: "b") { "B" }
        XCTAssertEqual([a, b], ["A", "B"])
    }

    func test_aFailedReadIsNotKept() async throws {
        struct Failure: Error {}
        let reads = RecentReads<Int>(lifetime: 10)
        do {
            _ = try await reads.value(for: "a") { throw Failure() }
            XCTFail("expected a throw")
        } catch {}
        let retry = try await reads.value(for: "a") { 7 }
        XCTAssertEqual(retry, 7)
    }

    func test_concurrentCallersShareTheInFlightRead() async throws {
        let reads = RecentReads<Int>(lifetime: 10)
        var loads = 0
        async let one = reads.value(for: "a") { loads += 1; try await Task.sleep(for: .milliseconds(30)); return 1 }
        async let two = reads.value(for: "a") { loads += 1; return 2 }
        let values = try await [one, two]
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(Set(values).count, 1)
    }
}
