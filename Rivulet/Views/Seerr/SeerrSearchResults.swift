// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The Search tab's "Request" row: what Seerr finds that the library
// doesn't have. Select opens the title's detail page (its Request button asks Seerr); a long press
// opens a quick request menu. `PlexHomeViewController` holds one and feeds it each search.

import os
import UIKit

@MainActor
final class SeerrSearchResults {
    static let sectionID = HomeSectionID.searchGroup("seerr")

    private(set) var titles: [SeerrTitle] = []
    /// Repaints the row's tiles after a request changes a badge.
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    // MARK: - Search

    /// Seerr's results for `query`; a new query drops the old row now, so the library's results
    /// never show beside another query's.
    func fetch(_ query: String) async -> [SeerrTitle] {
        titles = []
        return await SeerrCatalog.search(query)
    }

    func apply(_ titles: [SeerrTitle]) {
        self.titles = SeerrCatalog.isAvailable ? titles : []
    }

    var hasResults: Bool { !titles.isEmpty }

    /// The row, after the library's own groups.
    func sections() -> [HomeSectionData] {
        guard !titles.isEmpty else { return [] }
        return [.searchGrid(id: Self.sectionID, title: String(localized: "Request"),
                            items: titles.map(\.mediaItem))]
    }

    /// The tile's corner badge: its Seerr status. Nil for every other row.
    func badge(section: HomeSectionID, index: Int) -> String? {
        guard section == Self.sectionID else { return nil }
        return titles[safe: index]?.availability.badge
    }

    // MARK: - Long press

    /// A long press on a Request tile opens its quick menu. False for every other tile, so the
    /// caller's own menu runs.
    func select(section: HomeSectionID, index: Int, from presenter: UIViewController,
                sourceFrame: CGRect?, moreInfo: @escaping () -> Void) -> Bool {
        guard section == Self.sectionID, let title = titles[safe: index] else { return false }
        let more = TileMenuAction(title: "More Info",
                                  systemImage: "info.circle", handler: moreInfo)
        let detail = title.releaseDate.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
        let done: @MainActor (SeerrAvailability) -> Void = { [weak self] state in
            self?.update(index: index, tmdbID: title.tmdbID, to: state)
        }
        switch title.kind {
        case .movie:
            let first = title.availability.canRequest
                ? TileMenuAction(title: "Request", systemImage: "plus.circle") { [weak presenter] in
                    guard let presenter else { return }
                    SeerrRequestFlow.requestMovie(title.tmdbID, title: title.title, from: presenter,
                                                  sourceFrame: sourceFrame, done: done)
                }
                : TileMenuAction(verbatim: title.availability.badge ?? "",
                                 systemImage: title.availability.symbolName, handler: {})
            SeerrRequestFlow.present([[first], [more]], header: TileMenuHeader(title: title.title, detail: detail),
                                     from: presenter, sourceFrame: sourceFrame)
        case .tv:
            SeerrRequestFlow.presentSeasons(of: title.tmdbID, title: title.title, detail: detail, from: presenter,
                                            sourceFrame: sourceFrame, extra: [more], done: done)
        }
        return true
    }

    /// The tile's badge after a request. Matched on the id too, in case a new search replaced the row.
    private func update(index: Int, tmdbID: Int, to availability: SeerrAvailability) {
        guard titles.indices.contains(index), titles[index].tmdbID == tmdbID else { return }
        titles[index].availability = availability
        onChange()
    }
}
