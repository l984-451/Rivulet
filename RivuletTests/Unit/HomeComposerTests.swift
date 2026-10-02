// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeComposerTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

final class HomeComposerTests: XCTestCase {
    func test_synthesizesHubsFromPrimitives_forNonPlexProvider() async throws {
        let stub = StubMediaProvider()
        stub.continueWatchingItems = [makeItem("a"), makeItem("b")]
        stub.recentlyAddedItems = [makeItem("c")]

        let hubs = try await HomeComposer.compose(provider: stub)
        XCTAssertEqual(hubs.count, 2)
        XCTAssertEqual(hubs[0].title, "Continue Watching")
        XCTAssertEqual(hubs[0].items.count, 2)
        XCTAssertEqual(hubs[1].title, "Recently Added")
        XCTAssertEqual(hubs[1].items.count, 1)
    }

    func test_emptyPrimitives_returnsNoHubs() async throws {
        let stub = StubMediaProvider()
        let hubs = try await HomeComposer.compose(provider: stub)
        XCTAssertTrue(hubs.isEmpty)
    }

    private func makeItem(_ id: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "stub", itemID: id),
            kind: .movie, title: id, sortTitle: nil, overview: nil,
            year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }
}

/// Minimal stub provider used by HomeComposer tests.
final class StubMediaProvider: MediaProvider, @unchecked Sendable {
    nonisolated let id: String
    nonisolated let kind: MediaProviderKind
    nonisolated let displayName = "Stub"

    init(id: String = "stub", kind: MediaProviderKind = .plex) {
        self.id = id
        self.kind = kind
    }
    let connectionState = ConnectionState.connected
    let supportsWatchlist = false

    var continueWatchingItems: [MediaItem] = []
    var continueWatchingError: Error?
    var recentlyAddedItems: [MediaItem] = []
    /// Keyed by the parent's itemID (`children`) / the show's itemID (`allEpisodes`).
    var childrenByParent: [String: [MediaItem]] = [:]
    var episodesByShow: [String: [MediaItem]] = [:]

    var libraryList: [MediaLibrary] = []
    var librariesError: Error?
    func libraries() async throws -> [MediaLibrary] {
        if let librariesError { throw librariesError }
        return libraryList
    }
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        PagedResult(items: [], total: 0, nextPage: nil)
    }
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] { childrenByParent[itemRef.itemID] ?? [] }
    var searchItems: [MediaItem] = []
    func search(_ query: String) async throws -> [MediaItem] { searchItems }
    /// What `related(for:kind:)` answers, and the kinds it was asked for.
    var relatedContent = RelatedContent(items: [], collection: nil)
    private(set) var relatedKinds: [MediaKind] = []
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        relatedKinds.append(kind)
        return relatedContent
    }
    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] { episodesByShow[showRef.itemID] ?? [] }
    /// What the playback calls answer (nil throws `.notFound`), and the calls
    /// made, as "detail(m1)", "stream(m1,nil)", "extras(m1,src)".
    var detailResult: MediaItemDetail?
    var streamResult: StreamInfo?
    var extrasResult = PlaybackExtras()
    private let callLock = NSLock()
    private var recordedCalls: [String] = []
    var playbackCalls: [String] { callLock.withLock { recordedCalls } }
    private func recordCall(_ call: String) { callLock.withLock { recordedCalls.append(call) } }
    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        recordCall("detail(\(itemRef.itemID))")
        guard let detailResult else { throw MediaProviderError.notFound }
        return detailResult
    }
    func playbackExtras(for itemRef: MediaItemRef, sourceID: String?) async -> PlaybackExtras {
        recordCall("extras(\(itemRef.itemID),\(sourceID ?? "nil"))")
        return extrasResult
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        if let continueWatchingError { throw continueWatchingError }
        return continueWatchingItems
    }
    func recentlyAdded(limit: Int) async throws -> [MediaItem] { recentlyAddedItems }
    func hubs() async throws -> [MediaHub] { [] }
    var hubsByLibrary: [String: [MediaHub]] = [:]
    var hubsError: Error?
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        if let hubsError { throw hubsError }
        return hubsByLibrary[library.id] ?? []
    }
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?) async throws -> StreamInfo {
        recordCall("stream(\(itemRef.itemID),\(sourceID ?? "nil"))")
        guard let streamResult else { throw MediaProviderError.notFound }
        return streamResult
    }
    /// What `transcodeStream` answers, and what it was asked for.
    var transcodeResult: StreamInfo?
    private(set) var transcodeRequests: [(ref: MediaItemRef, sourceID: String?, startTime: TimeInterval)] = []
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval) async throws -> StreamInfo {
        transcodeRequests.append((itemRef, sourceID, startTime))
        guard let transcodeResult else { throw MediaProviderError.transcodeRequired }
        return transcodeResult
    }
    /// What `progressReporter(for:sourceID:playSessionID:)` hands out.
    var reporter: any Rivulet.ProgressReporter = StubReporter()
    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any Rivulet.ProgressReporter {
        reporter
    }
    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {}
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {}
    private(set) var markedPlayed: [MediaItemRef] = []
    private(set) var markedUnplayed: [MediaItemRef] = []
    func markPlayed(_ itemRef: MediaItemRef) async throws { markedPlayed.append(itemRef) }
    func markUnplayed(_ itemRef: MediaItemRef) async throws { markedUnplayed.append(itemRef) }
    private(set) var refreshed: [MediaItemRef] = []
    func refreshMetadata(_ itemRef: MediaItemRef) async throws { refreshed.append(itemRef) }
    private(set) var progressUpdates: [(MediaItemRef, TimeInterval)] = []
    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        progressUpdates.append((itemRef, position))
    }
    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool { false }
    func addToWatchlist(_ ref: MediaItemRef) async throws {}
    func removeFromWatchlist(_ ref: MediaItemRef) async throws {}
}

struct StubReporter: Rivulet.ProgressReporter {
    func start(position: TimeInterval) async {}
    func progress(position: TimeInterval) async {}
    func paused(at position: TimeInterval) async {}
    func stopped(at position: TimeInterval) async {}
}

/// Records every call, in order, as "start", "progress(30.0)", "paused(5.0)", "stopped(95.0)".
final class RecordingReporter: Rivulet.ProgressReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    private func record(_ event: String) { lock.withLock { recorded.append(event) } }
    func start(position: TimeInterval) async { record("start") }
    func progress(position: TimeInterval) async { record("progress(\(position))") }
    func paused(at position: TimeInterval) async { record("paused(\(position))") }
    func stopped(at position: TimeInterval) async { record("stopped(\(position))") }
}
