// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// RivuletTests/Unit/MusicProviderRegistryTests.swift
import XCTest
@testable import Rivulet

@MainActor
final class MusicProviderRegistryTests: XCTestCase {

    func test_register_and_lookup() {
        let registry = MusicProviderRegistry()
        let provider = StubMusicProvider(id: "plex:abc")
        registry.register(provider)
        XCTAssertNotNil(registry.provider(for: "plex:abc"))
        XCTAssertEqual(registry.provider(for: "plex:abc")?.id, "plex:abc")
    }

    func test_register_dedupes_by_id() {
        let registry = MusicProviderRegistry()
        registry.register(StubMusicProvider(id: "plex:abc"))
        registry.register(StubMusicProvider(id: "plex:abc"))
        XCTAssertEqual(registry.providers.count, 1)
    }

    func test_unregister_removes() {
        let registry = MusicProviderRegistry()
        registry.register(StubMusicProvider(id: "plex:abc"))
        registry.unregister(providerID: "plex:abc")
        XCTAssertNil(registry.provider(for: "plex:abc"))
    }

    // A new address for a restored session registers a second id: the newest is the server.
    func test_primaryProvider_is_the_plex_provider_registered_last() {
        let registry = MusicProviderRegistry()
        for id in ["plex:a", "plex:b", "plex:c", "plex:d"] { registry.register(StubMusicProvider(id: id)) }
        XCTAssertEqual(registry.primaryProvider?.id, "plex:d")
        XCTAssertNotNil(registry.provider(for: MediaItemRef(providerID: "plex:a", itemID: "1")))
        registry.unregister(providerID: "plex:d")
        XCTAssertNil(registry.primaryProvider)
    }

    func test_signedInProviders_plexFirst_thenOtherKindsSortedByID() {
        let registry = MusicProviderRegistry()
        registry.register(StubMusicProvider(id: "jellyfin:b", kind: .jellyfin))
        registry.register(StubMusicProvider(id: "plex:old"))
        registry.register(StubMusicProvider(id: "jellyfin:a", kind: .jellyfin))
        registry.register(StubMusicProvider(id: "plex:new"))
        XCTAssertEqual(registry.signedInProviders.map(\.id), ["plex:new", "jellyfin:a", "jellyfin:b"],
                       "stale Plex ids stay out; the order does not follow registration")
    }

    func test_missing_id_returns_nil() {
        let registry = MusicProviderRegistry()
        XCTAssertNil(registry.provider(for: "nope"))
    }
}
