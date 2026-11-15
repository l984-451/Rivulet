// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FolderListingModel.swift
//  Rivulet
//
//  SwiftUI's view of a FolderListing, for iOS and Mac.
//

import Combine
import Foundation

@MainActor
final class FolderListingModel: ObservableObject {
    let listing: FolderListing
    @Published private(set) var entries: [FolderEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    /// Takes over `listing.onChange`, which has one owner.
    init(listing: FolderListing) {
        self.listing = listing
        listing.onChange = { [weak self] _ in self?.mirror() }
    }

    /// Loads the next page once `entry` is within 30 of the end.
    func loadMoreIfNeeded(after entry: FolderEntry) {
        guard entries.suffix(30).contains(where: { $0.id == entry.id }) else { return }
        listing.loadMore()
    }

    private func mirror() {
        entries = listing.entries
        isLoading = listing.isLoading
        failed = listing.error != nil
    }
}

extension MediaLibrary {
    /// Whether the library page offers Folders: a library with no metadata browses that way,
    /// and any Plex movie or TV library can.
    func offersFolders(on provider: (any MediaProvider)?) -> Bool {
        guard provider is any FolderProvider else { return false }
        return browsesByFolder || (provider?.kind == .plex && (kind == .movies || kind == .shows))
    }
}
