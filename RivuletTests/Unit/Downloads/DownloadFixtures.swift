// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
@testable import Rivulet

enum DownloadFixtures {
    static func item(_ id: String, kind: MediaKind = .movie, providerID: String = "plex:srv") -> MediaItem {
        JellyfinFixtures.mediaItem(id, kind: kind, providerID: providerID)
    }
}
