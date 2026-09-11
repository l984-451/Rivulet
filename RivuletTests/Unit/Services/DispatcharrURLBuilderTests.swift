// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DispatcharrURLBuilderTests.swift
//  RivuletTests
//
//  Covers the pure URL logic behind GitHub issue #246: capturing a Dispatcharr
//  channel profile out of a pasted endpoint instead of discarding it, encoding
//  it correctly as a path segment, and leaving the no-profile URLs byte for byte
//  as they were.
//

import XCTest
@testable import Rivulet

final class DispatcharrURLBuilderTests: XCTestCase {

    // MARK: - Backward compatibility

    /// The whole no-profile path must be unchanged. These are the exact strings
    /// every already-configured source requests today.
    func test_outputURL_withoutProfile_isUnchanged() {
        let base = URL(string: "http://192.168.1.100:9191")!
        XCTAssertEqual(
            DispatcharrService.outputURL(base: base, kind: "m3u", channelProfile: nil).absoluteString,
            "http://192.168.1.100:9191/output/m3u")
        XCTAssertEqual(
            DispatcharrService.outputURL(base: base, kind: "epg", channelProfile: nil).absoluteString,
            "http://192.168.1.100:9191/output/epg")
    }

    /// A profile that is present but blank must behave exactly as no profile, so
    /// opening the field and backing out cannot append an empty path segment.
    func test_outputURL_withBlankProfile_isUnchanged() {
        let base = URL(string: "http://host:9191")!
        for blank in ["", "   ", "\n"] {
            XCTAssertEqual(
                DispatcharrService.outputURL(base: base, kind: "m3u", channelProfile: blank).absoluteString,
                "http://host:9191/output/m3u")
        }
    }

    /// A bare base URL with no endpoint must survive untouched, which is what
    /// every existing stored source looks like.
    func test_splitEndpointPath_bareBaseURL_isUnchangedAndHasNoProfile() {
        let split = DispatcharrService.splitEndpointPath(from: "http://192.168.1.100:9191")
        XCTAssertEqual(split.baseURL, "http://192.168.1.100:9191")
        XCTAssertNil(split.channelProfile)
    }

    // MARK: - Profile appending and encoding

    func test_outputURL_withProfile_appendsPathSegment() {
        let base = URL(string: "http://host:9191")!
        XCTAssertEqual(
            DispatcharrService.outputURL(base: base, kind: "m3u", channelProfile: "Kids").absoluteString,
            "http://host:9191/output/m3u/Kids")
        XCTAssertEqual(
            DispatcharrService.outputURL(base: base, kind: "epg", channelProfile: "Kids").absoluteString,
            "http://host:9191/output/epg/Kids")
    }

    /// A space must be percent-encoded, never emitted raw. A raw space produces a
    /// URL that fails to construct and a request that never leaves the device.
    func test_outputURL_profileWithSpace_isPercentEncoded() {
        let base = URL(string: "http://host:9191")!
        let url = DispatcharrService.outputURL(base: base, kind: "m3u", channelProfile: "Kids TV")
        XCTAssertEqual(url.absoluteString, "http://host:9191/output/m3u/Kids%20TV")
        XCTAssertFalse(url.absoluteString.contains(" "))
        // The server has to receive the original name back, not the escaped one.
        XCTAssertEqual(url.lastPathComponent, "Kids TV")
    }

    func test_outputURL_profileWithAmpersand_isEncoded() {
        let base = URL(string: "http://host:9191")!
        let url = DispatcharrService.outputURL(base: base, kind: "m3u", channelProfile: "News & Sport")
        XCTAssertEqual(url.lastPathComponent, "News & Sport")
        XCTAssertFalse(url.absoluteString.contains(" "))
    }

    /// Surrounding whitespace from the tvOS keyboard must not become part of the
    /// path segment.
    func test_outputURL_profileIsTrimmed() {
        let base = URL(string: "http://host:9191")!
        XCTAssertEqual(
            DispatcharrService.outputURL(base: base, kind: "m3u", channelProfile: "  Kids  ").absoluteString,
            "http://host:9191/output/m3u/Kids")
    }

    // MARK: - Capturing a pasted profile (the issue #246 regression)

    func test_splitEndpointPath_capturesProfileFromPastedM3UURL() {
        let split = DispatcharrService.splitEndpointPath(from: "http://host:9191/output/m3u/Kids")
        XCTAssertEqual(split.baseURL, "http://host:9191")
        XCTAssertEqual(split.channelProfile, "Kids")
    }

