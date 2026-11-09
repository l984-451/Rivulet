// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Answers each query from fixed items, filtering by day, favorite and kind as a server would.
private struct FilteringProvider: PhotoProvider {
    let items: [PhotoItem]
    var hasPhotoLocations = true
    var photoSorts: [PhotoQuery.Sort] { [] }
    var shufflesPhotosOnServer: Bool { false }

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
        let calendar = Calendar.current
        let media = items.filter { item in
            if query.favoritesOnly && !item.isFavorite { return false }
            if query.show == .photos && item.kind != .photo { return false }
            if let range = query.takenBetween {
                guard let date = item.date else { return false }
                let day = calendar.startOfDay(for: date)
                return day >= calendar.startOfDay(for: range.lowerBound) && day <= calendar.startOfDay(for: range.upperBound)
            }
            return true
        }
        return PhotoPage(folders: [], media: Array(media.prefix(page.limit)), nextPage: nil)
    }

    func photoYears(in library: MediaLibrary) async throws -> [Int] {
        Set(items.compactMap { $0.date.map { Calendar.current.component(.year, from: $0) } }).sorted(by: >)
    }

    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {}
}

final class PhotoMemoriesTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar? = nil) -> Date {
        (calendar ?? utc).date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func days(_ ranges: [ClosedRange<Date>]) -> [String] {
        ranges.map {
            XCTAssertEqual($0.lowerBound, $0.upperBound)
            let parts = utc.dateComponents([.year, .month, .day], from: $0.lowerBound)
            return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
        }
    }

    func test_onThisDay_earlierYearsNewestFirst() {
        let ranges = PhotoMemories.onThisDayRanges(today: day(2026, 11, 9), years: [2026, 2025, 2020, 2019], calendar: utc)
        XCTAssertEqual(days(ranges), ["2025-11-9", "2020-11-9", "2019-11-9"])
    }

    func test_onThisDay_leapDayOnlyInLeapYears() {
        let ranges = PhotoMemories.onThisDayRanges(today: day(2028, 2, 29), years: [2027, 2024, 2023], calendar: utc)
        XCTAssertEqual(days(ranges), ["2024-2-29"])
    }

    func test_onThisDay_feb28IsNotFeb29() {
        let ranges = PhotoMemories.onThisDayRanges(today: day(2027, 2, 28), years: [2024], calendar: utc)
        XCTAssertEqual(days(ranges), ["2024-2-28"])
    }

    func test_onThisDay_capKeepsNewest() {
        let ranges = PhotoMemories.onThisDayRanges(today: day(2026, 6, 1), years: [2015, 2020, 2018, 2024, 2022],
                                                   calendar: utc, cap: 2)
        XCTAssertEqual(days(ranges), ["2024-6-1", "2022-6-1"])
    }

    func test_featuredYear_stableWithinADay() {
        let years = [2026, 2024, 2021, 2019, 2015]
        let first = PhotoMemories.featuredYear(today: day(2026, 11, 9), years: years, calendar: utc)
        for hour in 0..<100 {
            let today = utc.date(byAdding: .minute, value: hour * 14, to: utc.startOfDay(for: day(2026, 11, 9)))!
            XCTAssertEqual(PhotoMemories.featuredYear(today: today, years: years, calendar: utc), first)
        }
    }

    func test_featuredYear_neverTheCurrentYear() {
        let years = [2026, 2025, 2020]
        var date = day(2026, 1, 1)
        while utc.component(.year, from: date) == 2026 {
            let year = PhotoMemories.featuredYear(today: date, years: years, calendar: utc)
            XCTAssertNotNil(year)
            XCTAssertNotEqual(year, 2026)
            date = utc.date(byAdding: .day, value: 1, to: date)!
        }
    }

    func test_featuredYear_nilWithOnlyTheCurrentYear() {
        XCTAssertNil(PhotoMemories.featuredYear(today: day(2026, 11, 9), years: [2026], calendar: utc))
    }

