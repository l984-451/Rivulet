// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  PlaylistPlaybackTests.swift
//  RivuletTests
//

import Combine
import XCTest
@testable import Rivulet

/// The player walking a playlist: next entry, end of list, resume points. Provider
/// path, so nothing touches a server; a stream with no URL fails its start fast.
@MainActor
final class PlaylistPlaybackTests: XCTestCase {
    private let pid = "jellyfin:srv"

    private func item(_ id: String, kind: MediaKind = .movie, season: Int? = nil, number: Int? = nil,
                      offset: TimeInterval = 0) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: pid, itemID: id), kind: kind, title: id, sortTitle: nil,
            overview: nil, year: 2016, runtime: 100,
            parentRef: season.map { MediaItemRef(providerID: pid, itemID: "season\($0)") },
            grandparentRef: kind == .episode ? MediaItemRef(providerID: pid, itemID: "show") : nil,
            episodeNumber: number, seasonNumber: season, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: offset, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
    }

    private func source(url: URL?) -> MediaSource {
        MediaSource(id: "src", container: "mkv", duration: 100, bitrate: nil, fileSize: nil, fileName: "x.mkv",
                    videoResolution: "1080", videoTracks: [], audioTracks: [], subtitleTracks: [],
                    streamKind: .directPlay, streamURL: url)
    }

    private func detail(_ item: MediaItem, url: URL? = nil) -> MediaItemDetail {
        MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                        chapters: [], mediaSources: [source(url: url)], trailerURL: nil, contentRating: nil,
                        nextEpisode: nil, collections: [])
    }

    /// A player on `entries[index]`, with the provider set up so any next entry's start fails fast.
    private func queueVM(_ provider: StubMediaProvider, _ items: [MediaItem], at index: Int,
                         next: MediaItem? = nil) -> UniversalPlayerViewModel {
        let entries = items.enumerated().map { PlaylistEntry(entryID: "pl\($0.offset)", item: $0.element) }
        let current = items[index]
        let url = URL(string: "http://media.local/\(current.ref.itemID)")!
        let playback = ProviderPlayback(
            provider: provider, item: current, detail: detail(current, url: url),
            stream: StreamInfo(source: source(url: url), playSessionID: "ps1", trackInfoAvailable: true),
            extras: PlaybackExtras())
        let vm = UniversalPlayerViewModel(providerPlayback: playback, startOffset: nil,
                                          playQueue: PlayQueue(entries: entries, startingAt: index))
        vm.reportPlaybackState(.playing)
        if let next { provider.detailResult = detail(next) }
        provider.streamResult = StreamInfo(source: source(url: nil), playSessionID: "ps2", trackInfoAvailable: true)
        return vm
    }

    func test_queue_nextIsQueueEntry_notSeasonEpisode() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let e1 = item("e1", kind: .episode, season: 1, number: 1)
        provider.childrenByParent["season1"] = [e1, item("e2", kind: .episode, season: 1, number: 2)]
        let vm = queueVM(provider, [e1, item("m2")], at: 0)

        let next = await vm.fetchNextEpisode()
        XCTAssertEqual(next?.ratingKey, "m2")
    }

    func test_queue_fetchNext_hasNoSideEffect() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let vm = queueVM(provider, [item("m1"), item("m2"), item("m3")], at: 0)

        let first = await vm.fetchNextEpisode()
        let second = await vm.fetchNextEpisode()
        XCTAssertEqual(first?.ratingKey, "m2")
        XCTAssertEqual(second?.ratingKey, "m2")
        XCTAssertEqual(vm.playQueue?.index, 0)
    }

    func test_queue_movieEnd_showsUpNext() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let m2 = item("m2")
        let vm = queueVM(provider, [item("m1"), m2], at: 0, next: m2)

        await vm.handlePlaybackEnded()
        XCTAssertEqual(vm.postVideoState, .showingEpisodeSummary)
        XCTAssertEqual(vm.nextEpisode?.ratingKey, "m2")
        vm.cancelCountdown()
    }

    func test_lastItem_hasNoNext() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let vm = queueVM(provider, [item("m1"), item("m2")], at: 1)

        await vm.finishPlayback()
        XCTAssertEqual(vm.postVideoState, .hidden)
        XCTAssertNil(vm.nextEpisode)
        XCTAssertTrue(vm.shouldDismiss)
    }

    /// An item with no Up Next card never publishes `.loading`: the container mounts the card for it (#497).
    func test_noUpNextCard_neverPublishesLoading() async {
        for kind in [MediaKind.movie] {
            let current = item("e1", kind: kind, season: 1, number: 1)
            let url = URL(string: "http://media.local/e1")!
            let playback = ProviderPlayback(
                provider: StubMediaProvider(id: pid, kind: .jellyfin), item: current, detail: detail(current, url: url),
                stream: StreamInfo(source: source(url: url), playSessionID: "ps1", trackInfoAvailable: true),
                extras: PlaybackExtras())
            let vm = UniversalPlayerViewModel(providerPlayback: playback, startOffset: nil)
            vm.reportPlaybackState(.playing)

            var states: [PostVideoState] = []
            let sink = vm.$postVideoState.sink { states.append($0) }
            await vm.finishPlayback()
            sink.cancel()

            XCTAssertEqual(states, [.hidden], "\(kind)")
            XCTAssertTrue(vm.shouldDismiss, "\(kind)")
        }
    }

    /// Movies run the end funnel twice: the credits trigger, then `.ended`.
    func test_secondEndPass_doesNotDismissWhileCardShows() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let m2 = item("m2")
        let vm = queueVM(provider, [item("m1"), m2], at: 0, next: m2)

        await vm.handlePlaybackEnded()
        await vm.finishPlayback()
        XCTAssertEqual(vm.postVideoState, .showingEpisodeSummary)
        XCTAssertFalse(vm.shouldDismiss)
        vm.cancelCountdown()
    }

    func test_nextEntry_startsAtItsResumePoint() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let m2 = item("m2", offset: 30)
        let vm = queueVM(provider, [item("m1"), m2], at: 0, next: m2)

        await vm.handlePlaybackEnded()
        vm.cancelCountdown()
        await vm.playNextEpisode()
        XCTAssertEqual(vm.metadata.ratingKey, "m2")
        XCTAssertEqual(vm.playQueue?.index, 1)
        XCTAssertEqual(vm.startOffset, 30)
    }

    /// A pick from the list goes by position, so the same title again still plays.
    func test_queueJump_sameTitleLaterInList() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let m1 = item("m1")
        let vm = queueVM(provider, [m1, item("m2"), m1], at: 0, next: m1)

        await vm.playQueueEntry(at: 2)
        XCTAssertEqual(vm.playQueue?.index, 2)
        let after = await vm.fetchNextEpisode()
        XCTAssertNil(after)
    }

    /// A pick mid-item keeps the item it left resumable: stopped at its position, never marked played.
    func test_queueJump_midItem_reportsPositionAndDoesNotMarkPlayed() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let recorder = RecordingReporter()
        provider.reporter = recorder
        let m4 = item("m4")
        let vm = queueVM(provider, [item("m1"), item("m2"), item("m3"), m4], at: 0, next: m4)

        await vm.playQueueEntry(at: 3)
        XCTAssertEqual(vm.playQueue?.index, 3)
        XCTAssertTrue(provider.markedPlayed.isEmpty)
        // The outgoing session ends at the playhead (0 here: no engine drives the clock).
        XCTAssertEqual(Array(recorder.events.prefix(2)), ["start", "stopped(0.0)"])
    }

    /// After the credits, a pick still marks the finished item played.
    func test_queueJump_afterCredits_marksPlayed() async {
        let provider = StubMediaProvider(id: pid, kind: .jellyfin)
        let m2 = item("m2")
        let vm = queueVM(provider, [item("m1"), m2, item("m3")], at: 0, next: m2)

        await vm.handlePlaybackEnded()
        vm.cancelCountdown()
        provider.detailResult = detail(item("m3"))
        await vm.playQueueEntry(at: 2)
        XCTAssertEqual(vm.playQueue?.index, 2)
        XCTAssertTrue(provider.markedPlayed.map(\.itemID).contains("m1"))
    }
}

