// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The one source of tile and row metrics for every media shelf, layout and cell constraints alike.
// Margin, gap and tile widths are the Apple TV app's grid (tvOS 26.5).

import UIKit

enum MediaRowMetrics {
    // MARK: The grid
    //
    // 1920 = 2·rowLeading + N·width + (N − 1)·tileGap, leaving a 40 pt sliver of tile N + 1.
    // These are artwork numbers; a cell is its lockup's larger frame (see "Lockup frames").

    /// The app-wide content margin: hero, shelf headers, tile artwork, the
    /// expanded detail (`PreviewCarouselGeometry.expandedChromeInset`), popups.
    static let rowLeading: CGFloat = 80
    static let rowTrailing: CGFloat = rowLeading

    /// Gap between the artwork of neighbouring tiles.
    static let tileGap: CGFloat = 40

    /// Width of a tile covering `span` of `columns` grid columns.
    static func gridWidth(columns: Int, span: Int = 1) -> CGFloat {
        let column = (1920 - 2 * rowLeading - CGFloat(columns - 1) * tileGap) / CGFloat(columns)
        return (column * CGFloat(span) + tileGap * CGFloat(span - 1)).rounded(.down)
    }

    /// Fully-visible tile count per shelf type (the N in the equation). Posters follow
    /// Settings › Appearance › Display Size; a change re-lays out the screens showing them.
    static var posterFullCount: Int { DisplaySize.current.posterColumns }
    static let cwFullCount = 5
    static let liveFullCount = 4

    // MARK: Lockup frames
    //
    // TVPosterView and TVCardView rest their artwork short of their frame and
    // grow it to fill the frame on focus, by `focusGrowth` (a poster on its
    // long side and the other side in proportion; a card on both). Apple's
    // growth differs per tile (`Tile.growth`), so a cell is the frame Apple's
    // focused tile fills, the TVUIKit host stays at `Tile.hostSize` and a small
    // scale on focus (`Tile.focusScale`) trims it down to the cell.
    static let focusGrowth: CGFloat = 40

    /// A tile: its resting artwork, and the lockup frame (the cell) around it.
    struct Tile {
        enum Lockup { case poster, card }
        let art: CGSize
        var lockup = Lockup.poster
        /// Growth on focus (width, height), measured on device, tvOS 27.
        var growth = CGSize(width: MediaRowMetrics.focusGrowth, height: MediaRowMetrics.focusGrowth)

        /// Whole points: compositional layout floors a fractional item width,
        /// which would shorten the pitch.
        var frame: CGSize {
            CGSize(width: (art.width + growth.width).rounded(), height: (art.height + growth.height).rounded())
        }
        /// The size TVUIKit's own focus growth fills: the host view takes this size so the
        /// artwork rests at `art`.
        var hostSize: CGSize {
            let g = MediaRowMetrics.focusGrowth
            switch lockup {
            case .card:
                return CGSize(width: art.width + g, height: art.height + g)
            case .poster:
                let scale = 1 + g / max(art.width, art.height)
                return CGSize(width: (art.width * scale).rounded(), height: (art.height * scale).rounded())
            }
        }
        /// Scale that takes the host's focused size to `frame`; identity when they agree.
        var focusScale: CGAffineTransform {
            CGAffineTransform(scaleX: frame.width / hostSize.width, y: frame.height / hostSize.height)
        }
        /// Spacing between frames that leaves `tileGap` between the artwork.
        var gap: CGFloat { MediaRowMetrics.tileGap - (frame.width - art.width) }
        /// Frame inset that rests the first tile's artwork on `rowLeading`.
        var leading: CGFloat { MediaRowMetrics.rowLeading - (frame.width - art.width) / 2 }
    }

    // MARK: Tiles

    /// 2:3 poster (PosterCell, WatchlistPosterCell, detail Related row).
    static var poster: Tile {
        let width = gridWidth(columns: posterFullCount)
        return Tile(art: CGSize(width: width, height: width * 1.5), growth: CGSize(width: 20, height: 30))
    }
    static var posterWidth: CGFloat { poster.frame.width }
    static var posterHeight: CGFloat { poster.frame.height }

