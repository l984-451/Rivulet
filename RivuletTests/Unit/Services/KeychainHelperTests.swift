// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class KeychainHelperTests: XCTestCase {
    private let service = "com.rivulet.tests.keychain"

    override func tearDown() {
        KeychainHelper.delete("a", service: service)
        KeychainHelper.delete("b", service: service)
        super.tearDown()
    }

    func testSetReplacesAndDeleteRemoves() {
        XCTAssertTrue(KeychainHelper.set("one", forKey: "a", service: service))
        XCTAssertTrue(KeychainHelper.set("two", forKey: "a", service: service))
        XCTAssertEqual(KeychainHelper.get("a", service: service), "two")
        XCTAssertTrue(KeychainHelper.delete("a", service: service))
        XCTAssertNil(KeychainHelper.get("a", service: service))
    }

    /// Services don't share items.
    func testServicesAreSeparate() {
        KeychainHelper.set("attest", forKey: "b", service: service)
        XCTAssertNil(KeychainHelper.get("b"))
        XCTAssertEqual(KeychainHelper.get("b", service: service), "attest")
    }
}
