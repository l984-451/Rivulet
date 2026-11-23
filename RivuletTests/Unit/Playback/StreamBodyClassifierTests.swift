// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StreamBodyClassifierTests.swift
//  RivuletTests
//
//  Classifies the non-media bytes behind AVERROR_INVALIDDATA (RIVULET-19). The
//  security tests at the bottom guard that nothing from the body, which can echo
//  a token or credentials, reaches the summary string.
//

import XCTest
@testable import Rivulet

final class StreamBodyClassifierTests: XCTestCase {
    func testProbeKeepsOnlyTheSampleWhenServerReturnsFullContent() async throws {
        let url = URL(string: "https://media.test/example")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { MockURLProtocol.reset(); session.invalidateAndCancel() }

        for (status, count) in [(200, 4096), (206, 23), (403, 0)] {
            let body = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            MockURLProtocol.mockResponses[url] = (body, response)
            let (sample, http) = try await StreamBodyProbe.sample(URLRequest(url: url), session: session)
            XCTAssertEqual(sample, body.prefix(StreamBodyClassifier.probeByteCount))
            XCTAssertEqual(http.statusCode, status)
        }
    }


    // MARK: - Helpers

    private func classify(_ string: String) -> StreamBodyClassification {
        StreamBodyClassifier.classify(Data(string.utf8))
    }

    private func classify(_ bytes: [UInt8]) -> StreamBodyClassification {
        StreamBodyClassifier.classify(Data(bytes))
    }

    // MARK: - Text bodies

    /// The leading RIVULET-19 hypothesis is an expired token yielding an HTML
    /// error page, so this is the case the whole diagnostic exists to confirm.
    func testClassifiesHTMLDoctype() {
        XCTAssertEqual(classify("<!DOCTYPE html><html><body>401</body></html>"), .html)
    }

    func testClassifiesHTMLWithoutDoctype() {
        XCTAssertEqual(classify("<html><head><title>Unauthorized</title></head></html>"), .html)
    }

    /// Servers routinely emit a leading newline before the document, which must
    /// not defeat the match.
    func testClassifiesHTMLAfterLeadingWhitespace() {
        XCTAssertEqual(classify("\n\n  <!doctype HTML>"), .html)
    }

    func testClassifiesJSONObject() {
        XCTAssertEqual(classify("{\"error\":\"unauthorized\"}"), .json)
    }

    func testClassifiesJSONArray() {
        XCTAssertEqual(classify("[{\"code\":401}]"), .json)
    }

    /// Plex answers many errors with an XML MediaContainer, which is a different
    /// bug from an HTML interstitial and must stay distinguishable.
    func testClassifiesXMLDeclaration() {
        XCTAssertEqual(classify("<?xml version=\"1.0\"?><MediaContainer size=\"0\"/>"), .xml)
    }

    func testClassifiesBareMediaContainerAsXML() {
        XCTAssertEqual(classify("<MediaContainer size=\"0\"/>"), .xml)
    }

    /// AetherEngine already hardcodes a rescue for this body, so seeing it would
    /// mean that rescue is not firing rather than that the body is a surprise.
    func testClassifiesM3U8() {
        XCTAssertEqual(classify("#EXTM3U\n#EXT-X-VERSION:3\n"), .m3u8)
    }

    // MARK: - Container signatures

