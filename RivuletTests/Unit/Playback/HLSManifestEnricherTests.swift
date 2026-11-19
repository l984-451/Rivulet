// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HLSManifestEnricherTests.swift
//  RivuletTests
//
//  Every sub-URL out of `patchMasterPlaylist` must be absolute HTTP, since nothing
//  else loads `rivulet-hls://` (RIVULET-55, RIVULET-62). The fixture is a verbatim
//  PMS 1.43.4 master playlist.
//

import XCTest
@testable import Rivulet

final class HLSManifestEnricherTests: XCTestCase {

    /// Verbatim from `/video/:/transcode/universal/start.m3u8` on PMS 1.43.4.
    private let realMaster = """
    #EXTM3U
    #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=20505000,RESOLUTION=1920x1080,FRAME-RATE=50.000000
    session/f4b53cf9-6eb5-49f3-93e2-ff81cebd2050/base/index.m3u8
    #EXT-X-I-FRAME-STREAM-INF:RESOLUTION=320x180,BANDWIDTH=1000000,URI="session/f4b53cf9-6eb5-49f3-93e2-ff81cebd2050/keyframes/index.m3u8"
    """

    private let originalURL = URL(string:
        "http://192.168.1.140:32400/video/:/transcode/universal/start.m3u8?protocol=hls&session=abc")!

    private func makeEnricher(token: String? = "TESTTOKEN") -> HLSManifestEnricher {
        var headers = ["X-Plex-Client-Identifier": "tests"]
        if let token { headers["X-Plex-Token"] = token }
        return HLSManifestEnricher(metadata: PlexMetadata(), headers: headers, originalURL: originalURL)
    }

    // MARK: - Scheme swap

    func test_enrichedURL_swapsSchemeAndKeepsEverythingElse() {
        let enriched = makeEnricher().enrichedURL(from: originalURL)
        XCTAssertEqual(enriched?.scheme, "rivulet-hls")
        XCTAssertEqual(enriched?.host, "192.168.1.140")
        XCTAssertEqual(enriched?.port, 32400)
        XCTAssertEqual(enriched?.path, "/video/:/transcode/universal/start.m3u8")
        XCTAssertEqual(enriched?.query, "protocol=hls&session=abc")
    }

    // MARK: - Rewrite to absolute

    func test_relativeVariantBecomesAbsoluteHTTPWithToken() {
        let patched = makeEnricher().patchMasterPlaylist(realMaster)
        XCTAssertTrue(patched.contains(
            "http://192.168.1.140:32400/video/:/transcode/universal/session/f4b53cf9-6eb5-49f3-93e2-ff81cebd2050/base/index.m3u8?X-Plex-Token=TESTTOKEN"
        ), "variant line must be absolute, or AVPlayer resolves it against rivulet-hls:// and cannot load it")
    }

    func test_relativeURIAttributeBecomesAbsolute() {
        let patched = makeEnricher().patchMasterPlaylist(realMaster)
        XCTAssertTrue(patched.contains(
            "URI=\"http://192.168.1.140:32400/video/:/transcode/universal/session/f4b53cf9-6eb5-49f3-93e2-ff81cebd2050/keyframes/index.m3u8?X-Plex-Token=TESTTOKEN\""
        ), "URI= attributes are fetched too and need the same rewrite")
    }

    func test_noRelativeURLSurvivesThePatch() {
        let patched = makeEnricher().patchMasterPlaylist(realMaster)
        for line in patched.components(separatedBy: "\n") where !line.hasPrefix("#") && !line.isEmpty {
            XCTAssertTrue(line.hasPrefix("http://") || line.hasPrefix("https://"),
                          "relative line would be resolved against the custom scheme: \(line)")
        }
    }

    /// The colon path segment in `/video/:/transcode/universal/` is the part most
    /// likely to be mangled by URL helpers, and mangling it makes every fetch 404.
    func test_colonPathSegmentSurvivesTheBaseURLDerivation() {
        let patched = makeEnricher().patchMasterPlaylist(realMaster)
        XCTAssertTrue(patched.contains("/video/:/transcode/universal/session/"))
        XCTAssertFalse(patched.contains("/video/transcode/"), "the ':' segment was dropped")
    }

    // MARK: - Absolute lines and missing token

    func test_alreadyAbsoluteLinesAreLeftAlone() {
        let manifest = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1
        http://other.host:32400/already/absolute.m3u8
        """
        let patched = makeEnricher().patchMasterPlaylist(manifest)
        XCTAssertTrue(patched.contains("http://other.host:32400/already/absolute.m3u8"))
        XCTAssertFalse(patched.contains("universal/http://"), "an absolute line was prefixed with the base URL")
    }

    func test_withoutATokenTheRewriteIsStillAbsolute() {
        // Segments and sub-playlists serve 200 without a token once the session
        // exists (verified on PMS 1.43.4), so a missing token must not stop the
        // rewrite: an absolute URL with no token still plays, a relative one never does.
        let patched = makeEnricher(token: nil).patchMasterPlaylist(realMaster)
        XCTAssertTrue(patched.contains(
            "http://192.168.1.140:32400/video/:/transcode/universal/session/f4b53cf9-6eb5-49f3-93e2-ff81cebd2050/base/index.m3u8"
        ))
        XCTAssertFalse(patched.contains("X-Plex-Token="))
    }
}
