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

    func test_redact_coversQuotedPathAndUserinfoForms() {
        let cases = [
            #"{"name":"Home","accessToken":"tok123","x":1}"#,
            #"<Device accessToken="tok123" name="Home"/>"#,
            "http://iptv.example:8080/live/me/tok123/42.ts",
            "http://me:tok123@iptv.example/list.m3u",
            "http://h/x?X-Plex-Token=tok123&a=1",
            "http://iptv.example:8080/me/tok123/42.ts",
        ]
        for text in cases {
            XCTAssertFalse(SensitiveDataRedactor.redact(text).contains("tok123"), text)
        }
        XCTAssertEqual(SensitiveDataRedactor.redact("http://h/x?X-Plex-Token=tok123&a=1"),
                       "http://h/x?X-Plex-Token=[redacted]&a=1")
        for raw in ["http://iptv.example/live/me/tok123/42.ts", "http://iptv.example:8080/me/tok123/42.m3u8"] {
            XCTAssertFalse(SensitiveDataRedactor.safeURLString(URL(string: raw)!).contains("tok123"), raw)
        }
        // Plex paths keep their shape.
        XCTAssertEqual(SensitiveDataRedactor.safeURLString(URL(string: "http://h:32400/library/metadata/42")!),
                       "http://h:32400/library/metadata/42")
        XCTAssertTrue(SensitiveDataRedactor.isSecretName("X-Plex-Token"))
        XCTAssertFalse(SensitiveDataRedactor.isSecretName("Accept"))
    }

    func test_redact_scrubsEmbySignInPassword_asAWholeKey() {
        let json = SensitiveDataRedactor.redact(#"{"Username":"bain","Pw":"hunter2"}"#)
        XCTAssertEqual(json, #"{"Username":"bain","Pw":"[redacted]"}"#)
        XCTAssertEqual(SensitiveDataRedactor.redact("http://h/Users/AuthenticateByName?Pw=hunter2&a=1"),
                       "http://h/Users/AuthenticateByName?Pw=[redacted]&a=1")
        // Words that merely end in "pw" are left alone.
        XCTAssertEqual(SensitiveDataRedactor.redact(#"{"NewPw":"keep"}"#), #"{"NewPw":"keep"}"#)
        XCTAssertEqual(SensitiveDataRedactor.redact("http://h/x?bypw=keep"), "http://h/x?bypw=keep")
    }

    func test_isSecretName_coversAnyAuthorizationHeader() {
        XCTAssertTrue(SensitiveDataRedactor.isSecretName("X-Emby-Authorization"))
        XCTAssertTrue(SensitiveDataRedactor.isSecretName("Authorization"))
        XCTAssertTrue(SensitiveDataRedactor.isSecretName("Proxy-Authorization"))
        XCTAssertFalse(SensitiveDataRedactor.isSecretName("Accept"))
    }

    func test_redactEvent_scrubsErrorContextAndMechanism() {
        let failing = "http://iptv.example/get.php?username=me&password=tok123"
        let event = Event(level: .error)
        event.context = ["user info": [NSURLErrorFailingURLStringErrorKey: failing]]
        let exception = Exception(value: "Code: -1017", type: "NSURLErrorDomain")
        let mechanism = Mechanism(type: "NSError")
        mechanism.desc = "Error Domain=NSURLErrorDomain Code=-1017 UserInfo={NSErrorFailingURLStringKey=\(failing)}"
        mechanism.data = ["NSErrorFailingURLKey": URL(string: failing)!,
                          "NSUnderlyingError": NSError(domain: "x", code: 1, userInfo: [NSURLErrorFailingURLStringErrorKey: failing])]
        exception.mechanism = mechanism
        event.exceptions = [exception]

        let redacted = SentryEventRedaction.redact(event)
        let dump = "\(redacted.context ?? [:]) \(mechanism.desc ?? "") \(mechanism.data ?? [:])"
        XCTAssertFalse(dump.contains("tok123"), dump)
    }
}
