// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import UIKit
@testable import Rivulet

@MainActor
struct HeroReconfigurationTests {
    @Test(arguments: [0, 2])
    func plexRefreshDuringPagingKeepsNewSlideVisible(initialIndex: Int) async throws {
        let overlay = HeroOverlayView()
        let oldItems = (0..<3).map { PlexMetadata(type: "movie", title: "Old \($0)") }
        let newItems = (0..<3).map { PlexMetadata(type: "movie", title: "New \($0)") }
        overlay.configure(items: oldItems, serverURL: "", authToken: "", initialIndex: 0)
        let row = try #require(overlay.subviews.compactMap { $0 as? HeroButtonRowView }.first)
        row.nextButton.sendActions(for: .primaryActionTriggered)
        try #require(overlay.currentIndex == 1)

        overlay.configure(items: newItems, serverURL: "", authToken: "", initialIndex: initialIndex)
        await finishPendingSwap()

        #expect(overlay.currentIndex == initialIndex)
        try expectVisibleTitle("New \(initialIndex)", in: overlay)
        #expect(labels(in: overlay).contains { $0.text == "New 1" } == false)
    }

    @Test(arguments: [0, 2])
    func mediaRefreshDuringPagingKeepsNewSlideVisible(initialIndex: Int) async throws {
        let overlay = MediaItemHeroOverlayView()
        overlay.configure(items: (0..<3).map { item("Old \($0)") }, initialIndex: 0,
                          onIndexChanged: { _, _, _ in }, onPlay: { _ in }, onInfo: { _ in })
        overlay.advance()
        try #require(overlay.currentIndex == 1)

        overlay.configure(items: (0..<3).map { item("New \($0)") }, initialIndex: initialIndex,
                          onIndexChanged: { _, _, _ in }, onPlay: { _ in }, onInfo: { _ in })
        await finishPendingSwap()

        #expect(overlay.currentIndex == initialIndex)
        try expectVisibleTitle("New \(initialIndex)", in: overlay)
        #expect(labels(in: overlay).contains { $0.text == "New 1" } == false)
    }

    private func finishPendingSwap() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + HeroPageMotion.metadataDelay + 0.1) {
                continuation.resume()
            }
        }
    }

    private func expectVisibleTitle(_ title: String, in overlay: UIView,
                                    sourceLocation: SourceLocation = #_sourceLocation) throws {
        let label = try #require(labels(in: overlay).first { $0.text == title }, sourceLocation: sourceLocation)
        var view: UIView? = label
        while let current = view {
            #expect(current.alpha == 1, sourceLocation: sourceLocation)
            #expect(current.isHidden == false, sourceLocation: sourceLocation)
            view = current.superview
        }
    }

    private func labels(in view: UIView) -> [UILabel] {
        (view as? UILabel).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    private func item(_ title: String) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: "test", itemID: title), kind: .movie,
                  title: title, sortTitle: nil, overview: nil, year: nil, runtime: nil,
                  parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
                  childProgress: nil,
                  userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                  artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                  parentArtwork: nil, grandparentArtwork: nil)
    }
}
