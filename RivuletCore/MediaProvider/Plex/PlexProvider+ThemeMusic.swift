// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

extension PlexProvider {
    /// The show's theme tune. A show carries `theme`, a season `parentTheme`, an episode
    /// `grandparentTheme`, so any of the three answers with its show's. The full-metadata read
    /// is the one a detail page already makes, so within its short reuse window this costs no
    /// request of its own.
    func themeMusicURL(for itemRef: MediaItemRef) async throws -> URL? {
        guard itemRef.providerID == id else { return nil }
        return try await plexCall {
            let meta = try await networkManager.getFullMetadata(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID)
            return PlexMediaMapper.playableURL(
                meta.theme ?? meta.parentTheme ?? meta.grandparentTheme,
                serverURL: serverURL, authToken: authToken)
        }
    }
}