    func test_splitEndpointPath_capturesProfileFromPastedEPGURL() {
        let split = DispatcharrService.splitEndpointPath(from: "http://host:9191/output/epg/Kids")
        XCTAssertEqual(split.baseURL, "http://host:9191")
        XCTAssertEqual(split.channelProfile, "Kids")
    }

    /// A pasted URL carries the profile percent-encoded. It must be decoded once
    /// here so the single encode at request time does not double it up.
    func test_splitEndpointPath_decodesPercentEncodedProfile() {
        let split = DispatcharrService.splitEndpointPath(from: "http://host:9191/output/m3u/Kids%20TV")
        XCTAssertEqual(split.channelProfile, "Kids TV")

        let rebuilt = DispatcharrService.outputURL(base: URL(string: split.baseURL)!, kind: "m3u",
                                                   channelProfile: split.channelProfile)
        // Round trip must be stable, not "Kids%2520TV".
        XCTAssertEqual(rebuilt.absoluteString, "http://host:9191/output/m3u/Kids%20TV")
    }

    func test_splitEndpointPath_endpointWithNoProfile_hasNoProfile() {
        for pasted in ["http://host:9191/output/m3u", "http://host:9191/output/m3u/"] {
            let split = DispatcharrService.splitEndpointPath(from: pasted)
            XCTAssertEqual(split.baseURL, "http://host:9191")
            XCTAssertNil(split.channelProfile, "unexpected profile from \(pasted)")
        }
    }

    /// A query string is not part of the profile name.
    func test_splitEndpointPath_ignoresQueryString() {
        let split = DispatcharrService.splitEndpointPath(from: "http://host:9191/output/m3u/Kids?cached=1")
        XCTAssertEqual(split.channelProfile, "Kids")
    }

    func test_splitEndpointPath_addsSchemeWhenMissing() {
        let split = DispatcharrService.splitEndpointPath(from: "host:9191/output/m3u/Kids")
        XCTAssertEqual(split.baseURL, "http://host:9191")
        XCTAssertEqual(split.channelProfile, "Kids")
    }

    // MARK: - create(from:)

    func test_create_adoptsProfileFromPastedURL() async {
        let service = DispatcharrService.create(from: "http://host:9191/output/m3u/Kids")
        let url = await service?.m3uURL.absoluteString
        XCTAssertEqual(url, "http://host:9191/output/m3u/Kids")
    }

    /// An explicitly configured profile is the last word, so editing the field
    /// always overrides whatever the pasted URL said.
    func test_create_explicitProfileOverridesPastedURL() async {
        let service = DispatcharrService.create(from: "http://host:9191/output/m3u/Kids",
                                                apiToken: nil, channelProfile: "Sports")
        let url = await service?.m3uURL.absoluteString
        XCTAssertEqual(url, "http://host:9191/output/m3u/Sports")
    }

    func test_create_withoutProfile_producesTodaysURLs() async {
        let service = DispatcharrService.create(from: "http://192.168.1.100:9191/")
        let m3u = await service?.m3uURL.absoluteString
        let epg = await service?.epgURL.absoluteString
        XCTAssertEqual(m3u, "http://192.168.1.100:9191/output/m3u")
        XCTAssertEqual(epg, "http://192.168.1.100:9191/output/epg")
    }

    // MARK: - Client identity

    /// The User-Agent must identify the app and carry nothing user-specific, so
    /// it is safe to send to any IPTV server.
    func test_userAgent_identifiesRivuletAndLeaksNothing() {
        let agent = LiveTVClientIdentity.userAgent
        XCTAssertTrue(agent.hasPrefix("Rivulet/"), "unexpected user agent: \(agent)")
        XCTAssertEqual(LiveTVClientIdentity.streamHeaders["User-Agent"], agent)
    }

    func test_parseStreamURL_extractsUserAgentAndCleansURL() {
        let raw = "http://example.com/live/ch1.m3u8|User-Agent=CustomUA%201.0&Referer=http://example.org"
        let parsed = LiveTVClientIdentity.parseStreamURL(raw)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.url.absoluteString, "http://example.com/live/ch1.m3u8")
        XCTAssertEqual(parsed?.headers["User-Agent"], "CustomUA 1.0")
        XCTAssertEqual(parsed?.headers["Referer"], "http://example.org")
    }

    func test_resolveStream_overridesUserAgentFromURL() {
        let url = URL(string: "http://example.com/live/ch1.m3u8%7CUser-Agent=CustomPlayer")!
        let resolved = LiveTVClientIdentity.resolveStream(url: url)
        XCTAssertEqual(resolved.url.absoluteString, "http://example.com/live/ch1.m3u8")
        XCTAssertEqual(resolved.headers["User-Agent"], "CustomPlayer")
    }
}
