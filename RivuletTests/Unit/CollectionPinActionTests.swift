// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CollectionPinActionTests.swift
//  RivuletTests
//
//  A collection tile's menu in a library offers Pin to Home, Unpin from Home,
//  or nothing. A wrong answer either hides the only tile-side Unpin or offers
//  a Pin whose row can never render, so the choice is a pure static and this
//  covers it. Keys follow the measured P1 hub: a promoted collection hub's key
//  is /library/collections/{rk}/children (James Bond is rk 9144 on the test
//  server).
//

import XCTest
@testable import Rivulet

@MainActor
final class CollectionPinActionTests: XCTestCase {

    private let bond = "/library/collections/9144/children"

    /// No Home block to render into, so no menu.
    func test_libraryNotPinnedToHome_offersNothing() {
        XCTAssertNil(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: false, promotedChildrenKeys: [], childrenKey: bond, isPinned: false))
    }

    /// A pin whose library was later taken off Home still gets no tile menu.
    /// Settings > Home Rows is where it is unpinned.
    func test_libraryNotPinnedToHome_offersNothingEvenWhenPinned() {
        XCTAssertNil(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: false, promotedChildrenKeys: [], childrenKey: bond, isPinned: true))
    }

    /// Plex already puts a promoted collection on Home (P1 wins).
    func test_promotedInPlex_offersNothing() {
        XCTAssertNil(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true, promotedChildrenKeys: [bond], childrenKey: bond, isPinned: false))
        XCTAssertNil(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true, promotedChildrenKeys: [bond], childrenKey: bond, isPinned: true))
    }

    func test_otherPromotedCollection_doesNotBlock() {
        XCTAssertEqual(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true,
            promotedChildrenKeys: ["/library/collections/118562/children"],
            childrenKey: bond,
            isPinned: false), .pin)
    }

    func test_notPinned_offersPin() {
        XCTAssertEqual(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true, promotedChildrenKeys: [], childrenKey: bond, isPinned: false), .pin)
    }

    func test_pinned_offersUnpin() {
        XCTAssertEqual(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true, promotedChildrenKeys: [], childrenKey: bond, isPinned: true), .unpin)
    }

    /// Pin rows carry the pin's identity in their id, so they resolve through
    /// the prefix fallback, the way homeRow_ rows do.
    func test_pinRowId_resolvesToPinnedCollectionDescriptor() {
        XCTAssertEqual(SettingsDescriptorStore.descriptor(for: "pinnedCollection_library_abc123/9144")?.description,
                       "A collection you pinned from its tile menu. Hold Select to reorder, or Select to unpin it.")
    }
}
