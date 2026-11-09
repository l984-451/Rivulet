// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoListingModel.swift
//  Rivulet
//
//  SwiftUI's view of a PhotoListing, for iOS and Mac.
//

import Combine
import Foundation

@MainActor
final class PhotoListingModel: ObservableObject {
    let listing: PhotoListing
    @Published private(set) var folders: [PhotoItem]
    @Published private(set) var media: [PhotoItem]
    @Published private(set) var isLoading: Bool
    @Published private(set) var failed: Bool

    /// Takes over `listing.onChange`, which has one owner.
    init(listing: PhotoListing) {
        self.listing = listing
        folders = listing.folders
        media = listing.media
        isLoading = listing.isLoading
        failed = listing.error != nil
        listing.onChange = { [weak self] _ in self?.mirror() }
    }

    /// Loads the next page once `item` is within 30 of the end.
    func loadMoreIfNeeded(after item: PhotoItem) {
        guard media.suffix(30).contains(where: { $0.ref == item.ref }) else { return }
        listing.loadMore()
    }

    private func mirror() {
        folders = listing.folders
        media = listing.media
        isLoading = listing.isLoading
        failed = listing.error != nil
    }
}
