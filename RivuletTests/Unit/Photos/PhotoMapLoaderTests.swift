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
}
