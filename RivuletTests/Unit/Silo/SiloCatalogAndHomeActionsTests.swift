import XCTest
@testable import Rivulet

@MainActor
final class SiloCatalogAndHomeActionsTests: XCTestCase {
    func testGenericDownloadPermissionsRefuseSiloWithoutPlanningPlayback() async throws {
        let server = SiloAuthTestServer()
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a",
                                transport: server.transport)
        let provider: any MediaProvider = SiloProvider(
            serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client)
        var permissions = DownloadPermissions()
        await permissions.ask([provider])
        XCTAssertTrue(permissions.answered.contains(provider.id))
        XCTAssertFalse(permissions.allowed.contains(provider.id))
        do {
            _ = try await provider.downloadSource(
                for: MediaItemRef(providerID: provider.id, itemID: "movie:one"), sourceID: nil)
            XCTFail("Silo must not offer a playback plan as an offline download.")
        } catch let error as MediaProviderError {
            guard case .backendSpecific = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requests = await server.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testGenericHubPagingUsesNativeKeyInsteadOfDisplayIdentifier() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/library/library-a/layout", [.init(body: #"{"sections":[]}"#)])
        await server.respond("GET", "/api/v2/catalog", [.init(body:
            #"{"items":[],"total":0,"page":{"has_more":false,"next_cursor":null}}"#)])
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a",
                                transport: server.transport)
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client)
        let key = try SiloHubRoute(scope: "library", sectionId: "recent", libraryId: "library-a").identifier()
        let hub = MediaHub(id: "\(provider.id)|display-row", providerID: provider.id, title: "Recent",
                           style: .shelf, items: [], pagingKey: key)
        _ = try await provider.hubPage(hub, page: Page(offset: 20, limit: 20, cursor: "opaque+cursor"))
        let requests = await server.requests()
        let request = try XCTUnwrap(requests.last)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "section_id" }?.value, "recent")
        XCTAssertEqual(query.first { $0.name == "library_id" }?.value, "library-a")
        XCTAssertEqual(query.first { $0.name == "cursor" }?.value, "opaque+cursor")
    }

    func testSavedFiltersAreIsolatedByAccountProfileAndLibraryAndReconciled() throws {
        let suite = "SiloCatalogAndHomeActionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SiloCatalogFilterStore(defaults: defaults)
        let selected = MediaCatalogFilter(selectedChoices: ["genre": ["Crime", "Removed"], "studio": ["Hidden"]])
        try store.save(selected, providerID: "silo:server-a:profile-a", accountID: "account-a",
                       profileID: "profile-a", libraryID: "library-a")
        XCTAssertEqual(store.load(providerID: "silo:server-a:profile-a", accountID: "account-b",
                                  profileID: "profile-a", libraryID: "library-a").selectedChoices, [:])
        XCTAssertEqual(store.load(providerID: "silo:server-a:profile-a", accountID: "account-a",
                                  profileID: "profile-a", libraryID: "library-b").selectedChoices, [:])
        let facets = [MediaCatalogFacet(id: "genre", title: "Genre", choices: [.init(id: "Crime", title: "Crime", count: nil)])]
        XCTAssertEqual(store.reconcile(selected, facets: facets).selectedChoices, ["genre": ["Crime"]])
        store.reset(providerID: "silo:server-a:profile-a", accountID: "account-a",
                    profileID: "profile-a", libraryID: "library-a")
        XCTAssertEqual(store.load(providerID: "silo:server-a:profile-a", accountID: "account-a",
                                  profileID: "profile-a", libraryID: "library-a").selectedChoices, [:])
    }

    func testHomeAnchorsRequireTheNativeRailFields() throws {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a")
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client)
        func card(_ json: String) throws -> SiloItem {
            try SiloJSON.decoder().decode(SiloItem.self, from: Data(json.utf8))
        }
        let movie = try card(#"{"content_id":"movie:one","title":"One","progress_updated_at":"2026-01-02T03:04:05.000Z","position_seconds":120}"#)
        XCTAssertEqual(provider.dismissalMetadata(for: movie, rail: .continueWatching)?.progressUpdatedAt,
                       "2026-01-02T03:04:05.000Z")
        XCTAssertNil(provider.dismissalMetadata(for: movie, rail: .nextUp))
        let episode = try card(#"{"content_id":"episode:one","title":"Episode","series_id":"series:one"}"#)
        XCTAssertEqual(provider.dismissalMetadata(for: episode, rail: .nextUp)?.seriesID, "series:one")
        XCTAssertNil(provider.dismissalMetadata(for: episode, rail: .continueWatching))
        XCTAssertNil(movie.userData)
        XCTAssertEqual(movie.positionSeconds, 120)
    }

    func testHomeDismissalActionKeepsResumeAndRejectsForeignAnchor() throws {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a")
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client)
        let card = try SiloJSON.decoder().decode(SiloItem.self, from: Data(#"{"content_id":"episode:one","type":"episode","title":"One","series_id":"series:one","progress_updated_at":"2026-01-02T03:04:05.000Z","position_seconds":120}"#.utf8))
        var item = SiloMediaMapper.item(card, providerID: provider.id, baseURL: client.baseURL)
        XCTAssertNil(item.dismissalAction())
        item.dismissalMetadata = provider.dismissalMetadata(for: card, rail: .continueWatching)
        let action = try XCTUnwrap(item.dismissalAction())
        XCTAssertEqual(action.item.itemID, "episode:one")
        XCTAssertEqual(action.progressUpdatedAt, "2026-01-02T03:04:05.000Z")
        XCTAssertEqual(action.seriesID, "series:one")
        XCTAssertEqual(item.userState.viewOffset, 120)
        item.dismissalMetadata = MediaItemDismissalMetadata(rail: .continueWatching, contentID: "movie:other",
            progressUpdatedAt: "2026-01-02T03:04:05.000Z", seriesID: nil,
            providerIdentity: provider.id, authorityRevision: provider.authorityRevision)
        XCTAssertNil(item.dismissalAction())
    }

    func testCatalogContinuationRetainsOpaqueCursor() throws {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a")
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client)
        let page = try provider.nextPage(SiloPageInfo(hasMore: true, nextCursor: "opaque+cursor/one"), offset: 25, limit: 25)
        XCTAssertEqual(page?.cursor, "opaque+cursor/one")
        XCTAssertEqual(page?.offset, 25)
        XCTAssertEqual(page?.limit, 25)
        XCTAssertNil(try provider.nextPage(SiloPageInfo(hasMore: false, nextCursor: nil), offset: 25, limit: 25))
        XCTAssertThrowsError(try provider.nextPage(SiloPageInfo(hasMore: true, nextCursor: nil), offset: 25, limit: 25))
    }

    func testFilteredCatalogNextPageKeepsRulesSortAndCursor() throws {
        let group = SiloCatalogGroup(match: "any", rules: [
            SiloCatalogRule(field: "genre", op: "contains", value: .string("Crime")),
            SiloCatalogRule(field: "genre", op: "contains", value: .string("Drama"))
        ])
        let query = SiloCatalogQuery(libraryId: "library-a", type: "movie", sort: "added_at", order: "desc",
                                     groups: [group], limit: 25, cursor: "opaque+cursor/one", seek: nil)
        let params = try query.getParameters()
        let values = Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values["library_id"], "library-a")
        XCTAssertEqual(values["sort"], "-added_at")
        XCTAssertEqual(values["cursor"], "opaque+cursor/one")
        XCTAssertNil(values["seek"])
        let groups = try XCTUnwrap(values["groups"]?.data(using: .utf8))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: groups) as? [[String: Any]])
        XCTAssertEqual((decoded.first?["rules"] as? [[String: Any]])?.count, 2)
    }

    func testNativeDismissalRequiresExact204AndDoesNotReplay() async throws {
        let server = SiloAuthTestServer()
        await server.respond("PUT", "/api/v2/home/dismissals/continue_watching/movie:one", [
            .init(status: 200), .init(status: 204, body: "")
        ])
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a", transport: server.transport)
        do {
            try await client.put("home/dismissals/continue_watching/movie:one",
                body: ["progress_updated_at": "2026-01-02T03:04:05.000Z"], expectedStatus: 204)
            XCTFail("A 200 response must not confirm a versioned dismissal")
        } catch { }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "PUT")
        XCTAssertEqual(requests.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["progress_updated_at"],
                       "2026-01-02T03:04:05.000Z")
    }

    func testAbsentAndStaleDismissalTokensNeverSendMutation() async throws {
        let server = SiloAuthTestServer()
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a", transport: server.transport)
        let provider = SiloProvider(serverID: "server-a", displayName: "Synthetic", profileID: "profile-a", client: client,
                                    authorityRevision: 7)
        let ref = MediaItemRef(providerID: provider.id, itemID: "movie:one")
        for action in [
            MediaDismissal(item: ref, rail: .continueWatching, providerIdentity: provider.id,
                           authorityRevision: 7),
            MediaDismissal(item: ref, rail: .continueWatching, providerIdentity: provider.id,
                           progressUpdatedAt: "2026-01-02T03:04:05.000Z", authorityRevision: 6),
            MediaDismissal(item: ref, rail: .nextUp, providerIdentity: provider.id,
                           authorityRevision: 7)
        ] {
            do { try await provider.dismiss(action); XCTFail("Missing or stale anchor was accepted") }
            catch { }
        }
        let requests = await server.requests()
        XCTAssertEqual(requests.count, 0)
    }
}
