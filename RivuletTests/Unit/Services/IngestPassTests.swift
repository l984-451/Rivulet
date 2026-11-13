// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// NPM matches `/<expiry>.<hmac>/api/<n>/envelope/`, so the pass must land before the project id.
final class IngestPassTests: XCTestCase {

    func test_dsn_putsPassBeforeProjectId() {
        XCTAssertEqual(
            IngestPass.dsn("https://abc@errors.example.com/1", pass: "1795202826.V2Mx_-9"),
            "https://abc@errors.example.com/1795202826.V2Mx_-9/1")
    }

    func test_expiry_readsLeadingSecondsAndRejectsMalformed() {
        XCTAssertEqual(IngestPass.expiry(of: "1795202826.sig"), 1_795_202_826)
        XCTAssertNil(IngestPass.expiry(of: "1795202826."))
        XCTAssertNil(IngestPass.expiry(of: "nope.sig"))
        XCTAssertNil(IngestPass.expiry(of: "1795202826"))
    }
}
