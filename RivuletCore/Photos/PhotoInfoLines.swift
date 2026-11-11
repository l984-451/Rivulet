// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoInfoLines.swift
//  Rivulet
//
//  What a photo's info pane says, on every app, and the details it says it from.
//

import Foundation

enum PhotoInfoLines {
    /// Display lines in order: date and time, camera, lens, exposure, "4032 × 3024", file name. Empty parts omitted.
    /// A wall-clock time shows as stamped; an instant and a day (Plex, no time) read in `timeZone`.
    static func lines(for item: PhotoItem, locale: Locale = .current, timeZone: TimeZone = .current) -> [String] {
        guard let details = item.details else { return [] }
        let taken = details.takenAt.map { date in
            date.formatted(Date.FormatStyle(
                date: .long, time: details.takenAtClock == .day ? .omitted : .shortened,
                locale: locale, calendar: locale.calendar,
                timeZone: details.takenAtClock == .wallClock ? .gmt : timeZone))
        }
        let size = details.width.flatMap { width in details.height.map { "\(width) × \($0)" } }
        return [taken, details.cameraLine, details.lens, details.exposureLine, size, details.fileName]
            .compactMap { $0 }
    }

    /// The viewer's caption: the day taken, long ("November 9, 2023"), under its place; the place
    /// alone without a date; nothing without either. Never a title or album, which run long.
    static func caption(date: Date?, place: String?) -> (eyebrow: String?, title: String?) {
        guard let date else { return (nil, place) }
        return (place, date.formatted(date: .long, time: .omitted))
    }
}

/// Each photo's fetched details, kept for the session.
@MainActor
enum PhotoDetailsCache {
    private static var fetched: [MediaItemRef: PhotoDetails] = [:]
    /// One request per photo, shared by every caller asking while it runs.
    private static var inFlight: [MediaItemRef: Task<PhotoDetails?, Never>] = [:]

    /// `item` with the best details known now: fetched, else listed.
    static func known(_ item: PhotoItem) -> PhotoItem {
        var item = item
        item.details = fetched[item.ref] ?? item.details
        return item
    }

    /// `item` with its full details, fetched once per photo. A failure keeps the listed ones and tries again next time.
    static func load(_ item: PhotoItem, provider: any PhotoProvider) async -> PhotoItem {
        let ref = item.ref
        guard fetched[ref] == nil else { return known(item) }
        let task = inFlight[ref] ?? Task { try? await provider.photoDetails(for: item) }
        inFlight[ref] = task
        let details = await task.value
        inFlight[ref] = nil
        if let details { fetched[ref] = details }
        return known(item)
    }
}
