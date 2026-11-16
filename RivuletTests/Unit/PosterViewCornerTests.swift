// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import TVUIKit
import UIKit
@testable import Rivulet

@MainActor
struct PosterViewCornerTests {
    @Test(arguments: [false, true])
    func imageViewCornersSurviveArtworkReplacementAndReuse(isMusic: Bool) throws {
        let tile = isMusic ? MediaRowMetrics.music : MediaRowMetrics.poster
        let cell = PosterCell(frame: CGRect(origin: .zero, size: tile.frame))
        var item = PlexMetadata()
        item.type = isMusic ? "album" : "movie"
        item.title = "Corner check"
        item.duration = 7_200_000
        item.viewOffset = 1_800_000
        cell.configure(item: item)
        let poster = try #require(cell.contentView.subviews.compactMap { $0 as? TVPosterView }.first)
        let originalClipping = poster.imageView.clipsToBounds
        let source = try #require(UIGraphicsImageRenderer(
            size: tile.art, format: .layeredArtwork(scale: 1)
        ).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: tile.art))
        }.cgImage)
        let artwork = RoundedPoster.render(source, shape: .init(tile: tile, scale: 2))
        for reuse in [false, true] {
            if reuse {
                cell.prepareForReuse()
                cell.configure(item: item)
            }
            poster.image = artwork
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            #expect(poster.imageView.clipsToBounds == originalClipping)
            #expect(poster.imageView.masksFocusEffectToContents == false)
            for view in [poster.imageView] {
                for corner in [UIRectCorner.topLeft, .topRight, .bottomLeft, .bottomRight] {
                    #expect(abs(view.effectiveRadius(corner: corner) - RoundedPoster.cornerRadius) < 0.01)
                }
            }
        }
    }

    @Test func watchlistUsesTheSameViewCorners() throws {
        let cell = WatchlistPosterCell(frame: CGRect(origin: .zero, size: MediaRowMetrics.poster.frame))
        cell.layoutIfNeeded()
        let poster = try #require(cell.contentView.subviews.compactMap { $0 as? TVPosterView }.first)
        for corner in [UIRectCorner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            #expect(abs(poster.imageView.effectiveRadius(corner: corner) - RoundedPoster.cornerRadius) < 0.01)
        }
    }
}
