// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import XCTest

@testable import Rivulet

/// The search page must start BELOW the tvOS search chrome (#292).
///
/// This cannot be eyeballed from the source: the search controller presents
/// full screen into the window, leaves the results view full screen at (0,0),
/// and hands over its chrome height only as `safeAreaInsets.top`. The page sets
/// `contentInsetAdjustmentBehavior = .never` for the hero, so that inset is only
/// applied because `updateContentTopInset` reads it back. Measured on tvOS 26.5:
/// field (80,60) 1760x70, keyboard (80,165) 1760x66, safe area top 306.
///
/// Without the fix the recents row draws from y=0, through the keyboard, and the
/// keyboard cannot be reached — which is exactly what shipped.
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