    /// `ftyp` sits at offset 4, after the box size.
    func testClassifiesMP4FtypAtOffsetFour() {
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]
        XCTAssertEqual(classify(bytes), .mp4)
    }

    func testClassifiesMatroskaEBML() {
        let bytes: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00]
        XCTAssertEqual(classify(bytes), .matroska)
    }

    /// A transport stream is confirmed by a second sync byte one 188-byte packet
    /// after the first, so an arbitrary body starting with ASCII "G" is not
    /// mistaken for media.
    func testClassifiesMPEGTSWithTwoSyncBytes() {
        var bytes = [UInt8](repeating: 0x00, count: 400)
        bytes[0] = 0x47
        bytes[188] = 0x47
        XCTAssertEqual(classify(bytes), .mpegts)
    }

    func testDoesNotClassifyLoneSyncByteAsMPEGTS() {
        var bytes = [UInt8](repeating: 0x00, count: 400)
        bytes[0] = 0x47
        // No second sync byte at 188.
        XCTAssertNotEqual(classify(bytes), .mpegts)
    }

    // MARK: - Degenerate bodies

    /// A zero-length 200 would explain the open failure directly, so it gets its
    /// own classification rather than collapsing into `unknown`.
    func testClassifiesEmptyBody() {
        XCTAssertEqual(StreamBodyClassifier.classify(Data()), .empty)
    }

    func testClassifiesWhitespaceOnlyBodyAsEmpty() {
        XCTAssertEqual(classify("   \n\t  "), .empty)
    }

    func testClassifiesUnrecognisedBinaryAsBinary() {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0xFF]
        XCTAssertEqual(classify(bytes), .binary)
    }

    func testClassifiesUnrecognisedTextAsUnknown() {
        XCTAssertEqual(classify("some plain text response"), .unknown)
    }

    // MARK: - Content-Type is reduced to a fixed vocabulary

    func testKnownContentTypeIsPreserved() {
        XCTAssertEqual(StreamBodyClassifier.safeContentType("text/html"), "text/html")
    }

    /// Parameters are dropped, so a charset or boundary cannot ride along.
    func testContentTypeParametersAreStripped() {
        XCTAssertEqual(StreamBodyClassifier.safeContentType("text/html; charset=utf-8"), "text/html")
    }

    func testContentTypeIsCaseNormalised() {
        XCTAssertEqual(StreamBodyClassifier.safeContentType("Application/JSON"), "application/json")
    }

    func testMissingContentTypeIsNone() {
        XCTAssertEqual(StreamBodyClassifier.safeContentType(nil), "none")
    }

    /// The header is server-controlled and therefore untrusted. Anything off the
    /// allowlist collapses to a constant, which is what stops a malicious or
    /// merely strange server leaking data through this field.
    func testUnknownContentTypeCollapsesToOther() {
        XCTAssertEqual(
            StreamBodyClassifier.safeContentType("application/x-plex-token=SECRETVALUE"),
            "other"
        )
    }

    // MARK: - SECURITY: no credential can reach the summary

    /// The core guarantee. An error body echoing a working Plex token must not
    /// put any part of that token into the string bound for Sentry. The summary
    /// is built from the status, the allowlisted content type and the
    /// classification only, so body content cannot appear by construction.
    func testSummaryOmitsTokenPresentInBody() {
        let body = """
        <!DOCTYPE html><html><body>
        Unauthorized for https://plex.example.com/library/parts/1/file.mkv?X-Plex-Token=SUPERSECRET123
        </body></html>
        """
        let data = Data(body.utf8)
        let summary = StreamBodyClassifier.describe(
            status: 401,
            contentType: "text/html; charset=utf-8",
            classification: StreamBodyClassifier.classify(data),
            byteCount: data.count
        )

        XCTAssertFalse(summary.contains("SUPERSECRET123"), "A token in the body must never reach Sentry")
        XCTAssertFalse(summary.contains("X-Plex-Token"), "Not even the token parameter name is forwarded")
        XCTAssertFalse(summary.contains("plex.example.com"), "The origin host must not reach Sentry")
        XCTAssertEqual(summary, "http=401 type=text/html body=html bytes=\(data.count)")
    }

    /// IPTV and Xtream providers embed credentials as PATH SEGMENTS, which no
    /// `key=value` redactor can see. This is precisely why the design drops the
    /// body prefix instead of trying to sanitize it.
    func testSummaryOmitsIPTVPathCredentials() {
        let body = "{\"error\":\"expired\",\"url\":\"http://iptv.example.com/live/johndoe/hunter2/4213.ts\"}"
        let data = Data(body.utf8)
        let summary = StreamBodyClassifier.describe(
            status: 403,
            contentType: "application/json",
            classification: StreamBodyClassifier.classify(data),
            byteCount: data.count
        )

        XCTAssertFalse(summary.contains("johndoe"), "An IPTV username must never reach Sentry")
        XCTAssertFalse(summary.contains("hunter2"), "An IPTV password must never reach Sentry")
        XCTAssertFalse(summary.contains("iptv.example.com"))
        XCTAssertEqual(summary, "http=403 type=application/json body=json bytes=\(data.count)")
    }

    /// Belt and braces: whatever the body is, the summary must be drawn entirely
    /// from the fixed vocabulary. This asserts the shape directly so a future
    /// change that appends a prefix fails loudly rather than silently shipping.
    func testSummaryShapeIsFixedRegardlessOfBody() {
        let hostile = Data("<html>X-Plex-Token=LEAK password=LEAK2 /live/u/p/1.ts</html>".utf8)
        let summary = StreamBodyClassifier.describe(
            status: 200,
            contentType: "text/html",
            classification: StreamBodyClassifier.classify(hostile),
            byteCount: hostile.count
        )

        XCTAssertEqual(summary, "http=200 type=text/html body=html bytes=\(hostile.count)")
        XCTAssertFalse(summary.contains("LEAK"))
        XCTAssertFalse(summary.contains("/live/"))
    }

    /// Every classification raw value must be a plain lowercase identifier, so
    /// no classification can ever carry response-derived text.
    func testAllClassificationValuesAreConstantIdentifiers() {
        let all: [StreamBodyClassification] = [
            .html, .json, .xml, .m3u8, .mp4, .matroska, .mpegts, .binary, .empty, .unknown
        ]
        for value in all {
            XCTAssertTrue(
                value.rawValue.allSatisfy { $0.isLowercase || $0.isNumber },
                "\(value.rawValue) must be a constant identifier"
            )
        }
    }
}
