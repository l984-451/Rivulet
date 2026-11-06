// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class SiloDiscoveryTests: XCTestCase {
    func testDiscoverUsesInlineRecommendationsAndPinsForYouWithoutExpandingSections() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/recommendations/discover", [.init(body: """
        {"items":[
          {"type":"genre_sampler","title":"Because you enjoy Adventure","kind":"genre","key":"Adventure",
           "items":[{"content_id":"movie:voyage","type":"movie","title":"The Voyage","genres":["Adventure"],"keywords":[],"status":"matched"}]},
          {"type":"popular","title":"Popular","kind":"popular","items":[]},
          {"type":"cluster","title":"FOR YOU","kind":"for-you-main",
           "items":[{"content_id":"series:orbit","type":"series","title":"Orbit","genres":[],"keywords":[],"status":"matched"}]},
          {"type":"recently_added","title":"Recently Added","kind":"recently-added",
           "items":[{"content_id":"movie:comet","type":"movie","title":"Comet","genres":[],"keywords":[],"status":"matched"}]}
        ],"page":{"has_more":false,"next_cursor":null}}
        """)])
        // The native Apple feed does not depend on these separate browse routes.
        for kind in ["genre", "popular", "for-you-main", "recently-added"] {
            await server.respond("GET", "/api/v2/recommendations/section/\(kind)", [.init(status: 503)])
        }
        let provider = provider(server)
        let result = try await provider.discoveryHubs()
        let hubs = try XCTUnwrap(result)
        XCTAssertEqual(hubs.map(\.title), ["FOR YOU", "Because you enjoy Adventure", "Recently Added"])
        XCTAssertEqual(hubs.flatMap(\.items).map(\.ref.itemID), ["series:orbit", "movie:voyage", "movie:comet"])
        XCTAssertTrue(hubs.flatMap(\.items).allSatisfy { $0.ref.providerID == provider.id })
        XCTAssertTrue(hubs.allSatisfy { !$0.canBrowse && $0.nextPage == nil })
        let requests = await server.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v2/recommendations/discover"])
    }

    func testDiscoverRejectsIncompleteNativeCollectionsInsteadOfShowingPartialRows() async throws {
        for page in [#"{"has_more":true,"next_cursor":null}"#,
                     #"{"has_more":false,"next_cursor":"opaque-next"}"#] {
            let server = SiloAuthTestServer()
            await server.respond("GET", "/api/v2/recommendations/discover", [.init(body: """
            {"items":[{"type":"cluster","title":"For You",
              "items":[{"content_id":"movie:voyage","type":"movie","title":"The Voyage","genres":[],"keywords":[],"status":"matched"}]}],"page":\(page)}
            """)])
            do {
                _ = try await provider(server).discoveryHubs()
                XCTFail("An incomplete recommendations collection must not appear as a complete feed.")
            } catch let error as MediaProviderError {
                guard case .backendSpecific = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testCompleteEmptyNativeFeedRemainsSupportedWithoutInventedRecommendations() async throws {
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/recommendations/discover", [.init(body: """
        {"items":[{"type":"popular","title":"Popular","items":[]}],
         "page":{"has_more":false,"next_cursor":""}}
        """)])
        let result = try await provider(server).discoveryHubs()
        let hubs = try XCTUnwrap(result)
        XCTAssertEqual(hubs.map(\.id), [])
    }

    func testNativeRecommendationsSurviveAnUnsupportedProviderAndAnotherServersFailureWithoutPlex() async throws {
        let registry = MediaProviderRegistry.shared
        let savedProviders = Array(registry.providers.values)
        let savedPlexID = registry.plexProvider?.id
        let auth = PlexAuthManager.shared
        let savedToken = auth.authToken
        auth.authToken = nil
        for id in registry.providers.keys { registry.unregister(providerID: id) }
        defer {
            for id in Array(registry.providers.keys) { registry.unregister(providerID: id) }
            for provider in savedProviders { registry.register(provider) }
            if let primary = savedProviders.first(where: { $0.id == savedPlexID }) { registry.register(primary) }
            auth.authToken = savedToken
        }
        let server = SiloAuthTestServer()
        await server.respond("GET", "/api/v2/recommendations/discover", [.init(body: """
        {"items":[{"type":"cluster","title":"For You","items":[
          {"content_id":"movie:voyage","type":"movie","title":"The Voyage","genres":[],"keywords":[],"status":"matched"}
        ]}]}
        """)])
        let failedServer = SiloAuthTestServer()
        await failedServer.respond("GET", "/api/v2/recommendations/discover", [.init(status: 503)])
        let identity = UUID().uuidString
        let available = provider(server, serverID: "available-\(identity)")
        let failed = provider(failedServer, serverID: "failed-\(identity)")
        let unsupported = StubMediaProvider(id: "jellyfin:unsupported-\(identity)", kind: .jellyfin)
        registry.register(available)
        registry.register(failed)
        registry.register(unsupported)

        let model = DiscoverViewModel()
        await model.load()

        XCTAssertEqual(model.nativeSupportedProviders, [available.id])
        XCTAssertEqual(Set(model.nativeErrors.keys), [failed.id])
        XCTAssertEqual(model.nativeHubs.map(\.providerID), [available.id])
        XCTAssertEqual(model.nativeHubs.flatMap(\.items).map(\.ref.itemID), ["movie:voyage"])
        XCTAssertTrue(model.sectionItems.isEmpty, "A Silo-only feed must not depend on Plex's curated sections.")
        XCTAssertFalse(model.loading)
    }

    func testNativeDiscoverPromotesLeadingRowWithoutDuplicatingCardsOrChangingCuration() {
        let rows = [
            discoverRow("for-you", title: "For You", itemIDs: ["movie:one", "series:two"]),
            discoverRow("adventure", title: "Because you enjoy Adventure", itemIDs: ["movie:three"])
        ]

        let presented = PlexHomeViewController.nativeDiscoverRows(rows)

        XCTAssertEqual(presented.map(\.id), rows.map(\.id))
        XCTAssertEqual(presented.map(\.title), rows.map(\.title))
        XCTAssertEqual(presented.map(\.style), [.hero, .shelf])
        XCTAssertEqual(presented.flatMap(\.items).map(\.ref), rows.flatMap(\.items).map(\.ref))
        XCTAssertEqual(presented.map(\.canBrowse), [false, false])
        XCTAssertTrue(presented.allSatisfy { $0.nextPage == nil })
    }

    func testNativeDiscoverPreservesExplicitHeroAndItsPosition() {
        let rows = [
            discoverRow("for-you", title: "For You", itemIDs: ["movie:one"]),
            discoverRow("featured", title: "Featured", style: .hero, itemIDs: ["movie:two"]),
            discoverRow("clips", title: "Clips", style: .clip, itemIDs: ["movie:three"])
        ]

        let presented = PlexHomeViewController.nativeDiscoverRows(rows)

        XCTAssertEqual(presented.map(\.id), rows.map(\.id))
        XCTAssertEqual(presented.map(\.style), [.shelf, .hero, .clip])
        XCTAssertEqual(presented.flatMap(\.items), rows.flatMap(\.items))
    }

    func testNativeDiscoverOmitsEmptyRowsBeforeChoosingItsLeadingHero() {
        let rows = [
            discoverRow("empty", title: "Empty", itemIDs: []),
            discoverRow("for-you", title: "For You", itemIDs: ["movie:one"])
        ]

        let presented = PlexHomeViewController.nativeDiscoverRows(rows)

        XCTAssertEqual(presented.map(\.id), ["for-you"])
        XCTAssertEqual(presented.map(\.style), [.hero])
        XCTAssertTrue(PlexHomeViewController.nativeDiscoverRows([rows[0]]).isEmpty)
    }

    func testNativeDiscoverDoesNotInventHeroArtworkOrOverrideLeadingClipStyle() {
        let noArtwork = discoverRow("for-you", title: "For You", itemIDs: ["movie:one"], hasBackdrop: false)
        let laterArtwork = discoverRow("popular", title: "Popular", itemIDs: ["movie:two"])
        let clip = discoverRow("clips", title: "Clips", style: .clip, itemIDs: ["movie:three"])

        XCTAssertEqual(PlexHomeViewController.nativeDiscoverRows([noArtwork, laterArtwork]).map(\.style), [.shelf, .shelf])
        XCTAssertEqual(PlexHomeViewController.nativeDiscoverRows([clip, laterArtwork]).map(\.style), [.clip, .shelf])
    }

    func testNativeHeroWithTMDBIdentityRendersItsOwnTitleImmediately() throws {
        let card = try SiloJSON.decoder().decode(SiloItem.self, from: Data("""
        {"content_id":"movie:voyage","type":"movie","title":"The Voyage",
         "overview":"A journey beyond the familiar.","tmdb_id":"123"}
        """.utf8))
        let item = SiloMediaMapper.item(card, providerID: "silo:discovery-server",
                                        baseURL: URL(string: "https://silo.invalid")!)
        XCTAssertEqual(item.identity, ["m:tmdb:123"])
        XCTAssertNil(item.tmdbID, "A native identity must not enter the external TMDB logo-resolution path.")
        let overlay = MediaItemHeroOverlayView(frame: CGRect(x: 0, y: 0, width: 1920, height: 880))
        overlay.configure(items: [item], initialIndex: 0, onIndexChanged: { _, _ in },
                          onPlay: { _ in }, onInfo: { _ in })
        overlay.layoutIfNeeded()

        func labels(in view: UIView) -> [UILabel] {
            (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
        }
        let title = try XCTUnwrap(labels(in: overlay).first { $0.text == "The Voyage" })
        XCTAssertGreaterThan(title.bounds.width, 0)
        XCTAssertGreaterThan(title.bounds.height, 0)
        XCTAssertTrue(labels(in: overlay).contains { $0.text == "A journey beyond the familiar." })
        var ancestor: UIView? = title
        while let view = ancestor {
            XCTAssertFalse(view.isHidden)
            XCTAssertGreaterThan(view.alpha, 0, "Native fallback metadata must not wait for an external logo lookup.")
            ancestor = view.superview
        }
    }

    private func discoverRow(_ id: String, title: String, style: MediaHub.HubStyle = .shelf,
                             itemIDs: [String], hasBackdrop: Bool = true) -> CachedHomeHub {
        let items = itemIDs.map { itemID in
            MediaItem(
                ref: MediaItemRef(providerID: "silo:discovery-server", itemID: itemID),
                kind: .movie, title: itemID, sortTitle: nil, overview: nil,
                year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
                episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                artwork: MediaArtwork(poster: nil, backdrop: hasBackdrop ? URL(string: "https://silo.invalid/backdrop.jpg") : nil,
                                      thumbnail: nil, logo: nil),
                parentArtwork: nil, grandparentArtwork: nil)
        }
        return CachedHomeHub(id: id, title: title, isContinueWatching: false, hubKey: nil,
                             hubIdentifier: id, totalSize: items.count, items: items,
                             nativeProviderID: "silo:discovery-server", providerHubID: id,
                             style: style, canBrowse: false)
    }

    private func provider(_ server: SiloAuthTestServer, serverID: String = "discovery-server") -> SiloProvider {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "discovery-profile",
                                transport: server.transport)
        return SiloProvider(serverID: serverID, displayName: "Silo", profileID: "discovery-profile", client: client)
    }
}
