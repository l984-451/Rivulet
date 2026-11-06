// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

/// A Plex server's base URL and the token for it.
struct PlexServerAddress: Sendable {
    let address: String
    let token: String
}
