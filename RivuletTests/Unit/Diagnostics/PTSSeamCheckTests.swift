// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Temporary: delete with ReleaseFixChecks.
final class PTSSeamCheckTests: XCTestCase {
    private let seam = "[SWHost] PTS discontinuity #1 (reader, audio): prevPts=13307.96s rawPts=13655.02s "
        + "delta=347.06s -> offset=-347.06s (timeline held continuous)"

    private func diag(lead: String, rend: String) -> String {
        "[SWDiag] clk=13310.00 dclk=1.00 rate=1.00 aLead=\(lead) aRend=\(rend) vLead=0.40 parkedPkts=3 rebuf=n"
    }

    private func run(_ lines: [String]) -> [PTSSeamCheck.Report] {
        var check = PTSSeamCheck()
        return lines.compactMap { check.ingest($0) }
    }

    func testHealthyAfterFix() throws {
        let reports = run([diag(lead: "1.00", rend: "rendering/y/-"), seam]
            + Array(repeating: diag(lead: "0.80", rend: "rendering/y/-"), count: 15))
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(report.stream, "audio")
        XCTAssertEqual(report.route, "reader")
        XCTAssertEqual(report.delta, 347.06, accuracy: 0.001)
        XCTAssertEqual(report.seconds, 15)
        XCTAssertTrue(report.healthy)
    }

    /// The #611 report: the lead jumped by the splice and the renderer starved.
    func testStarvedLikeTheReport() throws {
        let report = try XCTUnwrap(run([seam]
            + Array(repeating: diag(lead: "349.00", rend: "rendering/n/-"), count: 15)).first)
        XCTAssertEqual(report.maxAudioLead, 349)
        XCTAssertEqual(report.starvedSeconds, 15)
        XCTAssertFalse(report.healthy)
    }

    func testNoReportBeforeWindowAndNoSeam() {
        XCTAssertTrue(run(Array(repeating: diag(lead: "1.00", rend: "rendering/y/-"), count: 30)).isEmpty)
        XCTAssertTrue(run([seam] + Array(repeating: diag(lead: "-", rend: "-"), count: 14)).isEmpty)
    }
}
