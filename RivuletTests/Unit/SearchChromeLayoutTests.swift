// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import XCTest

@testable import Rivulet

/// The search page must start below the tvOS search chrome (#292). The chrome
/// height arrives only as `safeAreaInsets.top`, which `updateContentTopInset`
/// reads back. tvOS 26.5: field (80,60) 1760x70, keyboard (80,165) 1760x66,
/// safe area top 306.
final class SearchChromeLayoutTests: XCTestCase {

    private func seedRecents() {
        let items = (1...6).map { i in
            MediaItem(
                ref: MediaItemRef(providerID: "plex:test", itemID: "\(i)"),
                kind: .movie,
                title: "Recent \(i)",
                sortTitle: nil,
                overview: nil,
                year: 2020,
                runtime: nil,
                parentRef: nil,
                grandparentRef: nil,
                episodeNumber: nil,
                seasonNumber: nil,
                childProgress: nil,
                userState: MediaUserState(
                    isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
                artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
                parentArtwork: nil,
                grandparentArtwork: nil
            )
        }
        UserDefaults.standard.set(
            (try? JSONEncoder().encode(items)) ?? Data(), forKey: "recentSearchItems")
    }

    @MainActor
    func test_recentsRowStartsBelowTheSearchKeyboard() {
        seedRecents()

        let vc = SearchContainerViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()

        // The chrome is built asynchronously by the search controller.
        let settled = expectation(description: "chrome up")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        window.layoutIfNeeded()

        guard let collection = window.firstWideCollectionView() else {
            return XCTFail("no results collection view mounted")
        }
        guard let keyboard = window.searchKeyboardFrame() else {
            return XCTFail("the search chrome never came up, so nothing was measured")
        }

        XCTAssertGreaterThan(
            collection.safeAreaInsets.top, keyboard.maxY,
            "premise of this test: the chrome publishes its height as the safe area")

        XCTAssertGreaterThanOrEqual(
            collection.adjustedContentInset.top, keyboard.maxY,
            """
            the search page starts at \(collection.adjustedContentInset.top), above the \
            keyboard's bottom edge at \(keyboard.maxY) — the first row draws over the keyboard
            """)

        // And the rendered row, not just the inset.
        collection.layoutIfNeeded()
        if let cell = collection.visibleCells.first {
            let frame = cell.convert(cell.bounds, to: window)
            XCTAssertFalse(
                frame.intersects(keyboard),
                "the first row \(frame) overlaps the keyboard \(keyboard)")
        }

        // The page clips for the grid keyboard (#657); full screen here, so the clip cuts nothing.
        var page: UIView? = collection
        while let view = page, !(view.next is UIViewController) { page = view.superview }
        XCTAssertEqual(page.map { $0.convert($0.bounds, to: window) }, window.bounds)
    }

    /// Linear keyboard 1760x66 (measured); the grid shown for non-touch remotes is several rows.
    @MainActor
    func test_gridKeyboardIsToldApartFromLinear() {
        XCTAssertFalse(SearchContainerViewController.isGridKeyboard(CGSize(width: 1760, height: 66)))
        XCTAssertFalse(SearchContainerViewController.isGridKeyboard(CGSize(width: 1760, height: 70)))
        XCTAssertTrue(SearchContainerViewController.isGridKeyboard(CGSize(width: 700, height: 420)))
    }
}

extension UIWindow {
    fileprivate func firstWideCollectionView() -> UICollectionView? {
        func walk(_ view: UIView) -> UICollectionView? {
            if let collection = view as? UICollectionView, collection.bounds.width > 1000 {
                return collection
            }
            for sub in view.subviews { if let found = walk(sub) { return found } }
            return nil
        }
        return walk(self)
    }

    /// The tvOS search keyboard has no public type; it is found by class name.
    fileprivate func searchKeyboardFrame() -> CGRect? {
        func walk(_ view: UIView) -> CGRect? {
            if String(describing: type(of: view)).contains("UIKBFocusVCView") {
                return view.convert(view.bounds, to: self)
            }
            for sub in view.subviews { if let found = walk(sub) { return found } }
            return nil
        }
        return walk(self)
    }
}
