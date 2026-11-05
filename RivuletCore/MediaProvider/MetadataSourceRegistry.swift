// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Read-only catalog backends (TMDB), the sibling of MediaProviderRegistry.

import Foundation

@Observable @MainActor
final class MetadataSourceRegistry {
    static let shared = MetadataSourceRegistry()

    private(set) var sources: [String: any MetadataSource] = [:]

    init() {
        register(TMDBMetadataSource(), id: TMDBMediaMapper.providerID)
    }

    func source(for id: String) -> (any MetadataSource)? {
        sources[id]
    }

    func register(_ source: any MetadataSource, id: String) {
        sources[id] = source
    }

    func unregister(id: String) {
        sources.removeValue(forKey: id)
    }
}
