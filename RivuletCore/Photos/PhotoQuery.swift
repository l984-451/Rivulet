// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoQuery.swift
//  Rivulet
//
//  What a photo grid asks for: order, what to show, and narrowing. Each
//  provider maps it to its own parameters; the default is the original order.
//

import Foundation

nonisolated struct PhotoQuery: Hashable, Sendable, Codable {
    enum Sort: String, Codable, CaseIterable, Sendable { case dateTaken, dateAdded, name }
    enum Show: String, Codable, CaseIterable, Sendable { case all, photos, videos }

    var sort: Sort = .dateTaken
    var ascending = false
    var show: Show = .all
    var favoritesOnly = false
    var shuffled = false
    /// Inclusive days, read in the device's zone.
    var takenBetween: ClosedRange<Date>?

    static let `default` = PhotoQuery()

    /// Albums are listed only for the plain browse; a narrowed or shuffled grid is photos alone.
    var listsAlbums: Bool { !favoritesOnly && takenBetween == nil && !shuffled }

    /// `takenBetween` as "yyyy-MM-dd" days in `zone`.
    func days(in zone: TimeZone = .current) -> (first: String, last: String)? {
        guard let range = takenBetween else { return nil }
        let style = Date.ISO8601FormatStyle(timeZone: zone).year().month().day()
        return (range.lowerBound.formatted(style), range.upperBound.formatted(style))
    }
}
