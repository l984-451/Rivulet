// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class BackdropPlaneArtworkTests: XCTestCase {
    private let catalogURL = URL(string: "https://images.invalid/backdrop/w300.webp?signature=catalog")!
    private let detailURL = URL(string: "https://images.invalid/backdrop/original.webp?signature=detail")!

    private func item(profile: String = "one", backdrop: URL?, poster: URL? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "silo:server:\(profile)", itemID: "movie:project-hail-mary"),
            kind: .movie, title: "Project Hail Mary", sortTitle: nil, overview: nil, year: 2026,
            runtime: 9000, parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 123, isFavorite: true, lastViewedAt: nil),
            artwork: MediaArtwork(poster: poster, backdrop: backdrop, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    func test_detailArtworkReplacesCatalogSourceUsedByFullScreenPlane() {
        let movie = item(backdrop: catalogURL)
        let plane = BackdropPlaneView(frame: .zero)
        plane.configure(items: [movie])
        XCTAssertEqual(plane.artworkURL(for: 0), catalogURL)

        plane.updateArtwork(MediaArtwork(poster: nil, backdrop: detailURL, thumbnail: nil, logo: nil), for: movie.ref)

        // The renderer now requests the complete server-selected URL, including its signature.
        XCTAssertEqual(plane.artworkURL(for: 0), detailURL)
        // Signed query parameters must survive promotion unchanged.
        XCTAssertEqual(plane.artworkURL(for: 0)?.query, "signature=detail")
    }

    func test_detailArtworkCannotCrossProfileOrReplaceAnotherItem() {
        let movie = item(backdrop: catalogURL)
        let otherProfile = item(profile: "two", backdrop: catalogURL)
        let plane = BackdropPlaneView(frame: .zero)
        plane.configure(items: [movie])
        let detail = MediaArtwork(poster: nil, backdrop: detailURL, thumbnail: nil, logo: nil)

        plane.updateArtwork(detail, for: otherProfile.ref)
        XCTAssertEqual(plane.artworkURL(for: 0), catalogURL)
        plane.updateArtwork(detail, for: MediaItemRef(providerID: movie.ref.providerID, itemID: "another-movie"))
        XCTAssertEqual(plane.artworkURL(for: 0), catalogURL)
    }

    func test_missingDetailBackdropKeepsLandscapeButUpgradesPosterFallback() {
        let landscape = item(backdrop: catalogURL)
        let detail = MediaArtwork(poster: detailURL, backdrop: nil, thumbnail: nil, logo: nil)
        let plane = BackdropPlaneView(frame: .zero)
        plane.configure(items: [landscape])
        plane.updateArtwork(detail, for: landscape.ref)
        XCTAssertEqual(plane.artworkURL(for: 0), catalogURL)

        let posterOnly = item(backdrop: nil, poster: catalogURL)
        plane.configure(items: [posterOnly])
        plane.updateArtwork(detail, for: posterOnly.ref)
        XCTAssertEqual(plane.artworkURL(for: 0), detailURL)

        plane.configure(items: [posterOnly])
        XCTAssertEqual(plane.artworkURL(for: 0), catalogURL, "A new configuration must not inherit an old detail response")
        XCTAssertNil(plane.artworkURL(for: 1))
    }
}
