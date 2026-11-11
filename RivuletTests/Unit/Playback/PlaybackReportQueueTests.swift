// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import Testing
@testable import Rivulet

@MainActor
final class PlaybackReportQueueTests: XCTestCase {
    func testTimedOutProgressReleasesQueuedStopAndWatchedInOrder() async {
        let queue = PlaybackReportQueue()
        var events: [String] = []
        let cancelled = expectation(description: "request cancelled")
        queue.enqueue {
            events.append("playing")
            do {
                try await PlaybackReportTimeout.run(for: .milliseconds(20)) {
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { cancelled.fulfill(); throw error }
                }
                XCTFail("The hung request must time out")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .timedOut)
                events.append("timeout")
            }
        }
        queue.enqueue { events.append("stopped") }
        await queue.enqueue { events.append("watched") }.value
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(events, ["playing", "timeout", "stopped", "watched"])
    }

    func testRetirementWaitsForPendingProgressAndFinalPosition() async {
        let queue = PlaybackReportQueue()
        let ledger = ProviderReportLedger()
        let reporter = RecordingReporter()
        let pending = expectation(description: "progress in flight")
        var release: CheckedContinuation<Void, Never>?
        queue.enqueue {
            await ledger.report("outgoing", make: { reporter }, state: "playing", time: 40)
            await withCheckedContinuation { continuation in
                release = continuation
                pending.fulfill()
            }
        }
        await fulfillment(of: [pending], timeout: 1)
        queue.enqueue {
            await ledger.report("outgoing", make: { reporter }, state: "stopped", time: 95)
        }
        let pendingReports = queue.tail
        let retiring = expectation(description: "retirement waiting for final report")
        let retirement = Task {
            retiring.fulfill()
            await pendingReports?.value
            await ledger.stop("outgoing", make: { reporter }, fallback: 0)
        }
        await fulfillment(of: [retiring], timeout: 1)
        XCTAssertEqual(reporter.events, ["start", "progress(40.0)"])
        release?.resume()
        await retirement.value
        await ledger.report("outgoing", make: { reporter }, state: "playing", time: 96)
        XCTAssertEqual(reporter.events, ["start", "progress(40.0)", "stopped(95.0)"])
    }

    func testSuccessfulRequestDoesNotWaitForItsDeadline() async throws {
        let value = try await PlaybackReportTimeout.run(for: .seconds(60)) { 42 }
        XCTAssertEqual(value, 42)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackNetworkCancellationTests {
    private final class HangingProtocol: URLProtocol {
        static let events = AsyncStream<String>.makeStream()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { Self.events.continuation.yield("started") }
        override func stopLoading() { Self.events.continuation.yield("cancelled") }
    }

    @Test
    func deadlineCancelsAnActualURLSessionRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); HangingProtocol.events.continuation.finish() }
        let url = try #require(URL(string: "https://timeout.invalid/report"))
        do {
            _ = try await PlaybackReportTimeout.run(for: .seconds(1)) {
                try await session.data(from: url)
            }
            Issue.record("The unanswered request should time out")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        var events: [String] = []
        for await event in HangingProtocol.events.stream {
            events.append(event)
            if event == "cancelled" { break }
        }
        #expect(events == ["started", "cancelled"])
    }
}
