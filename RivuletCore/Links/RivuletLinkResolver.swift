// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// Turns a `rivulet://` link into the item it names, on whichever signed-in server owns it.
enum RivuletLinkResolver {
    /// Any app can open a link and the key goes into a server path: letters and digits only.
    static func isSafe(_ link: RivuletLink) -> Bool {
        link.ratingKey.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The server a link names, else the selected Plex server (whose link carries its URL, informational).
    @MainActor
    static func provider(for link: RivuletLink, in browse: BrowseStore) -> (any MediaProvider)? {
        if let server = link.server, MediaProviderKind(providerID: server) != nil,
           !MediaItemRef(providerID: server, itemID: link.ratingKey).isPlex,
           let named = browse.provider(for: server) {
            return named
        }
        return browse.providersInPlay.selected
    }

    @MainActor
    static func item(for link: RivuletLink, in browse: BrowseStore) async -> MediaItem? {
        guard isSafe(link), let provider = provider(for: link, in: browse) else { return nil }
        return try? await provider.fullDetail(for: MediaItemRef(providerID: provider.id, itemID: link.ratingKey)).item
    }
}
