// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Home waits behind the hero's first image, so a failed image has to release it too.
@MainActor
final class HeroBackdropFailureTests: XCTestCase {
    func test_failedFirstImage_stillReportsReady() async throws {
        let backdrop = HeroBackdropView()
        let ready = expectation(description: "released")
        backdrop.onFirstImageLoaded = { ready.fulfill() }
        backdrop.setBackdrop(url: URL(string: "http://127.0.0.1:9/missing.jpg"))
        await fulfillment(of: [ready], timeout: 45)
    }
}
