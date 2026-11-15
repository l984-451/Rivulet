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
    var sortOverride: [LibrarySortOption]?
    func sortOptions(for kind: MediaLibrary.LibraryKind) -> [LibrarySortOption] {
        sortOverride ?? LibrarySortOption.expressible(for: kind)
    }

    var continueWatchingItems: [MediaItem] = []
    var continueWatchingError: Error?
    var recentlyAddedItems: [MediaItem] = []
    /// Keyed by the parent's itemID (`children`) / the show's itemID (`allEpisodes`).
    var childrenByParent: [String: [MediaItem]] = [:]
    var episodesByShow: [String: [MediaItem]] = [:]

    var libraryList: [MediaLibrary] = []
    var librariesError: Error?

    var favoritesSupported = false
    var supportsFavorites: Bool { favoritesSupported }
    /// What `favorites(in:limit:)` answers, by library id.
    var favoritesByLibrary: [String: [MediaItem]] = [:]
    func favorites(in library: MediaLibrary, limit: Int) async throws -> [MediaItem] { favoritesByLibrary[library.id] ?? [] }

    var supportsPlaylists = false
    var playlistList: [MediaPlaylist] = []
    /// Awaited before `videoPlaylists()` answers, so a test can hold a refresh open.
    var playlistsGate: (@Sendable () async -> Void)?
    func videoPlaylists() async throws -> [MediaPlaylist] {
        await playlistsGate?()
        return playlistList
    }
    func libraries() async throws -> [MediaLibrary] {
        if let librariesError { throw librariesError }
        return libraryList
    }
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        PagedResult(items: [], total: 0, nextPage: nil)
    }
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] { childrenByParent[itemRef.itemID] ?? [] }
    var searchItems: [MediaItem] = []
    var searchError: Error?
    func search(_ query: String) async throws -> [MediaItem] {
        if let searchError { throw searchError }
        return searchItems
    }
    /// What `ownedItems(matching:limit:)` answers, and the titles it was asked for.
    var ownedItemsResult: [MediaItem] = []
    private(set) var ownedRequests: [[TitleMatch]] = []
    func ownedItems(matching titles: [TitleMatch], limit: Int) async throws -> [MediaItem] {
        ownedRequests.append(titles)
        return Array(ownedItemsResult.prefix(limit))
    }
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
    /// What a capped `resolveStream` answers (nil: `streamResult`), or throws.
    var cappedStreamResult: StreamInfo?
    var cappedStreamError: Error?
    var extrasResult = PlaybackExtras()
    private let callLock = NSLock()
    private var recordedCalls: [String] = []
    var playbackCalls: [String] { callLock.withLock { recordedCalls } }
    private var recordedBitrates: [Int?] = []
    /// `maxBitrate` of each `resolveStream`, in order.
    var resolveBitrates: [Int?] { callLock.withLock { recordedBitrates } }
    private func recordCall(_ call: String) { callLock.withLock { recordedCalls.append(call) } }
    /// Answers `fullDetail` per item when set.
    var detailResultFor: (@Sendable (MediaItemRef) throws -> MediaItemDetail)?
    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail {
        recordCall("detail(\(itemRef.itemID))")
        if let detailResultFor { return try detailResultFor(itemRef) }
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
    /// Libraries whose `hubs(in:)` throws, the others answering.
    var failingHubLibraries: Set<String> = []
    /// Awaited before `hubs(in:)` answers, so a test can hold library fetches open.
    var hubsGate: (@Sendable () async throws -> Void)?
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        try await hubsGate?()
        if let hubsError { throw hubsError }
        if failingHubLibraries.contains(library.id) { throw MediaProviderError.unreachable }
        return hubsByLibrary[library.id] ?? []
    }
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        recordCall("stream(\(itemRef.itemID),\(sourceID ?? "nil"))")
        callLock.withLock { recordedBitrates.append(maxBitrate) }
        if maxBitrate != nil {
            if let cappedStreamError { throw cappedStreamError }
            if let cappedStreamResult { return cappedStreamResult }
        }
        guard let streamResult else { throw MediaProviderError.notFound }
        return streamResult
    }
    /// `startTime` of each `resolveStream`, in order.
    private var recordedStarts: [TimeInterval] = []
    var resolveStartTimes: [TimeInterval] { callLock.withLock { recordedStarts } }
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?,
                       startTime: TimeInterval) async throws -> StreamInfo {
        callLock.withLock { recordedStarts.append(startTime) }
        return try await resolveStream(for: itemRef, sourceID: sourceID, maxBitrate: maxBitrate)
    }
    /// What `transcodeStream` answers, and what it was asked for.
    var transcodeResult: StreamInfo?
    private(set) var transcodeRequests: [(ref: MediaItemRef, sourceID: String?, startTime: TimeInterval)] = []
    private(set) var transcodeBitrates: [Int?] = []
    private(set) var transcodeTracks: [(audio: Int?, subtitle: Int?)] = []
    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval,
                         maxBitrate: Int?, audioStreamIndex: Int?, subtitleStreamIndex: Int?) async throws -> StreamInfo {
        transcodeRequests.append((itemRef, sourceID, startTime))
        transcodeBitrates.append(maxBitrate)
        transcodeTracks.append((audioStreamIndex, subtitleStreamIndex))
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
    var markPlayedError: Error?
    func markPlayed(_ itemRef: MediaItemRef) async throws {
        if let markPlayedError { throw markPlayedError }
        markedPlayed.append(itemRef)
    }
    func markUnplayed(_ itemRef: MediaItemRef) async throws { markedUnplayed.append(itemRef) }
    private(set) var refreshed: [MediaItemRef] = []
    func refreshMetadata(_ itemRef: MediaItemRef) async throws { refreshed.append(itemRef) }
    private(set) var progressUpdates: [(MediaItemRef, TimeInterval)] = []
    var progressError: Error?
    /// Fails `updateProgress` for some items only.
    var progressErrorFor: (@Sendable (MediaItemRef) -> Error?)?
    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        if let progressError { throw progressError }
        if let error = progressErrorFor?(itemRef) { throw error }
        progressUpdates.append((itemRef, position))
    }
    /// What `canDownloadMedia` answers in turn (the last repeats), and how often it was asked.
    var downloadAnswers: [Result<Bool, Error>] = []
    private(set) var downloadAsks = 0
    func canDownloadMedia() async throws -> Bool {
        downloadAsks += 1
        guard !downloadAnswers.isEmpty else { return false }
        let answer = downloadAnswers.count > 1 ? downloadAnswers.removeFirst() : downloadAnswers[0]
        return try answer.get()
    }
    var accountIDValue: String?
    var accountID: String? { accountIDValue }
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
