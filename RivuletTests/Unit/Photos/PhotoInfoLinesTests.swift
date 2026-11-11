// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class PhotoInfoLinesTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private let chicago = TimeZone(identifier: "America/Chicago")!

    private func item(_ details: PhotoDetails) -> PhotoItem {
        PhotoItem(ref: MediaItemRef(providerID: "p", itemID: "1"), kind: .photo, title: "IMG_0001",
                  date: nil, childCount: nil, thumbnail: nil, full: nil, playable: nil, details: details)
    }

    /// 2025-11-03 14:07 stamped Z, as Jellyfin and Emby send the camera's clock.
    private let stamped = Date(timeIntervalSince1970: 1_762_178_820)

    func test_embyShaped_isDateAndSize() {
        let lines = PhotoInfoLines.lines(
            for: item(PhotoDetails(takenAt: stamped, width: 1280, height: 960, takenAtClock: .wallClock)),
            locale: locale, timeZone: chicago)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], "1280 × 960")
    }

    func test_jellyfinShaped_isSixLinesInOrder_withTheCamerasClock() {
        let details = PhotoDetails(
            takenAt: stamped, make: "Apple", model: "iPhone Air", lens: "iPhone Air back camera 5.96mm f/1.6",
            fNumber: 1.6, exposureSeconds: 0.0125, iso: 125, focalLength: 5.96,
            width: 4284, height: 5712, fileName: "trip-8.jpg", takenAtClock: .wallClock)
        let lines = PhotoInfoLines.lines(for: item(details), locale: locale, timeZone: chicago)
        XCTAssertEqual(lines.count, 6)
        // The device's zone must not move the camera's clock.
        XCTAssertTrue(lines[0].hasPrefix("November 3, 2025"), lines[0])
        XCTAssertTrue(lines[0].contains("2:07"), lines[0])
        XCTAssertEqual(Array(lines[1...]), [
            "Apple iPhone Air", "iPhone Air back camera 5.96mm f/1.6",
            "f/1.6 · 1/80 s · ISO 125 · 6 mm", "4284 × 5712", "trip-8.jpg"
        ])
    }

    func test_instant_readsInTheDeviceZone() {
        let lines = PhotoInfoLines.lines(for: item(PhotoDetails(takenAt: stamped, takenAtClock: .instant)),
                                         locale: locale, timeZone: chicago)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("November 3, 2025"), lines[0])
        XCTAssertTrue(lines[0].contains("8:07"), lines[0])
    }

    func test_plexDay_hasNoTime() {
        let day = try! Date("2025-12-09", strategy: Date.ISO8601FormatStyle(timeZone: chicago).year().month().day())
        let lines = PhotoInfoLines.lines(for: item(PhotoDetails(takenAt: day)), locale: locale, timeZone: chicago)
        XCTAssertEqual(lines, ["December 9, 2025"])
    }

    func test_merged_fillsGapsFromTheList() {
        let fetched = PhotoDetails(make: "Apple", width: 4032)
        let merged = fetched.merged(over: PhotoDetails(make: "Other", height: 3024, fileName: "a.jpg"))
        XCTAssertEqual(merged.make, "Apple")
        XCTAssertEqual(merged.width, 4032)
        XCTAssertEqual(merged.height, 3024)
        XCTAssertEqual(merged.fileName, "a.jpg")
    }
}

@MainActor
final class PhotoDetailsCacheTests: XCTestCase {
    /// Counts detail requests; each takes a moment so two loads overlap.
    private final class CountingProvider: PhotoProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        var photoSorts: [PhotoQuery.Sort] { [] }
        var shufflesPhotosOnServer: Bool { false }
        var hasPhotoLocations: Bool { false }
        func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
            PhotoPage(folders: [], media: [], nextPage: nil)
        }
        func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {}
        func photoYears(in library: MediaLibrary) async throws -> [Int] { [] }
        func photoDetails(for item: PhotoItem) async throws -> PhotoDetails? {
            lock.withLock { count += 1 }
            try await Task.sleep(for: .milliseconds(50))
            return PhotoDetails(make: "Apple")
        }
    }

    /// A ref no other test has cached.
    private func item() -> PhotoItem {
        PhotoItem(ref: MediaItemRef(providerID: "p", itemID: UUID().uuidString), kind: .photo, title: "",
                  date: nil, childCount: nil, thumbnail: nil, full: nil, playable: nil,
                  details: PhotoDetails(width: 10))
    }

    func test_cacheHit_makesNoSecondCall() async {
        let provider = CountingProvider(), photo = item()
        let first = await PhotoDetailsCache.load(photo, provider: provider)
        let second = await PhotoDetailsCache.load(photo, provider: provider)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(first.details?.make, "Apple")
        XCTAssertEqual(second.details?.make, "Apple")
        XCTAssertEqual(PhotoDetailsCache.known(photo).details?.make, "Apple")
    }

    func test_concurrentLoads_shareOneCall() async {
        let provider = CountingProvider(), photo = item()
        async let first = PhotoDetailsCache.load(photo, provider: provider)
        async let second = PhotoDetailsCache.load(photo, provider: provider)
        let results = await [first, second]
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(results.map { $0.details?.make }, ["Apple", "Apple"])
    }
}
