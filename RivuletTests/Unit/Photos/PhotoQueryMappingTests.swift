// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Each provider's photo request for a query, with no network.
final class PhotoQueryMappingTests: XCTestCase {
    private let page = Page(offset: 0, limit: 200)
    private let album = MediaItemRef(providerID: "p", itemID: "album")

    private func dict(_ items: [URLQueryItem]) -> [String: String] {
        Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func plex(_ query: PhotoQuery, folder: MediaItemRef? = nil) -> [String: String] {
        dict(PlexProvider.photoQueryItems(query, folder: folder, page: page))
    }

    private func jellyfin(_ query: PhotoQuery, folder: MediaItemRef? = nil) -> [String: String] {
        dict(JellyfinProvider.photoQueryItems(query, folder: folder, page: page))
    }

    private func emby(_ query: PhotoQuery, folder: MediaItemRef? = nil) -> [String: String] {
        dict(EmbyProvider.photoQueryItems(query, folder: folder, page: page))
    }

    private var autumn: ClosedRange<Date> {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2025, month: 10, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2025, month: 11, day: 30, hour: 12))!
        return start...end
    }

    // MARK: - Default is the original order

    func test_default_plex() {
        let root = plex(.default)
        XCTAssertEqual(root["sort"], "originallyAvailableAt:desc")
        XCTAssertEqual(root["type"], "13,12")
        XCTAssertEqual(root["clusterZoomLevel"], "1")
        XCTAssertEqual([root["X-Plex-Container-Start"], root["X-Plex-Container-Size"]], ["0", "200"])
        XCTAssertEqual(root["includeGeolocation"], "1")
        XCTAssertNil(root["userRating"])
        let inside = plex(.default, folder: album)
        XCTAssertEqual(inside["parent"], "album")
        XCTAssertNil(inside["clusterZoomLevel"])
    }

    func test_default_jellyfin() {
        let root = jellyfin(.default)
        XCTAssertEqual(root["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(root["sortOrder"], "Descending")
        XCTAssertEqual(root["includeItemTypes"], "Photo,Video")
        XCTAssertEqual(root["recursive"], "true")
        XCTAssertNil(root["filters"])
        XCTAssertNil(jellyfin(.default, folder: album)["recursive"], "a folder lists its own photos")
    }

    func test_default_emby() {
        let root = emby(.default)
        XCTAssertEqual(root["SortBy"], "DateCreated,SortName")
        XCTAssertEqual(root["SortOrder"], "Descending,Ascending")
        XCTAssertEqual(root["IncludeItemTypes"], "Photo,Video")
        XCTAssertEqual(root["Recursive"], "true")
        XCTAssertEqual(emby(.default, folder: album)["Recursive"], "false")
    }

    // MARK: - Each part of a query

    func test_nameAscending() {
        let query = PhotoQuery(sort: .name, ascending: true)
        XCTAssertEqual(plex(query)["sort"], "titleSort")
        XCTAssertEqual([jellyfin(query)["sortBy"], jellyfin(query)["sortOrder"]], ["SortName", "Ascending"])
        XCTAssertEqual([emby(query)["SortBy"], emby(query)["SortOrder"]], ["SortName", "Ascending"])
    }

    func test_dateAdded_isPlexsAddedAt() {
        XCTAssertEqual(plex(PhotoQuery(sort: .dateAdded))["sort"], "addedAt:desc")
    }

    func test_showVideos() {
        let query = PhotoQuery(show: .videos)
        XCTAssertEqual(plex(query)["type"], "12")
        XCTAssertEqual(jellyfin(query)["includeItemTypes"], "Video")
        XCTAssertEqual(emby(query)["IncludeItemTypes"], "Video")
        XCTAssertEqual(plex(PhotoQuery(show: .photos))["type"], "13")
    }

    func test_favoritesOnly() {
        let query = PhotoQuery(favoritesOnly: true)
        XCTAssertEqual(plex(query)["userRating"], "10", "a photo favorite is rating 10, not the video star rule")
        XCTAssertEqual(plex(query)["clusterZoomLevel"], "1")
        XCTAssertEqual([jellyfin(query)["filters"], jellyfin(query)["recursive"]], ["IsFavorite", "true"])
        XCTAssertEqual([emby(query)["Filters"], emby(query)["Recursive"]], ["IsFavorite", "true"])
        XCTAssertFalse(query.listsAlbums)
    }

    func test_takenBetween() {
        let query = PhotoQuery(takenBetween: autumn)
        let items = PlexProvider.photoQueryItems(query, folder: nil, page: page)
        XCTAssertEqual(items.first { $0.name == "originallyAvailableAt>" }?.value, "2025-10-01")
        XCTAssertEqual(items.first { $0.name == "originallyAvailableAt<" }?.value, "2025-12-01",
                       "PMS reads <= a day as before it starts, so the last day goes as the day after")
        var components = URLComponents(string: "http://s/all")!
        components.queryItems = items
        XCTAssertTrue(components.url!.absoluteString.contains("originallyAvailableAt%3E=2025-10-01"))
        XCTAssertEqual(jellyfin(query)["minPremiereDate"], "2025-10-01T00:00:00Z")
        XCTAssertEqual(jellyfin(query)["maxPremiereDate"], "2025-11-30T23:59:59Z")
        XCTAssertEqual(emby(query)["MinPremiereDate"], "2025-10-01T00:00:00Z")
        XCTAssertEqual(emby(query)["MaxPremiereDate"], "2025-11-30T23:59:59Z")
        XCTAssertFalse(query.listsAlbums)
    }

    func test_shuffled() {
        let query = PhotoQuery(shuffled: true)
        XCTAssertEqual(plex(query)["sort"], "random")
        XCTAssertEqual(jellyfin(query)["sortBy"], "DateCreated,SortName", "the listing shuffles; the server keeps the sort")
        XCTAssertEqual(emby(query)["SortBy"], "DateCreated,SortName")
        XCTAssertFalse(query.listsAlbums)
        XCTAssertTrue(PhotoQuery.default.listsAlbums)
    }

    func test_queryRoundTripsThroughCodable() throws {
        let query = PhotoQuery(sort: .name, ascending: true, show: .photos, favoritesOnly: true, takenBetween: autumn)
        let copy = try JSONDecoder().decode(PhotoQuery.self, from: JSONEncoder().encode(query))
        XCTAssertEqual(copy, query)
    }
}
