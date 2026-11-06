// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyClientTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyClientTests: XCTestCase {
    private let server = FakeEmbyServer()

    private func client(base: String = "http://emby.local:8096", token: String? = "tok") -> EmbyClient {
        EmbyClient(baseURL: URL(string: base)!, token: token, transport: server.transport)
    }

    // MARK: - Authorization header

    func test_authorization_isMediaBrowserForm_withEncodedDeviceAndToken() {
        let header = client().authorization
        XCTAssertTrue(header.hasPrefix(#"MediaBrowser Client="Rivulet", Device="Apple%20TV", DeviceId=""#), header)
        XCTAssertTrue(header.contains(#"DeviceId="\#(PlexAPI.clientIdentifier)", Version=""#), header)
        XCTAssertTrue(header.hasSuffix(#", Token="tok""#), header)
        XCTAssertFalse(header.contains("'"), "Emby HTML-encodes apostrophes, so they do not round-trip")
    }

    func test_authorization_omitsTokenWhenSignedOut() {
        XCTAssertFalse(client(token: nil).authorization.contains("Token="))
    }

    func test_deviceName_isPercentEncodedOutsideUnreserved() {
        XCTAssertEqual(EmbyClient.encodedDeviceName("Living Room, TV's"), "Living%20Room%2C%20TV%27s")
        XCTAssertEqual(EmbyClient.encodedDeviceName("Apple-TV_4.K~"), "Apple-TV_4.K~")
    }

    func test_get_sendsOnlyTheAuthorizationHeader() async throws {
        server.respond("/System/Info/Public", body: EmbyLiveFixtures.publicInfo4_10_2)
        let c = client()
        let _: EmbyPublicSystemInfo = try await c.get("System/Info/Public")
        XCTAssertEqual(server.requests.first?.value(forHTTPHeaderField: "Authorization"), c.authorization)
        XCTAssertNil(server.requests.first?.value(forHTTPHeaderField: "X-Emby-Token"))
        XCTAssertEqual(server.headerProblems, [])
    }

    // MARK: - URLs

    func test_url_neverAddsOrStripsEmbyPrefix() async throws {
        let cases = [
            ("http://emby.local:8096", "/System/Info/Public"),
            ("http://emby.local:8096/", "/System/Info/Public"),
            ("http://emby.local:8096/emby", "/emby/System/Info/Public"),
            ("https://host.example/proxy/emby/", "/proxy/emby/System/Info/Public"),
            ("https://host.example/proxy", "/proxy/System/Info/Public")
        ]
        for (base, path) in cases {
            server.respond(path, body: EmbyLiveFixtures.publicInfo4_10_2)
            let _: EmbyPublicSystemInfo = try await client(base: base).get("System/Info/Public")
            XCTAssertEqual(server.requests.last?.url?.path, path, base)
        }
    }

    func test_url_toleratesLeadingSlash_andEncodesPlusAndSpaces() {
        let url = client(base: "https://h.example/emby").url("/Items", [URLQueryItem(name: "SearchTerm", value: "C++ & co")])
        XCTAssertEqual(url.absoluteString, "https://h.example/emby/Items?SearchTerm=C%2B%2B%20%26%20co")
    }

    func test_authenticatedURL_carriesApiKey_andNeverApiKeyPascalCase() {
        let url = client().authenticatedURL("Videos/12/stream", [URLQueryItem(name: "static", value: "true")])
        XCTAssertEqual(url.absoluteString, "http://emby.local:8096/Videos/12/stream?static=true&api_key=tok")
        XCTAssertFalse(url.absoluteString.contains("ApiKey"))
        XCTAssertFalse(client(token: nil).authenticatedURL("Videos/12/stream").absoluteString.contains("api_key"))
    }

    func test_imageURL_neverCarriesAToken() {
        let url = client().url("Items/857/Images/Primary", [URLQueryItem(name: "tag", value: "abc")])
        XCTAssertEqual(url.absoluteString, "http://emby.local:8096/Items/857/Images/Primary?tag=abc")
    }

    func test_resolve_joinsServerRelativeURLsAsStrings_keepingAProxySubpath() {
        let relative = "/videos/857/master.m3u8?MediaSourceId=mediasource_857&api_key=tok"
        XCTAssertEqual(client().resolve(relative)?.absoluteString, "http://emby.local:8096\(relative)")
        XCTAssertEqual(client(base: "https://h.example/proxy/").resolve(relative)?.absoluteString,
                       "https://h.example/proxy\(relative)")
    }

    // MARK: - Status mapping

    private func assertThrows(_ expected: MediaProviderError, status: Int, body: String = "") async {
        server.reset()
        server.respond("/Users/u/Views", status: status, body: body, contentType: "text/plain")
        do {
            let _: EmbyPublicSystemInfo = try await client().get("Users/u/Views")
            XCTFail("expected a throw for \(status)")
        } catch let error as MediaProviderError {
            XCTAssertEqual(String(describing: error), String(describing: expected), "\(status)")
        } catch { XCTFail("\(status) -> \(error)") }
    }

    func test_401and403_mapToUnauthorized_404ToNotFound() async {
        await assertThrows(.unauthorized, status: 401, body: EmbyLiveFixtures.invalidTokenBody)
        await assertThrows(.unauthorized, status: 403)
        await assertThrows(.notFound, status: 404, body: "The requested item could not be found.")
    }

    func test_otherStatuses_keepTheTextBody_withEntitiesDecoded() async {
        await assertThrows(.backendSpecific(underlying: "Emby HTTP 500 on Users/u/Views: \(EmbyLiveFixtures.sqliteBody)"),
                           status: 500, body: EmbyLiveFixtures.sqliteBody)
        await assertThrows(.backendSpecific(underlying: "Emby HTTP 500 on Users/u/Views: \(EmbyLiveFixtures.htmlEscapedBody4_8_11Plain)"),
                           status: 500, body: EmbyLiveFixtures.htmlEscapedBody4_8_11)
    }

    func test_plainText_decodesEntitiesOnce() {
        XCTAssertEqual(EmbyClient.plainText(Data("a &#39;b&#39; &#x27;c&#x27; &quot;d&quot; &lt;e&gt; &amp;#39; &amp; f".utf8)),
                       "a 'b' 'c' \"d\" <e> &#39; & f")
    }

    func test_networkFailure_mapsToUnreachable() async {
        do {
            let _: EmbyPublicSystemInfo = try await client().get("Users/u/Views")   // no route
            XCTFail("expected a throw")
        } catch MediaProviderError.unreachable {
        } catch { XCTFail("got \(error)") }
    }

    func test_certificateFailure_mapsToUntrustedCertificate() async {
        let failing = EmbyClient(baseURL: URL(string: "https://emby.local")!, token: nil,
                                 transport: { _ in throw URLError(.serverCertificateUntrusted) })
        do {
            let _: EmbyPublicSystemInfo = try await failing.get("System/Info/Public")
            XCTFail("expected a throw")
        } catch EmbySignInError.untrustedCertificate {
        } catch { XCTFail("got \(error)") }
    }

    func test_post_acceptsEmpty204() async throws {
        server.respond("/Sessions/Logout", method: "POST", status: 204)
        try await client().post("Sessions/Logout")
        XCTAssertEqual(server.requests.first?.httpMethod, "POST")
    }

    func test_get_doesNotRetryA500() async {
        server.respond("/Users/u/Views", status: 500, body: EmbyLiveFixtures.sqliteBody)
        let _: EmbyPublicSystemInfo? = try? await client().get("Users/u/Views")
        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: - Sign-in

    private let signInPath = "/Users/AuthenticateByName"

    func test_authenticate_sendsPw_notPassword() async throws {
        server.respond(signInPath, method: "POST", body: EmbyLiveFixtures.authenticate4_10_2)
        _ = try await client(token: nil).authenticate(username: "bain", password: "")
        let body = server.jsonBody(0)
        XCTAssertEqual(body["Username"] as? String, "bain")
        XCTAssertEqual(body["Pw"] as? String, "")
        XCTAssertNil(body["Password"])
        XCTAssertEqual(server.headerProblems, [])
    }

    func test_authenticate_decodesTheRealResponse() async throws {
        server.respond(signInPath, method: "POST", body: EmbyLiveFixtures.authenticate4_10_2)
        let result = try await client(token: nil).authenticate(username: "bain", password: "pw")
        XCTAssertEqual(result.accessToken, EmbyLiveFixtures.dummyToken)
        XCTAssertEqual(result.serverId, EmbyLiveFixtures.serverID)
        XCTAssertEqual(result.user?.id?.value, EmbyLiveFixtures.userID)
        XCTAssertEqual(result.user?.policy?.isAdministrator, false)
    }

    func test_authenticate_retriesA500Once() async throws {
        server.respond(signInPath, method: "POST", replies: [
            .init(status: 500, body: EmbyLiveFixtures.sqliteBody, contentType: "text/plain"),
            .init(body: EmbyLiveFixtures.authenticate4_10_2)
        ])
        let result = try await client(token: nil).authenticate(username: "bain", password: "pw")
        XCTAssertEqual(result.accessToken, EmbyLiveFixtures.dummyToken)
        XCTAssertEqual(server.requests.count, 2)
    }

    func test_authenticate_twoFiveHundreds_fail_afterExactlyTwoRequests() async {
        server.respond(signInPath, method: "POST", status: 500, body: EmbyLiveFixtures.sqliteBody, contentType: "text/plain")
        do {
            _ = try await client(token: nil).authenticate(username: "bain", password: "pw")
            XCTFail("expected a throw")
        } catch MediaProviderError.backendSpecific {
        } catch { XCTFail("got \(error)") }
        XCTAssertEqual(server.requests.count, 2)
    }

    func test_authenticate_401and403_areNeverRetried() async {
        let cases: [(Int, String, EmbySignInError)] = [
            (401, EmbyLiveFixtures.invalidCredentialsBody, .invalidCredentials),
            (403, EmbyLiveFixtures.lockedOutBody, .lockedOut(message: EmbyLiveFixtures.lockedOutBody)),
            (403, EmbyLiveFixtures.disabledBody, .accountDisabled(message: EmbyLiveFixtures.disabledBody)),
            (403, EmbyLiveFixtures.remoteAccessBody, .notAllowed(message: EmbyLiveFixtures.remoteAccessBody))
        ]
        for (status, body, expected) in cases {
            server.reset()
            server.respond(signInPath, method: "POST", status: status, body: body, contentType: "text/plain")
            do {
                _ = try await client(token: nil).authenticate(username: "bain", password: "pw")
                XCTFail("expected a throw for \(body)")
            } catch let error as EmbySignInError {
                XCTAssertEqual(error, expected)
            } catch { XCTFail("\(body) -> \(error)") }
            XCTAssertEqual(server.requests.count, 1, body)
        }
    }

    func test_authenticate_404_isNotEmby() async {
        server.respond(signInPath, method: "POST", status: 404, body: "not found", contentType: "text/plain")
        do {
            _ = try await client(token: nil).authenticate(username: "bain", password: "pw")
            XCTFail("expected a throw")
        } catch EmbySignInError.notEmby {
        } catch { XCTFail("got \(error)") }
    }

    // MARK: - Decoding rules

    func test_integerNestedIds_doNotThrow() throws {
        struct Item: Decodable {
            let id: EmbyID?
            let studios: [EmbyNameID]?
            let genreItems: [EmbyNameID]?
            let tagItems: [EmbyNameID]?
            let collections: [EmbyNameID]?
            let providerIds: [String: String]?
        }
        let movie = try EmbyJSON.decoder().decode(Item.self, from: Data(EmbyLiveFixtures.movieDetail4_9_5.utf8))
        XCTAssertEqual(movie.id?.value, "19")
        XCTAssertEqual(movie.studios?.first?.id?.value, "1087")
        XCTAssertEqual(movie.studios?.first?.name, "Columbia Pictures")
        XCTAssertEqual(movie.genreItems?.map { $0.id?.value }, ["1084", "1085", "1086"])
        XCTAssertEqual(movie.tagItems?.count, 0)
        XCTAssertEqual(movie.providerIds?["Imdb"], "tt10548174", "dictionary keys keep their case")
        XCTAssertEqual(movie.providerIds?["Official Website"], "https://flixtor.diy/28-years-later-2025/")

        let boxed = try EmbyJSON.decoder().decode(Item.self, from: Data(EmbyLiveFixtures.movieWithCollections4_10_2.utf8))
        XCTAssertEqual(boxed.collections?.map { $0.id?.value }, ["1778", "1779"])
        XCTAssertEqual(boxed.id?.value, "856")
    }

    func test_embyID_decodesStringOrInteger_andRejectsOthers() throws {
        struct Holder: Decodable { let id: EmbyID }
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(Holder.self, from: Data(#"{"id":"857"}"#.utf8)).id.value, "857")
        XCTAssertEqual(try decoder.decode(Holder.self, from: Data(#"{"id":857}"#.utf8)).id.value, "857")
        XCTAssertEqual(try decoder.decode(Holder.self, from: Data(#"{"id":9007199254740993}"#.utf8)).id.value, "9007199254740993")
        XCTAssertThrowsError(try decoder.decode(Holder.self, from: Data(#"{"id":true}"#.utf8)))
    }

    func test_dates_parseWithAndWithoutFractions_andYearOneIsNil() {
        let withSeven = EmbyJSON.date("2026-11-04T14:03:49.1537435Z")
        let whole = EmbyJSON.date("2026-11-04T14:03:49Z")
        XCTAssertNotNil(withSeven)
        XCTAssertEqual(whole?.timeIntervalSince1970, 1_793_801_029)
        XCTAssertEqual(withSeven!.timeIntervalSince1970, 1_793_801_029.15, accuracy: 0.01)
        XCTAssertEqual(EmbyJSON.date("2025-09-16T10:41:38.0000000Z")?.timeIntervalSince1970, 1_758_019_298)
        XCTAssertNil(EmbyJSON.date("0001-01-01T00:00:00.0000000Z"))
        XCTAssertNil(EmbyJSON.date(nil))
        XCTAssertNil(EmbyJSON.date("yesterday"))
    }

    func test_viewsWithYearOneDateModified_decode() throws {
        struct Views: Decodable { let items: [View] }
        struct View: Decodable { let id: EmbyID; let dateModified: String?; let collectionType: String? }
        let views = try EmbyJSON.decoder().decode(Views.self, from: Data(EmbyLiveFixtures.views4_9_5.utf8))
        XCTAssertEqual(views.items.count, 3)
        XCTAssertTrue(views.items.allSatisfy { EmbyJSON.date($0.dateModified) == nil })
    }

    func test_ticks() {
        XCTAssertEqual(EmbyTicks.seconds(13_183_590_000), 1318.359)
        XCTAssertNil(EmbyTicks.seconds(nil))
        XCTAssertEqual(EmbyTicks.ticks(90.5), 905_000_000)
        XCTAssertEqual(EmbyTicks.ticks(.infinity), 0)
        XCTAssertEqual(EmbyTicks.ticks(.nan), 0)
        XCTAssertEqual(EmbyTicks.ticks(1e30), 0)
    }

    func test_usersAcrossVersions_decodePolicy() throws {
        let cases: [(String, Bool)] = [
            (EmbyLiveFixtures.userAdmin4_10_2, true), (EmbyLiveFixtures.userNonAdmin4_10_2, false),
            (EmbyLiveFixtures.user4_8_11, true), (EmbyLiveFixtures.user4_9_5, true)
        ]
        for (json, admin) in cases {
            let user = try EmbyJSON.decoder().decode(EmbyUser.self, from: Data(json.utf8))
            XCTAssertEqual(user.policy?.isAdministrator, admin)
            XCTAssertNotNil(user.id)
            XCTAssertNotNil(user.policy?.enableLiveTvAccess)
        }
    }
}
