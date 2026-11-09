// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Three pages of two photos, one located in each; records the queries it was asked.
private final class PagedProvider: PhotoProvider, @unchecked Sendable {
    var queries: [PhotoQuery] = []
    var photoSorts: [PhotoQuery.Sort] { [] }
    var shufflesPhotosOnServer: Bool { false }
    var hasPhotoLocations: Bool { true }

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
        queries.append(query)
        let index = page.offset / page.limit
        let media = [
            Self.photo("\(index)a", PhotoCoordinate(latitude: Double(index), longitude: 1)),
            Self.photo("\(index)b", nil),
        ]
        let next = index < 2 ? Page(offset: page.offset + page.limit, limit: page.limit) : nil
        return PhotoPage(folders: [], media: media, nextPage: next)
    }

    func photoYears(in library: MediaLibrary) async throws -> [Int] { [] }
    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {}

    static func photo(_ id: String, _ coordinate: PhotoCoordinate?) -> PhotoItem {
        PhotoItem(ref: MediaItemRef(providerID: "p", itemID: id), kind: .photo, title: id, date: nil,
                  childCount: nil, thumbnail: nil, full: nil, playable: nil, coordinate: coordinate)
    }
}

@MainActor
final class PhotoMapLoaderTests: XCTestCase {
    override func setUp() async throws {
        PhotoMapLoader.clearCache()
    }

    func test_load_keepsLocatedPhotosAcrossPagesAndStops() async {
        let provider = PagedProvider()
        let library = MediaLibrary(id: "map", providerID: "p", title: "Photos", kind: .photos)
        var pages: [[String]] = []
        await PhotoMapLoader(provider: provider, library: library, pageSize: 2).load { items in
            pages.append(items.map(\.ref.itemID))
        }
        XCTAssertEqual(pages, [["0a"], ["1a"], ["2a"]])
        XCTAssertEqual(provider.queries.count, 3)
        XCTAssertTrue(provider.queries.allSatisfy { $0.show == .photos })

        // The second open is served from the session cache in one call.
        var cached: [[String]] = []
        await PhotoMapLoader(provider: provider, library: library, pageSize: 2).load { cached.append($0.map(\.ref.itemID)) }
        XCTAssertEqual(cached, [["0a", "1a", "2a"]])
        XCTAssertEqual(provider.queries.count, 3)
    }

    func test_clusters_groupByCell() {
        let items = [
            PagedProvider.photo("a", PhotoCoordinate(latitude: 10.01, longitude: 20.01)),
            PagedProvider.photo("b", PhotoCoordinate(latitude: 10.02, longitude: 20.03)),
            PagedProvider.photo("c", PhotoCoordinate(latitude: 40, longitude: -70)),
            PagedProvider.photo("d", nil),
        ]
        let groups = PhotoMapLoader.clusters(items, cell: 1).map { $0.map(\.ref.itemID).sorted() }.sorted { $0.count > $1.count }
        XCTAssertEqual(groups, [["a", "b"], ["c"]])
    }

    func test_places_groupByCell_newestPlaceFirst_newestPhotoFirst() {
        func photo(_ id: String, _ lat: Double, _ lon: Double, _ day: Double?) -> PhotoItem {
            PhotoItem(ref: MediaItemRef(providerID: "p", itemID: id), kind: .photo, title: id,
                      date: day.map { Date(timeIntervalSince1970: $0 * 86_400) }, childCount: nil, thumbnail: nil,
                      full: nil, playable: nil, coordinate: PhotoCoordinate(latitude: lat, longitude: lon))
        }
        let items = [
            photo("old-here", 10.01, 20.01, 1),
            photo("new-here", 10.05, 20.09, 5),
            photo("there", 10.15, 20.01, 9),       // next cell north
            photo("undated", -33.87, 151.21, nil),
            PagedProvider.photo("unlocated", nil),
        ]
        let places = PhotoMapLoader.places(items)
        XCTAssertEqual(places.map { $0.photos.map(\.ref.itemID) }, [["there"], ["new-here", "old-here"], ["undated"]])
        XCTAssertEqual(places[1].id, PhotoPlace.ID(latitude: 100, longitude: 200))
        XCTAssertEqual(places[2].id, PhotoPlace.ID(latitude: -339, longitude: 1512), "negatives round down")
    }
}
