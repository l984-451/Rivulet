// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Loading settings must not write them: a fresh device's defaults would otherwise look like choices and beat a configured device's.
@MainActor
final class LoadTimeWritesTests: XCTestCase {
    private let defaults = UserDefaults.standard

    private func keys(startingWith prefixes: [String]) -> [String] {
        defaults.dictionaryRepresentation().keys.filter { key in prefixes.contains { key.hasPrefix($0) } }
    }

    func test_loadingLibrarySettingsWritesNothing() {
        let prefixes = ["hiddenLibraryKeys", "libraryOrder", "librarySortOptions"]
        let saved = Dictionary(uniqueKeysWithValues: keys(startingWith: prefixes).map { ($0, defaults.object(forKey: $0)!) })
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        for key in saved.keys { defaults.removeObject(forKey: key) }

        LibrarySettingsManager.shared.reloadFromDefaults()

        XCTAssertEqual(keys(startingWith: prefixes), [])
    }

    func test_loadingLiveTVFavoritesWritesNothing() {
        let keys = ["liveTVFavoriteChannelIds", "liveTVUnfavoritedChannelIds"]
        let saved = keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        keys.forEach(defaults.removeObject)

        LiveTVDataStore.shared.loadFavorites()

        for key in keys { XCTAssertNil(defaults.object(forKey: key), key) }
    }

    func test_loadingFavoritesStillReadsWhatIsSaved() {
        let saved = defaults.object(forKey: "liveTVFavoriteChannelIds")
        defer { defaults.set(saved, forKey: "liveTVFavoriteChannelIds"); LiveTVDataStore.shared.loadFavorites() }
        defaults.set(["xtream:xtream:ab:1"], forKey: "liveTVFavoriteChannelIds")
        LiveTVDataStore.shared.loadFavorites()
        XCTAssertEqual(LiveTVDataStore.shared.favoriteIds, ["xtream:xtream:ab:1"])
    }
}

/// A source with a slow connection check stands in for "the network is slow when a source is removed".
private struct SlowSource: LiveTVProvider {
    let sourceType = LiveTVSourceType.xtream
    let sourceId = "xtream:slowstub"
    let displayName = "Slow"
    var isConnected: Bool { get async { try? await Task.sleep(for: .milliseconds(600)); return true } }
    func fetchChannels() async throws -> [UnifiedChannel] { [] }
    func refreshChannels() async throws -> [UnifiedChannel] { [] }
    func fetchEPG(for channels: [UnifiedChannel], startDate: Date, endDate: Date) async throws -> [String: [UnifiedProgram]] { [:] }
    func getCurrentProgram(for channel: UnifiedChannel) async -> UnifiedProgram? { nil }
    func buildStreamURL(for channel: UnifiedChannel) -> URL? { nil }
}

@MainActor
final class LiveTVRemovalOrderTests: XCTestCase {
    func test_theRemovalIsRecordedBeforeTheSlowNetworkWork() async {
        let store = LiveTVDataStore.shared
        store.debugAddTransientSource(SlowSource())
        let id = "xtream:removalorder\(UInt32.random(in: 0...UInt32.max))"
        let removal = Task { await store.removeSource(id: id, scope: .thisDevice) }
        // Past the point where the old order would still be waiting on the slow source.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(CloudSync.shared.isSignedOutHere(accountID: LiveTVDataStore.syncID(forSource: id)))
        await removal.value
        await store.removeSourceLocally(id: SlowSource().sourceId)
    }
}
