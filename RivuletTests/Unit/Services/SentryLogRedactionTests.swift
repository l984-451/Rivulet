// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Sentry
import XCTest
@testable import Rivulet

/// Logs bypass `beforeSend`, so this scrub is the only thing between a
/// tokenised URL and the logs product.
final class SentryLogRedactionTests: XCTestCase {

    func test_redact_stripsTokenFromBodyAndStringAttributes() {
        let log = SentryLog(
            level: .warn,
            body: "GET http://10.0.0.2:32400/hubs?X-Plex-Token=abc123",
            attributes: [
                "url": .init(string: "http://iptv.example/get.php?username=me&password=hunter2"),
                "elapsed_ms": .init(integer: 812),
            ]
        )

        let redacted = SentryEventRedaction.redact(log)

        XCTAssertFalse(redacted.body.contains("abc123"))
        let url = redacted.attributes["url"]?.value as? String ?? ""
        XCTAssertFalse(url.contains("hunter2"))
        XCTAssertFalse(url.contains("username=me"))
        XCTAssertEqual(redacted.attributes["elapsed_ms"]?.value as? Int, 812)
    }
}
