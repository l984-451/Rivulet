// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BelowFoldRailScrollTests.swift
//  RivuletTests
//
//  Moving across the season pills switches the episode rail by scrolling the
//  orthogonal section to that season's first episode (no press needed). The
//  focus engine is not in play here; this drives the same entry point the pill
//  focus handler calls and checks the rail's own scroller moved.
//

import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class BelowFoldRailScrollTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let railGap: CGFloat = 16
    /// Enough episodes that season 2's first card can sit at the leading edge
    /// without the scroller clamping at the end of the rail.
    private let episodesPerSeason = 8

    func test_switchingSeasonScrollsTheRailToItsFirstEpisode() throws {
        let stub = StubMediaProvider()
        stub.childrenByParent["show"] = [item("s1", .season, parent: "show"), item("s2", .season, parent: "show")]
        stub.episodesByShow["show"] = (1...(2 * episodesPerSeason)).map { n in
            let first = n <= episodesPerSeason
            return item("e\(n)", .episode, parent: first ? "s1" : "s2", season: first ? 1 : 2, episode: n)
        }
        MediaProviderRegistry.shared.register(stub)
        defer { MediaProviderRegistry.shared.unregister(providerID: stub.id) }

        let window = UIWindow()
        window.frame = screen
        let view = BelowFoldCollectionView(frame: screen)
        window.addSubview(view)
        window.isHidden = false

        let loaded = expectation(description: "show loaded")
        view.onSeasonsLoaded = { _, _ in loaded.fulfill() }
        view.configure(item: item("show", .show, parent: nil), detail: nil)
        wait(for: [loaded], timeout: 3)
        view.layoutIfNeeded()

        let scroller = try XCTUnwrap(railScroller(in: view), "the episode rail's orthogonal scroller was not realized")
        let rest = scroller.contentOffset.x

        view.scrollEpisodesToSeason(seasonRefID: "s2")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))

        // Season 1's cards and the divider that opens season 2.
        let expected = CGFloat(episodesPerSeason) * (EpisodeCell.cardWidth + railGap) + (SeasonDividerCell.cardWidth + railGap)
        XCTAssertEqual(scroller.contentOffset.x - rest, expected, accuracy: 2)

        view.scrollEpisodesToSeason(seasonRefID: "s1")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        XCTAssertEqual(scroller.contentOffset.x, rest, accuracy: 2)
    }

    /// The compositional layout's orthogonal section scrolls in its own embedded
    /// scroll view: the one (other than the collection) with an episode cell in it.
    private func railScroller(in root: UIView) -> UIScrollView? {
        var stack: [UIView] = [root]
        while let v = stack.popLast() {
            if let scroll = v as? UIScrollView, !(scroll is UICollectionView), contains(EpisodeCollectionCell.self, in: scroll) {
                return scroll
            }
            stack.append(contentsOf: v.subviews)
        }
        return nil
    }

    private func contains(_ type: AnyClass, in root: UIView) -> Bool {
        var stack = root.subviews
        while let v = stack.popLast() {
            if v.isKind(of: type) { return true }
            stack.append(contentsOf: v.subviews)
        }
        return false
    }

    private func item(_ id: String, _ kind: MediaKind, parent: String?,
                      season: Int? = nil, episode: Int? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "stub", itemID: id),
            kind: kind, title: id, sortTitle: nil, overview: nil,
            year: nil, runtime: nil,
            parentRef: parent.map { MediaItemRef(providerID: "stub", itemID: $0) },
            grandparentRef: nil,
            episodeNumber: episode, seasonNumber: season, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }
}