    /// 1:1 square for music (artist/album/track): the poster's grid column.
    static var music: Tile { square(columns: posterFullCount) }

    /// A 1:1 square on a `columns`-wide grid, for a surface that keeps its own column count.
    static func square(columns: Int) -> Tile {
        let width = gridWidth(columns: columns)
        return Tile(art: CGSize(width: width, height: width))
    }
    static var musicWidth: CGFloat { music.frame.width }
    static var musicHeight: CGFloat { music.frame.height }

    /// Continue Watching card: a 16:9 still over a 48pt band (Apple's Up Next).
    static let continueWatching: Tile = {
        let width = gridWidth(columns: cwFullCount)
        // Apple grows it 40 x 29; TVCardView's fixed 40 x 40 stays, since trimming it would squash the art.
        return Tile(art: CGSize(width: width, height: (width * 9 / 16 + 48).rounded()), lockup: .card)
    }()
    static let cwWidth = continueWatching.frame.width
    static let cwHeight = continueWatching.frame.height

    /// Playlists grid card: 16:9 art, three across.
    static let playlistFullCount = 3
    static let playlist: Tile = {
        let width = gridWidth(columns: playlistFullCount)
        return Tile(art: CGSize(width: width, height: (width * 9 / 16).rounded()), lockup: .card)
    }()

    /// Live TV Browse card (16:9), on the Apple TV app's live-row geometry:
    /// four across, its ~88pt margin and 40pt gap, so both peeks stay wide.
    /// 2·88 + 4·406 + 3·40 = 1920 → 48pt sliver. The Browse page only, with
    /// numbers of its own (frames, not artwork).
    static let liveLeading: CGFloat = 88
    static let liveWidth: CGFloat = 406
    static let liveHeight: CGFloat = 228
    static let liveGap: CGFloat = 40

    // MARK: Row chrome (vertical)

    /// Extra group height beneath tiles for the focus-scale growth.
    /// (Was 80 when tiles were smaller and carried a drop shadow.)
    static let focusGrowthPadding: CGFloat = 48

    /// Vertical insets around each row section. (Were 12 / 15.)
    static let rowTopInset: CGFloat = 8
    static let rowBottomInset: CGFloat = 8

    // MARK: Shelf header (measured on device, tvOS 27)

    /// Section header box, and how far its text baseline sits above the box bottom.
    static let headerHeight: CGFloat = 40
    static let headerBaselineInset: CGFloat = 8
    /// Header baseline to the resting artwork's top, and one row's artwork bottom to the next's top.
    static let headerBaselineToArt: CGFloat = 21.5
    static let shelfArtGap: CGFloat = 126

    static var headerFont: UIFont { .systemFont(ofSize: 31, weight: .semibold) }
    static var headerColor: UIColor { UIColor.white.withAlphaComponent(0.55) }

    /// Section insets (top, bottom) of a titled shelf row of `tile`s. The row's flow layout
    /// centres the frames in their focus padding, so half of it plus half the growth sits
    /// between the row edge and the artwork.
    static func shelfInsets(for tile: Tile) -> (top: CGFloat, bottom: CGFloat) {
        let half = (tile.growth.height + focusGrowthPadding) / 2
        let artBelowHeader = headerBaselineToArt - headerBaselineInset
        return (artBelowHeader - half, shelfArtGap - half - headerHeight - artBelowHeader)
    }

    /// Library poster grid: artwork top to the next row's artwork top (Apple's 55 between 390-tall tiles).
    static var posterGridPitch: CGFloat { poster.art.height + 55 }
}

extension NSLayoutConstraint {
    /// Returns self at priority 999, for cell constraints that meet TVCardView's zero-width first
    /// layout pass without logging unsatisfiable-constraint warnings.
    func withPriority(_ rawValue: Float) -> NSLayoutConstraint {
        priority = UILayoutPriority(rawValue)
        return self
    }
}
