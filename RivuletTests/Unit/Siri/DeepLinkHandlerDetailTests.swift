// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DeepLinkHandlerDetailTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class DeepLinkHandlerDetailTests: XCTestCase {

    // MARK: - RivuletLink: one builder, one parser

    func testEveryActionRoundTripsForEveryItemType() throws {
        // The link carries no type, so movie, episode, show and season keys all take the same path.
        let server = "https://192-168-1-140.abc123.plex.direct:32400"
        for action in [RivuletLink.Action.play, .detail] {
            for ratingKey in ["184065", "241748", "12974", "63657"] {
                for server in [server, nil] {
                    let link = RivuletLink(action, ratingKey: ratingKey, server: server)
                    let url = try XCTUnwrap(link.url)
                    XCTAssertEqual(RivuletLink(url: url), link, url.absoluteString)
                }
            }
        }
    }

    func testBuiltURLShape() {
        XCTAssertEqual(RivuletLink(.detail, ratingKey: "12345").url?.absoluteString,
                       "rivulet://detail?ratingKey=12345")
        XCTAssertEqual(RivuletLink(.play, ratingKey: "1").url?.absoluteString, "rivulet://play?ratingKey=1")
    }

    func testPathFormMatchesQueryForm() throws {
        for action in ["play", "detail"] {
            let path = try XCTUnwrap(RivuletLink(url: XCTUnwrap(URL(string: "rivulet://\(action)/1777"))))
            let query = try XCTUnwrap(RivuletLink(url: XCTUnwrap(URL(string: "rivulet://\(action)?ratingKey=1777"))))
            XCTAssertEqual(path, query)
            XCTAssertEqual(path.ratingKey, "1777")
        }
        let trailing = RivuletLink(url: URL(string: "rivulet://play/1777/")!)
        XCTAssertEqual(trailing?.ratingKey, "1777")
        let withServer = RivuletLink(url: URL(string: "rivulet://detail/5?server=abc")!)
        XCTAssertEqual(withServer, RivuletLink(.detail, ratingKey: "5", server: "abc"))
    }

    func testQueryWinsOverPath() {
        XCTAssertEqual(RivuletLink(url: URL(string: "rivulet://play/1?ratingKey=2")!)?.ratingKey, "2")
    }

    func testBadLinksAreRejected() {
        for s in ["rivulet://play", "rivulet://play/", "rivulet://play?ratingKey=", "rivulet://play/1/2",
                  "rivulet://bogus/1", "other://play/1", "rivulet:///1777"] {
            XCTAssertNil(RivuletLink(url: URL(string: s)!), s)
        }
    }

    func testServerWithReservedCharactersRoundTrips() throws {
        let link = RivuletLink(.play, ratingKey: "7", server: "https://h:32400/?a=b&c=d e")
        XCTAssertEqual(RivuletLink(url: try XCTUnwrap(link.url)), link)
    }

    func testParserRejectsWhatItCannotResolve() {
        for bad in ["http://play?ratingKey=1", "rivulet://open?ratingKey=1",
                    "rivulet://play", "rivulet://play?ratingKey=", "rivulet://detail?server=x"] {
            XCTAssertNil(RivuletLink(url: URL(string: bad)!), bad)
        }
    }

    // MARK: - Hold until ready

    private func makeHandler(token: @escaping () -> String? = { "t" },
                             fetch: @escaping (String, String) async throws -> PlexMetadata)
        -> DeepLinkHandler {
        let handler = DeepLinkHandler()
        handler.credentials = { token().map { ("http://s", $0) } }
        handler.fetch = { key, _, token in try await fetch(key, token) }
        handler.reconnect = {}
        handler.isSignedIn = { true }
        return handler
    }

    private func metadata(_ key: String) -> PlexMetadata {
        var m = PlexMetadata()
        m.ratingKey = key
        return m
    }

    func testKeyThatCouldReshapeTheServerPathIsDropped() {
        let handler = makeHandler { key, _ in self.metadata(key) }
        for key in ["../../:/scrobble?key=1", "5/children", "5%2F", "5&x=1"] {
            XCTAssertNil(handler.handle(RivuletLink(.detail, ratingKey: key)))
            XCTAssertNil(handler.heldLink, key)
        }
    }

    func testLinkBeforeShellReadyIsHeldThenDelivered() async {
        let handler = makeHandler { key, _ in self.metadata(key) }
        XCTAssertNil(handler.handle(RivuletLink(.detail, ratingKey: "5")))
        XCTAssertEqual(handler.heldLink?.ratingKey, "5")
        XCTAssertNil(handler.pendingDetail)

        handler.isShellReady = true   // didSet delivers
        XCTAssertNil(handler.heldLink)
        for _ in 0..<100 where handler.pendingDetail == nil { await Task.yield() }
        XCTAssertEqual(handler.pendingDetail?.ratingKey, "5")
        XCTAssertNil(handler.pendingPlayback)
    }

    func testLinkWithoutTokenWaitsForOne() async {
        var token: String?
        let handler = makeHandler(token: { token }) { key, _ in self.metadata(key) }
        handler.isShellReady = true
        XCTAssertNil(handler.handle(RivuletLink(.play, ratingKey: "9")))
        XCTAssertEqual(handler.heldLink?.ratingKey, "9")

        token = "t"
        await handler.deliverHeldLink()?.value
        XCTAssertEqual(handler.pendingPlayback?.ratingKey, "9")
    }

    func testNewerLinkReplacesHeldOne() async {
        let handler = makeHandler { key, _ in self.metadata(key) }
        handler.handle(RivuletLink(.play, ratingKey: "1"))
        handler.handle(RivuletLink(.detail, ratingKey: "2"))
        handler.isShellReady = true
        for _ in 0..<100 where handler.pendingDetail == nil { await Task.yield() }
        XCTAssertEqual(handler.pendingDetail?.ratingKey, "2")
        XCTAssertNil(handler.pendingPlayback)
    }

    func testProfilePromptDuringFetchHoldsLinkForTheNewProfile() async {
        var token = "old"
        var handler: DeepLinkHandler!
        var tokensUsed: [String] = []
        handler = makeHandler(token: { token }) { key, used in
            tokensUsed.append(used)
            if used == "old" { handler.isShellReady = false }   // picker came up mid-fetch
            return self.metadata(key)
        }
        handler.isShellReady = true
        await handler.handle(RivuletLink(.detail, ratingKey: "3"))?.value
        XCTAssertNil(handler.pendingDetail, "must not open under the profile being left")
        XCTAssertEqual(handler.heldLink?.ratingKey, "3")

        token = "new"
        handler.isShellReady = true
        for _ in 0..<100 where handler.pendingDetail == nil { await Task.yield() }
        XCTAssertEqual(handler.pendingDetail?.ratingKey, "3")
        XCTAssertEqual(tokensUsed, ["old", "new"])
    }

    func testProfileSwitchDuringFetchRefetchesAsTheNewProfile() async {
        // The sidebar switcher never clears isShellReady, so only the token shows the change.
        var token = "old"
        var tokensUsed: [String] = []
        let handler = makeHandler(token: { token }) { key, used in
            tokensUsed.append(used)
            if used == "old" { token = "new" }
            return self.metadata(used == "old" ? "stale" : key)
        }
        handler.isShellReady = true
        await handler.handle(RivuletLink(.detail, ratingKey: "3"))?.value
        for _ in 0..<100 where handler.pendingDetail == nil { await Task.yield() }
        XCTAssertEqual(handler.pendingDetail?.ratingKey, "3", "must not publish the previous profile's result")
        XCTAssertEqual(tokensUsed, ["old", "new"])
    }

    func testLinkWhileSignedOutIsNotHeld() async {
        var token: String?
        let handler = makeHandler(token: { token }) { key, _ in self.metadata(key) }
        handler.isSignedIn = { false }
        XCTAssertNil(handler.handle(RivuletLink(.play, ratingKey: "6")))
        XCTAssertNil(handler.heldLink)

        token = "t"   // signed in later
        handler.isShellReady = true
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(handler.pendingPlayback)
        XCTAssertNil(handler.pendingDetail)
    }

    func testSignOutDropsTheHeldLink() async {
        let handler = makeHandler { key, _ in self.metadata(key) }
        handler.handle(RivuletLink(.play, ratingKey: "8"))   // held behind the profile gate
        handler.dropHeldLink()
        handler.isShellReady = true
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(handler.pendingPlayback)
    }

    func testFailedFetchReconnectsAndRetriesOnce() async {
        var attempts = 0
        var reconnects = 0
        let handler = makeHandler { key, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.cannotConnectToHost) }
            return self.metadata(key)
        }
        handler.reconnect = { reconnects += 1 }
        handler.isShellReady = true
        await handler.handle(RivuletLink(.play, ratingKey: "4"))?.value
        XCTAssertEqual(reconnects, 1)
        XCTAssertEqual(handler.pendingPlayback?.ratingKey, "4")
    }

    func testFetchThatKeepsFailingDropsTheLink() async {
        var attempts = 0
        let handler = makeHandler { _, _ in
            attempts += 1
            throw URLError(.cannotConnectToHost)
        }
        handler.isShellReady = true
        await handler.handle(RivuletLink(.play, ratingKey: "4"))?.value
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(handler.pendingPlayback)
        XCTAssertNil(handler.heldLink)
    }
}
