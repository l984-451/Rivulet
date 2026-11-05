// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ProviderReportLedgerTests: XCTestCase {

    private let reporter = RecordingReporter()
    private func ledger() -> ProviderReportLedger { ProviderReportLedger() }
    private var make: () -> any Rivulet.ProgressReporter { { [reporter] in reporter } }

    func test_firstReportStartsTheSessionOnce() async {
        let ledger = ledger()
        await ledger.report("s1", make: make, state: "playing", time: 1)
        await ledger.report("s1", make: make, state: "playing", time: 11)
        await ledger.report("s1", make: make, state: "paused", time: 12)
        XCTAssertEqual(reporter.events, ["start", "progress(1.0)", "progress(11.0)", "paused(12.0)"])
    }

    func test_openStartsTheSessionBeforeTheFirstReport() async {
        let ledger = ledger()
        await ledger.open("s1", make: make, position: 30)
        await ledger.report("s1", make: make, state: "playing", time: 31)
        XCTAssertEqual(reporter.events, ["start", "progress(31.0)"])
    }

    func test_stoppedIsSentOnce() async {
        let ledger = ledger()
        await ledger.report("s1", make: make, state: "playing", time: 1)
        await ledger.report("s1", make: make, state: "stopped", time: 5)
        await ledger.report("s1", make: make, state: "stopped", time: 6)
        XCTAssertEqual(reporter.events.filter { $0.hasPrefix("stopped") }, ["stopped(5.0)"])
    }

    func test_watchingResumesAfterTheItemEnded() async {
        let ledger = ledger()
        await ledger.report("s1", make: make, state: "playing", time: 90)
        await ledger.report("s1", make: make, state: "stopped", time: 100)
        // The viewer seeks back and plays on: the session reports again, as a fresh start.
        await ledger.report("s1", make: make, state: "playing", time: 20)
        await ledger.report("s1", make: make, state: "paused", time: 25)
        XCTAssertEqual(reporter.events, ["start", "progress(90.0)", "stopped(100.0)", "start", "progress(20.0)", "paused(25.0)"])
    }

    func test_stoppingAReplacedSessionUsesTheLastReportedPosition() async {
        let ledger = ledger()
        await ledger.report("s1", make: make, state: "playing", time: 40)
        await ledger.stop("s1", make: make, fallback: 0)
        XCTAssertEqual(reporter.events.last, "stopped(40.0)", "never 0, which would move the resume point")
    }

    func test_stoppingASessionThatNeverReportedUsesTheFallback() async {
        let ledger = ledger()
        await ledger.stop("s1", make: make, fallback: 12)
        XCTAssertEqual(reporter.events, ["stopped(12.0)"])
    }

    func test_aReplacedSessionStaysClosed() async {
        let ledger = ledger()
        await ledger.report("s1", make: make, state: "playing", time: 40)
        await ledger.stop("s1", make: make, fallback: 0)
        await ledger.report("s1", make: make, state: "playing", time: 41)
        await ledger.stop("s1", make: make, fallback: 0)
        XCTAssertEqual(reporter.events, ["start", "progress(40.0)", "stopped(40.0)"])
    }

    func test_stoppingAnEndedSessionAddsNothing() async {
        let ledger = ledger()
        await ledger.report("s1", make: make, state: "playing", time: 90)
        await ledger.report("s1", make: make, state: "stopped", time: 100)
        await ledger.stop("s1", make: make, fallback: 0)
        XCTAssertEqual(reporter.events.filter { $0.hasPrefix("stopped") }.count, 1)
    }
}