    private func photo(_ id: String, _ date: Date, favorite: Bool = false, coordinate: PhotoCoordinate? = nil) -> PhotoItem {
        PhotoItem(ref: MediaItemRef(providerID: "p", itemID: id), kind: .photo, title: id, date: date,
                  childCount: nil, thumbnail: nil, full: nil, playable: nil,
                  isFavorite: favorite, coordinate: coordinate)
    }

    private let library = MediaLibrary(id: "1", providerID: "p", title: "Photos", kind: .photos)

    @MainActor
    func test_load_onlyKindsWithContent() async {
        let local = Calendar.current
        let provider = FilteringProvider(items: [
            photo("a", day(2023, 11, 9, in: local)),
            photo("b", day(2021, 11, 9, in: local)),
            photo("c", day(2021, 3, 2, in: local))
        ])
        let memories = await PhotoMemories.load(provider: provider, library: library, today: day(2026, 11, 9, in: local))
        guard memories.count == 2, case .year(let year) = memories[1].kind else {
            return XCTFail("expected On This Day and a year, got \(memories.map(\.kind))")
        }
        XCTAssertEqual(memories[0].kind, .onThisDay)
        XCTAssertEqual(memories[0].content, .items([provider.items[0], provider.items[1]]))
        XCTAssertEqual(memories[0].title, "On This Day")
        XCTAssertTrue([2021, 2023].contains(year))
        XCTAssertEqual(memories[1].title, "Photos from \(year)")
        XCTAssertNotNil(memories[1].cover)
    }

    @MainActor
    func test_load_favoritesAndMap() async {
        let local = Calendar.current
        let provider = FilteringProvider(items: [
            photo("a", day(2020, 1, 5, in: local), favorite: true, coordinate: PhotoCoordinate(latitude: 1, longitude: 2))
        ])
        let memories = await PhotoMemories.load(provider: provider, library: library, today: day(2026, 11, 9, in: local))
        XCTAssertEqual(memories.map(\.kind), [.year(2020), .favorites, .map])
        XCTAssertNil(memories[2].cover)
    }

    /// Opening a memory: fixed items list as they are and write favorites to the library's server;
    /// a query memory keeps the library's source and narrows with the saved Sort.
    @MainActor
    func test_openingAMemory() async throws {
        final class Writes: @unchecked Sendable { var refs: [MediaItemRef] = [] }
        struct Server: PhotoProvider {
            let writes: Writes
            var photoSorts: [PhotoQuery.Sort] { [.dateTaken] }
            var shufflesPhotosOnServer: Bool { false }
            var hasPhotoLocations: Bool { false }
            func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery,
                           page: Page) async throws -> PhotoPage { PhotoPage(folders: [], media: [], nextPage: nil) }
            func photoYears(in library: MediaLibrary) async throws -> [Int] { [] }
            func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws { writes.refs.append(ref) }
        }
        let writes = Writes()
        let library = self.library
        let base: PhotoListing.Source = { (Server(writes: writes), library) }
        let items = [photo("a", day(2023, 11, 9)), photo("b", day(2021, 11, 9))]

        let onThisDay = PhotoMemory(kind: .onThisDay, title: "On This Day", cover: items[0], content: .items(items))
        XCTAssertEqual(onThisDay.query, .default)
        let fixed = try XCTUnwrap(onThisDay.source(over: base)())
        let page = try await fixed.provider.photoPage(in: library, folder: nil, query: .default, page: Page(offset: 0, limit: 10))
        XCTAssertEqual(page.media, items)
        XCTAssertTrue(fixed.provider.photoSorts.isEmpty)
        try await fixed.provider.setPhotoFavorite(true, for: items[1].ref)
        XCTAssertEqual(writes.refs, [items[1].ref])

        let range = day(2020, 1, 1)...day(2020, 12, 31)
        let year = PhotoMemory(kind: .year(2020), title: "Photos from 2020", cover: items[0],
                               content: .query(PhotoQuery(takenBetween: range)))
        XCTAssertFalse(try XCTUnwrap(year.source(over: base)()).provider.photoSorts.isEmpty)
        XCTAssertEqual(year.query.takenBetween, range)
        XCTAssertFalse(year.query.listsAlbums)
    }
}
