// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CollectionPageRoutingTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

/// Stands in for whatever is on screen when a tile is tapped. `below` fakes
/// the controller that presented it, and `present` records instead of
/// presenting, so the routing walk runs with no window.
private final class RecordingPresenter: UIViewController {
    var below: UIViewController?
    private(set) var presented: [UIViewController] = []

    override var presentingViewController: UIViewController? { below }

    override func present(_ viewControllerToPresent: UIViewController,
                          animated flag: Bool,
                          completion: (() -> Void)? = nil) {
        presented.append(viewControllerToPresent)
    }
}

@MainActor
final class CollectionPageRoutingTests: XCTestCase {

    private func item(_ key: String, kind: MediaKind) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: key),
            kind: kind,
            title: "Item \(key)",
            sortTitle: nil,
            overview: nil,
            year: nil,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    func test_nonCollection_isNotRouted() {
        let presenter = RecordingPresenter()

        let opened = PlexHomeViewController.openCollectionIfNeeded(item("1", kind: .movie), from: presenter)

        XCTAssertFalse(opened)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func test_collection_presentsBlurFadePage() throws {
        let presenter = RecordingPresenter()
        var dismissed = false

        let opened = PlexHomeViewController.openCollectionIfNeeded(
            item("9144", kind: .collection), from: presenter, onDismiss: { dismissed = true })

        XCTAssertTrue(opened)
        XCTAssertEqual(presenter.presented.count, 1)
        let page = try XCTUnwrap(presenter.presented.first as? PlexHomeViewController)
        guard case .collection(let shown) = page.mode else {
            return XCTFail("presented page is not in collection mode")
        }
        XCTAssertEqual(shown.ref.itemID, "9144")
        XCTAssertEqual(page.modalPresentationStyle, .overFullScreen)
        // UIKit holds the transitioning delegate weakly: nil here means the
        // page does not keep its own reference.
        XCTAssertTrue(page.transitioningDelegate is BlurFadeTransitioningDelegate)
        page.onDismiss?()
        XCTAssertTrue(dismissed)
    }

    func test_sameCollectionBelowPresenter_doesNotStack() {
        // Collection page, a member's detail on top of it, and the detail's
        // trailing tile is the same collection. Only the no-stack half is
        // checkable here: the fake page never really presents, so the unwind
        // (dismiss) is device check 6h.
        let page = PlexHomeViewController(mode: .collection(item("9144", kind: .collection)))
        let memberDetail = RecordingPresenter()
        memberDetail.below = page

        let opened = PlexHomeViewController.openCollectionIfNeeded(
            item("9144", kind: .collection), from: memberDetail)

        XCTAssertTrue(opened)
        XCTAssertTrue(memberDetail.presented.isEmpty, "a second page for the same collection was stacked")
    }

    func test_otherCollectionBelowPresenter_presentsNewPage() {
        let page = PlexHomeViewController(mode: .collection(item("9144", kind: .collection)))
        let memberDetail = RecordingPresenter()
        memberDetail.below = page

        let opened = PlexHomeViewController.openCollectionIfNeeded(
            item("118562", kind: .collection), from: memberDetail)

        XCTAssertTrue(opened)
        XCTAssertEqual(memberDetail.presented.count, 1)
    }
}