/// Plex path: a preload for another entry must never decide what a jump plays.
@MainActor
final class PlaylistPlexJumpTests: XCTestCase {
    /// Opens once; every waiter before and after goes through.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func entry(_ id: String) -> PlaylistEntry {
        PlaylistEntry(entryID: "pl-\(id)", item: MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: id), kind: .movie, title: id, sortTitle: nil,
            overview: nil, year: 2016, runtime: 100, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil))
    }

    private static func full(_ id: String) -> PlexMetadata {
        let json = #"{"ratingKey":"\#(id)","type":"movie","title":"\#(id)","duration":100000,"Media":[{"id":1,"#
            + #""Part":[{"id":1,"key":"/library/parts/1/\#(id).mkv"}]}]}"#
        return try! JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    func test_jumpDuringStalePreload_playsTheJumpTarget() async {
        let entries = ["m1", "m2", "m3"].map(entry)
        // Port 9 refuses at once, so watched-marking and the start fail fast.
        let vm = UniversalPlayerViewModel(metadata: Self.full("m1"), serverURL: "http://127.0.0.1:9", authToken: "t",
                                          playQueue: PlayQueue(entries: entries, startingAt: 0))
        let gate = Gate()
        vm.plexMetadataFetch = { _, _, key in
            // The card's preload for m2 is held until the jump asks for m3, then lands late.
            if key == "m2" { await gate.wait() } else { await gate.open() }
            return Self.full(key)
        }

        await vm.handlePlaybackEnded()
        XCTAssertEqual(vm.nextEpisode?.ratingKey, "m2")
        vm.cancelCountdown()
        await vm.playQueueEntry(at: 2)

        XCTAssertEqual(vm.metadata.ratingKey, "m3")
        XCTAssertEqual(vm.playQueue?.index, 2)
    }

    /// The credits trigger fires while the jump fetches: Up Next re-points at m2
    /// and its preload writes while the jump marks m1 watched.
    func test_creditsTriggerDuringJump_playsTheJumpTarget() async {
        let entries = ["m1", "m2", "m3"].map(entry)
        let vm = UniversalPlayerViewModel(metadata: Self.full("m1"), serverURL: "http://127.0.0.1:9", authToken: "t",
                                          playQueue: PlayQueue(entries: entries, startingAt: 0))
        var triggered = false
        vm.plexMetadataFetch = { [weak vm] _, _, key in
            if key == "m3", !triggered {
                triggered = true
                await vm?.handlePlaybackEnded()
                vm?.cancelCountdown()
            }
            return Self.full(key)
        }

        await vm.playQueueEntry(at: 2)

        XCTAssertTrue(triggered)
        XCTAssertEqual(vm.metadata.ratingKey, "m3")
        XCTAssertEqual(vm.playQueue?.index, 2)
    }
}
