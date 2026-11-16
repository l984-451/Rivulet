// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import TVUIKit
import UIKit
@testable import Rivulet

@MainActor
struct PosterViewCornerTests {
    @Test(arguments: [false, true])
    func nativeOverlayAndCornersSurviveArtworkReplacementAndReuse(isMusic: Bool) throws {
        let tile = isMusic ? MediaRowMetrics.music : MediaRowMetrics.poster
        let cell = PosterCell(frame: CGRect(origin: .zero, size: tile.frame))
        var item = PlexMetadata()
        item.type = isMusic ? "album" : "movie"
        item.title = "Corner check"
        item.duration = 7_200_000
        item.viewOffset = 1_800_000
        cell.configure(item: item)
        let poster = try #require(cell.contentView.subviews.compactMap { $0 as? TVPosterView }.first)
        let overlay = cell.previewArtworkView
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
            let host = poster.imageView.overlayContentView
            #expect(overlay.superview === host)
            #expect(abs(overlay.frame.minX - host.bounds.minX) < 0.01)
            #expect(abs(overlay.frame.minY - host.bounds.minY) < 0.01)
            #expect(abs(overlay.frame.width - host.bounds.width) < 0.01)
            #expect(abs(overlay.frame.height - host.bounds.height) < 0.01)
            #expect(poster.imageView.clipsToBounds == originalClipping)
            #expect(poster.imageView.masksFocusEffectToContents == false)
            if !isMusic {
                let band = try #require(overlay.subviews.compactMap { $0 as? BottomInfoBlurView }.first)
                #expect(band.isHidden == false)
                #expect(abs(band.frame.width - overlay.bounds.width) < 0.01)
                #expect(abs(band.frame.maxY - overlay.bounds.maxY) < 0.01)
            }
            for view in [poster.imageView, overlay] {
                for corner in [UIRectCorner.topLeft, .topRight, .bottomLeft, .bottomRight] {
                    #expect(abs(view.effectiveRadius(corner: corner) - RoundedPoster.cornerRadius) < 0.01)
                }
            }
        }
    }

    @Test func unfocusCleanupResetsHostsWithoutWalkingOverlayEffects() throws {
        let cell = PosterCell(frame: CGRect(origin: .zero, size: MediaRowMetrics.poster.frame))
        let poster = try #require(cell.contentView.subviews.compactMap { $0 as? TVPosterView }.first)
        let host = poster.imageView.overlayContentView
        let content = UIView()
        cell.previewArtworkView.addSubview(content)
        let hostTransform = CGAffineTransform(translationX: 3, y: 2)
        let contentTransform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        host.transform = hostTransform
        cell.previewArtworkView.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
        content.transform = contentTransform
        poster.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)

        cell.resetStaleFocusAppearance()

        #expect(poster.transform.isIdentity)
        #expect(host.transform.isIdentity)
        #expect(cell.previewArtworkView.transform.isIdentity)
        #expect(content.transform == contentTransform)
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
