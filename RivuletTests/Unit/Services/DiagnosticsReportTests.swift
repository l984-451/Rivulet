// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class DiagnosticsReportTests: XCTestCase {
    /// The attachment is dropped when the report holds anything JSONSerialization rejects.
    func test_collect_isValidJSON() {
        let sections = DiagnosticsReport.collect(window: nil)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(sections))
        XCTAssertNotNil(sections["top_shelf"] as? [String: Any])
    }

    /// Keeps the head and tail, marks the gap, and folds a repeated message into a count.
    func test_logBucket_headTailAndRepeats() {
        var bucket = LogBucket(head: 2, tail: 2)
        for i in 1...6 { bucket.add("t\(i) line \(i)") }
        bucket.add("t7 line 6")
        bucket.add("t8 line 6")
        XCTAssertEqual(bucket.lines, ["t1 line 1", "t2 line 2", "… 3 lines omitted …", "t6 line 6", "  (repeated 2x)"])
    }

    /// Server addresses reach the log as a kind, never as the address.
    func test_describeURL_hidesAddress() {
        XCTAssertEqual(DiagLog.describe(url: "https://192-168-1-2.abc.plex.direct:32400"), "https plex.direct :32400")
        XCTAssertEqual(DiagLog.describe(url: "http://192.168.1.140:32400"), "http lan ipv4 :32400")
        XCTAssertEqual(DiagLog.describe(url: "http://8.8.8.8:32400"), "http ipv4 :32400")
        XCTAssertEqual(DiagLog.describe(url: "https://media.example.com"), "https hostname")
        XCTAssertJSONValid(DiagnosticsReport.recentLogLines())
    }

    private func XCTAssertJSONValid(_ value: Any) {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(value))
    }
}
