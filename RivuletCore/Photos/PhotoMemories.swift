// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoMemories.swift
//  Rivulet
//
//  The memories row at the top of a photo library: On This Day, Photos from
//  <year>, Favorites and Map. No server has a memories endpoint, so each is a
//  query over the seam.
//

import Foundation

nonisolated struct PhotoMemory: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case onThisDay, year(Int), favorites, map }
    let kind: Kind
    let title: String
    /// nil only for `.map`.
    let cover: PhotoItem?
    /// What opening it lists: fixed items (On This Day) or a query.
    enum Content: Hashable, Sendable { case items([PhotoItem]), query(PhotoQuery), map }
    let content: Content
}

extension PhotoMemory {
    /// What its grid narrows to: the memory's query, else none.
    var query: PhotoQuery {
        if case .query(let query) = content { return query }
        return .default
    }

    /// Where its grid lists from: its fixed items (favorites written to the library's server), else the library.
    func source(over library: @escaping PhotoListing.Source) -> PhotoListing.Source {
        guard case .items(let items) = content else { return library }
        return { library().map { (FixedPhotoProvider(items: items, server: $0.provider), $0.library) } }
    }
}

nonisolated enum PhotoMemories {
    static let onThisDayYears = 10
    static let onThisDayLimit = 50
    static let mapProbeLimit = 50

    /// One inclusive day per earlier year present, newest first, at most `cap`. Feb 29 only in leap years.
    static func onThisDayRanges(today: Date, years: [Int], calendar: Calendar,
                                cap: Int = onThisDayYears) -> [ClosedRange<Date>] {
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let current = now.year else { return [] }
        let days: [Date] = Set(years).filter { $0 < current }.sorted(by: >).compactMap { year in
            var parts = now
            parts.year = year
            // A Feb 29 that does not exist rolls to Mar 1: drop it.
            guard let day = calendar.date(from: parts),
                  calendar.component(.month, from: day) == now.month,
                  calendar.component(.day, from: day) == now.day else { return nil }
            return calendar.startOfDay(for: day)
        }
        return days.prefix(cap).map { $0...$0 }
    }

    /// A past year present in `years`, never the current one, the same for every call on one calendar day.
    static func featuredYear(today: Date, years: [Int], calendar: Calendar) -> Int? {
        let current = calendar.component(.year, from: today)
        let past = Set(years).filter { $0 < current }.sorted()
        guard !past.isEmpty, let day = calendar.ordinality(of: .day, in: .era, for: today) else { return nil }
        return past[day % past.count]
    }

    /// Order: On This Day, Photos from <year>, Favorites, Map. Each only when non-empty; Map only when
    /// `hasPhotoLocations` and a probe finds a coordinate. A failed request drops its memory, never the row.
    @MainActor static func load(provider: any PhotoProvider, library: MediaLibrary, today: Date) async -> [PhotoMemory] {
        let calendar = Calendar.current
        let favoritesQuery = PhotoQuery(favoritesOnly: true)
        async let favorites = media(provider, library, favoritesQuery, limit: 1)
        async let located = provider.hasPhotoLocations
            ? media(provider, library, PhotoQuery(show: .photos), limit: mapProbeLimit) : nil
        let years = (try? await provider.photoYears(in: library)) ?? []

        let ranges = onThisDayRanges(today: today, years: years, calendar: calendar)
        let featured = featuredYear(today: today, years: years, calendar: calendar)
        let yearQuery = featured.flatMap { year -> PhotoQuery? in
            guard let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let last = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return nil }
            return PhotoQuery(takenBetween: first...last)
        }
        async let yearCover = yearQuery == nil ? nil : media(provider, library, yearQuery!, limit: 1)
        let onThisDay = await withTaskGroup(of: (Int, [PhotoItem]).self) { group in
            for (index, range) in ranges.enumerated() {
                group.addTask {
                    (index, await media(provider, library, PhotoQuery(takenBetween: range), limit: onThisDayLimit) ?? [])
                }
            }
            var found: [(Int, [PhotoItem])] = []
            for await result in group { found.append(result) }
            return found.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }

        var memories: [PhotoMemory] = []
        if let cover = onThisDay.first {
            memories.append(PhotoMemory(kind: .onThisDay, title: String(localized: "On This Day"),
                                        cover: cover, content: .items(onThisDay)))
        }
        if let featured, let yearQuery, let cover = await yearCover?.first {
            // The year goes in as a String: an Int interpolation is grouped ("2,019").
            memories.append(PhotoMemory(kind: .year(featured), title: String(localized: "Photos from \(String(featured))"),
                                        cover: cover, content: .query(yearQuery)))
        }
        if let cover = await favorites?.first {
            memories.append(PhotoMemory(kind: .favorites, title: String(localized: "Favorites"),
                                        cover: cover, content: .query(favoritesQuery)))
        }
        if await located?.contains(where: { $0.coordinate != nil }) == true {
            memories.append(PhotoMemory(kind: .map, title: String(localized: "Map"), cover: nil, content: .map))
        }
        return memories
    }

    /// The first `limit` photos and clips at the library's root for `query`, or nil on failure.
    private static func media(_ provider: any PhotoProvider, _ library: MediaLibrary,
                              _ query: PhotoQuery, limit: Int) async -> [PhotoItem]? {
        try? await provider.photoPage(in: library, folder: nil, query: query,
                                      page: Page(offset: 0, limit: limit)).media
    }
}
