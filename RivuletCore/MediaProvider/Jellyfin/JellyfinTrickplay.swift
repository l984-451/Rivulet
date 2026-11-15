// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinTrickplay.swift
//  Rivulet
//
//  Jellyfin trickplay (10.9+): the server cuts a title into tiled JPEG sheets,
//  one thumbnail per `interval` ms. Scrub previews read them instead of
//  decoding frames from the file.
//

import CoreGraphics
import Foundation
import ImageIO

/// One resolution of a title's trickplay, as the item's `Trickplay` field reports it.
nonisolated struct JFTrickplayInfo: Decodable, Sendable, Equatable {
    let width: Int
    let height: Int
    let tileWidth: Int
    let tileHeight: Int
    let thumbnailCount: Int
    /// Milliseconds between thumbnails.
    let interval: Int

    var isUsable: Bool {
        width > 0 && height > 0 && tileWidth > 0 && tileHeight > 0 && thumbnailCount > 0 && interval > 0
    }

    /// The sheet holding the thumbnail for `seconds`, and its crop inside that sheet.
    func locate(_ seconds: Double) -> (sheet: Int, crop: CGRect) {
        let n = min(max(0, Int(seconds * 1000) / interval), thumbnailCount - 1)
        let perSheet = tileWidth * tileHeight
        let slot = n % perSheet
        return (n / perSheet, CGRect(x: (slot % tileWidth) * width, y: (slot / tileWidth) * height,
                                     width: width, height: height))
    }

    /// The width closest to `target`, from one media source's `{ "<width>": info }` map.
    static func choose(from widths: [String: JFTrickplayInfo], near target: Int) -> JFTrickplayInfo? {
        widths.values.filter(\.isUsable).min { abs($0.width - target) < abs($1.width - target) }
    }
}

/// `fields=Trickplay` on one item: `{ mediaSourceId: { width: info } }`.
nonisolated struct JFTrickplayItem: Decodable, Sendable {
    let trickplay: [String: [String: JFTrickplayInfo]]?

    /// The source's own map, else the only one (a single-version item is keyed by its item id).
    func widths(forSource sourceID: String?) -> [String: JFTrickplayInfo]? {
        guard let trickplay else { return nil }
        if let sourceID, let own = trickplay[sourceID] { return own }
        return trickplay.count == 1 ? trickplay.values.first : nil
    }
}

/// Crops preview stills out of a title's sheets, keeping the few most recent in memory.
/// Dropping the object releases them.
actor JellyfinTrickplayPreviews: ScrubPreviewSource {
    private let info: JFTrickplayInfo
    private let fetchSheet: @Sendable (Int) async -> Data?
    private var sheets: [(index: Int, image: CGImage)] = []
    private static let maxSheets = 3

    init(info: JFTrickplayInfo, fetchSheet: @escaping @Sendable (Int) async -> Data?) {
        self.info = info
        self.fetchSheet = fetchSheet
    }

    func image(at seconds: Double) async -> CGImage? {
        let spot = info.locate(seconds)
        if let hit = sheets.firstIndex(where: { $0.index == spot.sheet }) {
            let found = sheets.remove(at: hit)
            sheets.append(found)
            return found.image.cropping(to: spot.crop)
        }
        guard let data = await fetchSheet(spot.sheet),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              // Decoded once here, so each crop doesn't decode the whole sheet again.
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        sheets.append((spot.sheet, sheet))
        if sheets.count > Self.maxSheets { sheets.removeFirst() }
        return sheet.cropping(to: spot.crop)
    }
}
