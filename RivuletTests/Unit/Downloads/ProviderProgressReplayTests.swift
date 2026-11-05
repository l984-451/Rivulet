// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ProviderProgressReplayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let providerID = "jellyfin:srv"

    private func entry(_ id: String, offset: Int = 600_000, watched: Bool = false, seconds: TimeInterval = 100,
                       provider: String = "jellyfin:srv", account: String? = "u1", profile: String? = nil)
        -> OfflineProgressLog.Entry {
        .init(providerID: provider, profileID: profile, accountID: account, itemID: id, offsetMs: offset,
              durationMs: 1_320_000, watched: watched, at: t0.addingTimeInterval(seconds))
    }

    private func stub(lastViewed: [String: Date] = [:], missing: Set<String> = []) -> StubMediaProvider {
        let stub = StubMediaProvider(id: providerID, kind: .jellyfin)
        stub.detailResultFor = { ref in
            if missing.contains(ref.itemID) { throw MediaProviderError.notFound }
            var item = JellyfinFixtures.mediaItem(ref.itemID, providerID: "jellyfin:srv")
            item.userState = MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: lastViewed[ref.itemID])
            return MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                                   chapters: [], mediaSources: [], trailerURL: nil, contentRating: nil, nextEpisode: nil,
                                   collections: [])
        }
        return stub
    }

    // MARK: - Which entries

    func test_due_isThisServerAccountAndProfile() {
        let mine = entry("a")
        let entries = [
            mine,
            entry("b", provider: "emby:srv"),
            entry("c", account: "u2"),
            entry("d", profile: "7"),
            entry("e", provider: "plex:srv", account: nil),
        ]
        XCTAssertEqual(ProviderProgressReplay.due(entries, providerID: providerID, accountID: "u1", profileID: nil), [mine])
        XCTAssertEqual(ProviderProgressReplay.due(entries, providerID: providerID, accountID: "u1", profileID: "7").map(\.itemID), ["d"])
    }

    // MARK: - Replay

    func test_replay_sendsPositionInSeconds_andMarksPlayedWhenWatched() async {
        let provider = stub()
        var removed: [String] = []
        let sent = await ProviderProgressReplay.replay(
            [entry("a", offset: 640_000), entry("b", offset: 1_300_000, watched: true)],
            provider: provider, remove: { removed.append($0.itemID) })
        XCTAssertTrue(sent)
        XCTAssertEqual(provider.progressUpdates.map { "\($0.0.itemID)@\($0.1)" }, ["a@640.0", "b@1300.0"])
        XCTAssertEqual(provider.markedPlayed.map(\.itemID), ["b"])
        XCTAssertEqual(removed, ["a", "b"])
    }

    func test_replay_usesTheEntrysServerNotThePlexKey() async {
        let provider = stub()
        _ = await ProviderProgressReplay.replay([entry("a")], provider: provider, remove: { _ in })
        XCTAssertEqual(provider.progressUpdates.first?.0, MediaItemRef(providerID: providerID, itemID: "a"))
    }

    func test_replay_skipsWhatTheServerSawLaterAndStillRemovesIt() async {
        let provider = stub(lastViewed: ["a": t0.addingTimeInterval(500)])
        var removed: [String] = []
        let sent = await ProviderProgressReplay.replay([entry("a", seconds: 100)], provider: provider, remove: { removed.append($0.itemID) })
        XCTAssertFalse(sent)
        XCTAssertTrue(provider.progressUpdates.isEmpty)
        XCTAssertEqual(removed, ["a"])
    }

    func test_replay_dropsAnItemTheServerLost() async {
        var removed: [String] = []
        let sent = await ProviderProgressReplay.replay([entry("gone")], provider: stub(missing: ["gone"]), remove: { removed.append($0.itemID) })
        XCTAssertFalse(sent)
        XCTAssertEqual(removed, ["gone"])
    }

    func test_replay_unreachableStopsTheRunAndKeepsTheRest() async {
        let provider = stub()
        provider.progressError = MediaProviderError.unreachable
        var removed: [String] = []
        let sent = await ProviderProgressReplay.replay([entry("a"), entry("b")], provider: provider, remove: { removed.append($0.itemID) })
        XCTAssertFalse(sent)
        XCTAssertEqual(removed, [])
    }

    func test_replay_signedOutKeepsEverything() async {
        let provider = stub()
        provider.progressError = MediaProviderError.unauthorized
        var removed: [String] = []
        _ = await ProviderProgressReplay.replay([entry("a"), entry("b")], provider: provider, remove: { removed.append($0.itemID) })
        XCTAssertEqual(removed, [])
    }

    func test_replay_aServerFaultKeepsThatEntryAndGoesOn() async {
        let provider = stub()
        provider.progressErrorFor = { $0.itemID == "a" ? MediaProviderError.backendSpecific(underlying: "HTTP 500") : nil }
        var removed: [String] = []
        let sent = await ProviderProgressReplay.replay([entry("a"), entry("b")], provider: provider, remove: { removed.append($0.itemID) })
        XCTAssertTrue(sent)
        XCTAssertEqual(removed, ["b"])
    }
}
