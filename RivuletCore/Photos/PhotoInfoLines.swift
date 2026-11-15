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
        let size = details.width.flatMap { width in details.height.map { "\(width) × \($0)" } }
        return [taken(details, locale, timeZone), details.cameraLine, details.lens, details.exposureLine,
                size, details.fileName].compactMap { $0 }
    }

    /// tvOS's info card, laid out as the player's: the day taken as the title (else the file name, else the
    /// item's title), camera, lens and exposure as the summary, size and file name on the meta line.
    static func card(for item: PhotoItem, locale: Locale = .current,
                     timeZone: TimeZone = .current) -> (title: String, summary: String?, meta: String?) {
        guard let details = item.details else { return (item.title, nil, nil) }
        let taken = taken(details, locale, timeZone)
        let size = details.width.flatMap { width in details.height.map { "\(width) × \($0)" } }
        let summary = [details.cameraLine, details.lens, details.exposureLine].compactMap { $0 }
        let meta = [size, taken == nil ? nil : details.fileName].compactMap { $0 }
        return (taken ?? details.fileName ?? item.title,
                summary.isEmpty ? nil : summary.joined(separator: " • "),
                meta.isEmpty ? nil : meta.joined(separator: " • "))
    }

    private static func taken(_ details: PhotoDetails, _ locale: Locale, _ timeZone: TimeZone) -> String? {
        details.takenAt.map { date in
            date.formatted(Date.FormatStyle(
                date: .long, time: details.takenAtClock == .day ? .omitted : .shortened,
                locale: locale, calendar: locale.calendar,
                timeZone: details.takenAtClock == .wallClock ? .gmt : timeZone))
        }
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
