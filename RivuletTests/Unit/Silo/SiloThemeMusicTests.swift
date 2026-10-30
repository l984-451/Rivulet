import XCTest
@testable import Rivulet

@MainActor
final class SiloThemeMusicTests: XCTestCase {
    private func account(profile: String, credential: UUID) -> SiloSession.Account {
        SiloSession.Account(serverURL: URL(string: "https://silo.test")!, serverID: "server-test",
                            serverName: "Test", userID: "user-test", userName: "Viewer",
                            profileID: profile, profileName: profile, credentialID: credential)
    }

    func testOptInIsIsolatedByLoginAndProfile() {
        let suite = "theme-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SiloThemeMusicPreferences(defaults: defaults)
        let login = UUID()
        let first = account(profile: "profile-a", credential: login)
        store.write(.init(enabled: true, loop: true), account: first)
        XCTAssertEqual(store.read(account: first), .init(enabled: true, loop: true))
        XCTAssertEqual(store.read(account: account(profile: "profile-b", credential: login)), .init())
        XCTAssertEqual(store.read(account: account(profile: "profile-a", credential: UUID())), .init())
    }

    func testMemoryLoaderRejectsInvalidOffsetsAndClampsValidRanges() {
        XCTAssertNil(SiloThemeMemoryLoader.bounds(requestedStart: -1, current: -1, length: 5, count: 100, toEnd: false))
        XCTAssertNil(SiloThemeMemoryLoader.bounds(requestedStart: 101, current: 101, length: 1, count: 100, toEnd: false))
        XCTAssertNil(SiloThemeMemoryLoader.bounds(requestedStart: 40, current: 39, length: 5, count: 100, toEnd: false))
        XCTAssertNil(SiloThemeMemoryLoader.bounds(requestedStart: 40, current: 46, length: 5, count: 100, toEnd: false))
        XCTAssertEqual(SiloThemeMemoryLoader.bounds(requestedStart: 95, current: 95, length: Int.max,
                                                    count: 100, toEnd: false), 95..<100)
        XCTAssertEqual(SiloThemeMemoryLoader.bounds(requestedStart: 40, current: 42, length: 5,
                                                    count: 100, toEnd: false), 42..<45)
        XCTAssertEqual(SiloThemeMemoryLoader.bounds(requestedStart: 40, current: 42, length: 1,
                                                    count: 100, toEnd: true), 42..<100)
    }

    func testCatalogResolvesInheritedOwnerAndFirstAuthorizedSong() async throws {
        let base = URL(string: "https://silo.test")!
        let client = SiloClient(baseURL: base, transport: { request in
            let body = Data(#"{"themes":{"owner_id":"series-test","items":[{"id":"theme-a","title":"Opening"},{"id":"theme-b"}]}}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let selection = try await SiloThemeMusicAPI(client: client).firstTheme(for: "episode-test")
        XCTAssertEqual(selection?.ownerID, "series-test")
        XCTAssertEqual(selection?.themeID, "theme-a")
    }

    func testForeignMediaURLDoesNotReceiveProfileAuthority() async throws {
        let client = SiloClient(baseURL: URL(string: "https://media.invalid")!,
                                token: "synthetic", profileID: "profile-test")
        let foreign = URL(string: "https://proxy.invalid/audio?token=synthetic-grant")!
        let headers = try await client.mediaHeaders(for: foreign)
        XCTAssertNil(headers["Authorization"])
        XCTAssertNil(headers["X-Profile-Id"])
    }

    func testGrantAcceptsOnlyKnownDeliveryAndKeepsSignedURLUnmodified() async throws {
        let server = SiloAuthTestServer()
        await server.respond("POST", "/api/v2/catalog/items/series-test/themes/theme-a/playback", [
            .init(body: #"{"url":"https://audio.invalid/theme?grant=synthetic","delivery":"converted"}"#),
            .init(body: #"{"url":"https://audio.invalid/theme?grant=synthetic","delivery":"future-mode"}"#)
        ])
        let client = SiloClient(baseURL: URL(string: "https://silo.test")!, profileID: "profile-a", transport: server.transport)
        let api = SiloThemeMusicAPI(client: client)
        let grant = try await api.grant(ownerID: "series-test", themeID: "theme-a")
        XCTAssertTrue(grant.converted)
        XCTAssertEqual(grant.url.absoluteString, "https://audio.invalid/theme?grant=synthetic")
        do { _ = try await api.grant(ownerID: "series-test", themeID: "theme-a"); XCTFail("Unknown delivery accepted") }
        catch SiloSignInError.invalidResponse { }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
    }
}
