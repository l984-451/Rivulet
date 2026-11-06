// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProviderPlaybackTests.swift
//  RivuletTests
//
//  Plex through the playback seam (stage 4): the capped stream, the transcode,
//  the play session's open and close, markers with IntroDB, track picks.
//

import XCTest
import os
@testable import Rivulet

@MainActor
final class PlexProviderPlaybackTests: XCTestCase {

    private final class StubNetwork: PlexNetworkManager, @unchecked Sendable {
        var metadata: [String: PlexMetadata] = [:]
        var calls: [String] = []
        var timeline: [(key: String, ms: Int, state: String, duration: Int?, session: String?)] = []

        override func getFullMetadata(serverURL: String, authToken: String, ratingKey: String) async throws -> PlexMetadata {
            calls.append("full(\(ratingKey))")
            guard let meta = metadata[ratingKey] else { throw PlexAPIError.invalidURL }
            return meta
        }
        override func getMetadata(serverURL: String, authToken: String, ratingKey: String,
                                  includeGuids: Bool) async throws -> PlexMetadata {
            calls.append("meta(\(ratingKey))")
            guard let meta = metadata[ratingKey] else { throw PlexAPIError.invalidURL }
            return meta
        }
        override func setSelectedAudioStream(serverURL: String, authToken: String, partId: Int, audioStreamID: Int) async {
            calls.append("audio(\(partId),\(audioStreamID))")
        }
        override func setSelectedSubtitleStream(serverURL: String, authToken: String, partId: Int, subtitleStreamID: Int) async {
            calls.append("subtitle(\(partId),\(subtitleStreamID))")
        }
        override func reportProgress(serverURL: String, authToken: String, ratingKey: String, timeMs: Int,
                                     state: String, duration: Int?, sessionIdentifier: String?) async throws -> String? {
            timeline.append((ratingKey, timeMs, state, duration, sessionIdentifier))
            return nil
        }
        override func stopTranscodeSession(serverURL: String, authToken: String, sessionId: String) async {
            calls.append("stop(\(sessionId))")
        }
        override func startTranscodeDecision(hlsURL: URL, headers: [String: String]) async {
            calls.append("decision(\(hlsURL.path))")
        }
        override func openDirectPlaySession(serverURL: String, authToken: String, ratingKey: String,
                                            mediaIndex: Int, sessionIdentifier: String) async {
            calls.append("open(\(ratingKey),\(mediaIndex),\(sessionIdentifier))")
        }
    }

    /// Movie 100: version 11 is 20 Mbps (index 0), version 12 is 4 Mbps (index 1).
    private static let movieJSON = """
    {"ratingKey":"100","type":"movie","title":"Heat","duration":7200000,
     "Marker":[{"id":5,"type":"intro","startTimeOffset":1000,"endTimeOffset":61000},
               {"id":6,"type":"credits","startTimeOffset":7000000,"endTimeOffset":7200000}],
     "Media":[
      {"id":11,"duration":7200000,"bitrate":20000,"videoResolution":"1080","container":"mkv","Part":[
        {"id":111,"key":"/library/parts/111/1/file.mkv","duration":7200000,"container":"mkv","Stream":[
          {"id":1000,"streamType":1,"codec":"h264","index":0},
          {"id":1001,"streamType":2,"codec":"eac3","index":1,"languageCode":"eng","selected":true},
          {"id":1002,"streamType":2,"codec":"aac","index":2,"languageCode":"spa"},
          {"id":1003,"streamType":3,"codec":"srt","index":3,"languageCode":"eng"}]}]},
      {"id":12,"duration":7200000,"bitrate":4000,"videoResolution":"720","container":"mkv","Part":[
        {"id":121,"key":"/library/parts/121/1/file.mkv","duration":7200000,"container":"mkv","Stream":[
          {"id":2000,"streamType":1,"codec":"h264","index":0},
          {"id":2001,"streamType":2,"codec":"aac","index":1,"languageCode":"eng"}]}]}]}
    """

    private func makeProvider(_ network: StubNetwork) -> PlexProvider {
        let movie = try! JSONDecoder().decode(PlexMetadata.self, from: Data(Self.movieJSON.utf8))
        network.metadata["100"] = movie
        return PlexProvider(machineIdentifier: "m1", displayName: "Plex", serverURL: "http://plex.test:32400",
                            authToken: "tok", networkManager: network)
    }

    private let ref = MediaItemRef(providerID: "plex:m1", itemID: "100")

    private func query(_ url: URL?, _ name: String) -> String? {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    // MARK: - resolveStream

    func test_resolveStream_uncapped_directPlaysTheBestVersion() async throws {
        let provider = makeProvider(StubNetwork())
        let info = try await provider.resolveStream(for: ref, sourceID: nil, maxBitrate: nil)
        XCTAssertEqual(info.source.id, "11")
        XCTAssertEqual(info.source.streamKind, .directPlay)
        XCTAssertEqual(info.source.streamURL?.path, "/library/parts/111/1/file.mkv")
        XCTAssertEqual(query(info.source.streamURL, "X-Plex-Token"), "tok")
        XCTAssertEqual(info.headers["X-Plex-Token"], "tok")
        XCTAssertNotNil(info.playSessionID)
    }

    func test_resolveStream_capFitsASmallerVersion_directPlaysIt() async throws {
        let provider = makeProvider(StubNetwork())
        let info = try await provider.resolveStream(for: ref, sourceID: nil, maxBitrate: 4_000_000)
        XCTAssertEqual(info.source.id, "12")
        XCTAssertEqual(info.source.streamKind, .directPlay)
    }

    func test_resolveStream_capBelowEveryVersion_transcodesAtThatStep() async throws {
        let provider = makeProvider(StubNetwork())
        let info = try await provider.resolveStream(for: ref, sourceID: "12", maxBitrate: 2_000_000)
        XCTAssertEqual(info.source.streamKind, .hlsTranscode)
        let url = info.source.streamURL
        XCTAssertEqual(url?.path, "/video/:/transcode/universal/start.m3u8")
        XCTAssertEqual(query(url, "path"), "/library/metadata/100")
        XCTAssertEqual(query(url, "mediaIndex"), "1")
        XCTAssertEqual(query(url, "maxVideoBitrate"), "\(QualityDecision.highestStep(atMost: 2000).kbps)")
        XCTAssertEqual(query(url, "session"), info.playSessionID)
        XCTAssertEqual(info.headers["X-Plex-Token"], "tok")
    }

    // MARK: - transcodeStream

    func test_transcodeStream_startsAtTheOffsetOnTheChosenVersion() async throws {
        let provider = makeProvider(StubNetwork())
        let info = try await provider.transcodeStream(for: ref, sourceID: "11", startTime: 125, maxBitrate: 4_000_000)
        XCTAssertEqual(query(info.source.streamURL, "offset"), "125")
        XCTAssertEqual(query(info.source.streamURL, "mediaIndex"), "0")
        XCTAssertEqual(query(info.source.streamURL, "directPlay"), "0")
        XCTAssertEqual(query(info.source.streamURL, "maxVideoBitrate"), "\(QualityDecision.highestStep(atMost: 4000).kbps)")
    }

    func test_transcodeStream_withoutACap_usesTheTopStep() async throws {
        let provider = makeProvider(StubNetwork())
        let info = try await provider.transcodeStream(for: ref, sourceID: nil, startTime: 0)
        XCTAssertEqual(query(info.source.streamURL, "maxVideoBitrate"), "\(QualityStep.ladder[0].kbps)")
    }

    func test_transcodeStream_trackPicksGoToThePartBeforeTheSessionStarts() async throws {
        let network = StubNetwork()
        let provider = makeProvider(network)
        _ = try await provider.transcodeStream(for: ref, sourceID: "11", startTime: 0, maxBitrate: 4_000_000,
                                               audioStreamIndex: 1002, subtitleStreamIndex: -1)
        XCTAssertTrue(network.calls.contains("audio(111,1002)"))
        XCTAssertTrue(network.calls.contains("subtitle(111,0)"), "-1 is off, which Plex writes as 0")
    }

    func test_transcodeStream_noPicks_leavesThePartAlone() async throws {
        let network = StubNetwork()
        let provider = makeProvider(network)
        _ = try await provider.transcodeStream(for: ref, sourceID: "11", startTime: 0, maxBitrate: 4_000_000)
        XCTAssertFalse(network.calls.contains { $0.hasPrefix("audio") || $0.hasPrefix("subtitle") })
    }

    // MARK: - Play session

    func test_reporter_directPlay_opensTheSessionThenReportsItsIdentifier() async throws {
        let network = StubNetwork()
        let provider = makeProvider(network)
        let info = try await provider.resolveStream(for: ref, sourceID: "12", maxBitrate: nil)
        let session = try XCTUnwrap(info.playSessionID)
        let reporter = provider.progressReporter(for: ref, sourceID: "12", playSessionID: session)
        await reporter.start(position: 0)
        await reporter.progress(position: 30)
        await reporter.stopped(at: 60)
        XCTAssertTrue(network.calls.contains("open(100,1,\(session))"))
        XCTAssertEqual(network.timeline.map(\.state), ["playing", "stopped"])
        XCTAssertEqual(network.timeline.map(\.ms), [30_000, 60_000])
        XCTAssertEqual(network.timeline.first?.session, session)
        XCTAssertEqual(network.timeline.first?.duration, 7_200_000)
        XCTAssertFalse(network.calls.contains { $0.hasPrefix("stop(") }, "a direct play has no transcoder to stop")
    }

    func test_reporter_transcode_leavesTheDecisionToThePlayerAndStopsTheTranscoderOnStopped() async throws {
        let network = StubNetwork()
        let provider = makeProvider(network)
        let info = try await provider.transcodeStream(for: ref, sourceID: "11", startTime: 0, maxBitrate: 4_000_000)
        let session = try XCTUnwrap(info.playSessionID)
        let reporter = provider.progressReporter(for: ref, sourceID: "11", playSessionID: session)
        await reporter.start(position: 0)
        XCTAssertFalse(network.calls.contains { $0.hasPrefix("decision(") },
                       "the player's preflight sends the decision, and a second one is wasted")
        await reporter.stopped(at: 10)
        XCTAssertTrue(network.calls.contains("stop(\(session))"))
        XCTAssertNil(network.timeline.last?.session, "a transcode's timeline carries no direct-play identifier")
    }

    func test_stopped_forgetsTheSession() async throws {
        let provider = makeProvider(StubNetwork())
        let direct = try await provider.resolveStream(for: ref, sourceID: "12", maxBitrate: nil)
        let transcode = try await provider.transcodeStream(for: ref, sourceID: "11", startTime: 0, maxBitrate: 4_000_000)
        XCTAssertEqual(provider.playSessions.withLock { $0.count }, 2)
        for info in [direct, transcode] {
            let reporter = provider.progressReporter(for: ref, sourceID: info.source.id, playSessionID: info.playSessionID)
            await reporter.stopped(at: 1)
        }
        XCTAssertEqual(provider.playSessions.withLock { $0.count }, 0)
    }

    func test_newStreams_pruneSessionsNobodyEverStopped() async throws {
        let provider = makeProvider(StubNetwork())
        provider.playSessions.withLock {
            $0["stale"] = PlexPlaySession(ratingKey: "9", mediaIndex: 0, durationMs: nil, transcode: nil,
                                          createdAt: Date(timeIntervalSinceNow: -7 * 3600))
        }
        _ = try await provider.resolveStream(for: ref, sourceID: nil, maxBitrate: nil)
        XCTAssertNil(provider.playSessions.withLock { $0["stale"] })
        XCTAssertEqual(provider.playSessions.withLock { $0.count }, 1)
    }

    func test_resolveStream_cappedTranscodeStartsAtTheResumePoint() async throws {
        let provider = makeProvider(StubNetwork())
        let info = try await provider.resolveStream(for: ref, sourceID: "12", maxBitrate: 2_000_000, startTime: 125)
        XCTAssertEqual(query(info.source.streamURL, "offset"), "125")
        let uncapped = try await provider.resolveStream(for: ref, sourceID: "12", maxBitrate: nil, startTime: 125)
        XCTAssertEqual(uncapped.source.streamKind, .directPlay, "a direct play has no offset to carry")
    }

    func test_reporter_unknownSession_stillReportsTheTimeline() async {
        let network = StubNetwork()
        let provider = makeProvider(network)
        let reporter = provider.progressReporter(for: ref, sourceID: nil, playSessionID: nil)
        await reporter.paused(at: 5)
        XCTAssertEqual(network.timeline.map(\.state), ["paused"])
    }

    // MARK: - Markers

    func test_playbackExtras_mapsPlexMarkers() async throws {
        let provider = makeProvider(StubNetwork())
        let extras = await provider.playbackExtras(for: ref, sourceID: nil)
        XCTAssertEqual(extras.markers, [
            PlaybackMarker(kind: .intro, start: 1, end: 61),
            PlaybackMarker(kind: .credits, start: 7000, end: 7200)
        ])
    }

    func test_playbackExtras_unknownItem_isEmpty() async {
        let provider = makeProvider(StubNetwork())
        let extras = await provider.playbackExtras(for: MediaItemRef(providerID: "plex:m1", itemID: "nope"), sourceID: nil)
        XCTAssertTrue(extras.markers.isEmpty)
    }

    // MARK: - Marker merge

    func test_markerMerge_communityFillsOnlyMissingKinds() {
        let plex = [PlexMarker(id: 1, type: "intro", startTimeOffset: 0, endTimeOffset: 1000)]
        let community = [
            PlexMarker(id: -9001, type: "intro", startTimeOffset: 5, endTimeOffset: 6),
            PlexMarker(id: -9003, type: "credits", startTimeOffset: 9000, endTimeOffset: 9500)
        ]
        let merged = PlexPlaybackMarkers.merged(plex: plex, community: community)
        XCTAssertEqual(merged.compactMap(\.type), ["intro", "credits"])
        XCTAssertEqual(merged.first?.id, 1, "Plex's own intro wins")
    }

    func test_markerMerge_sortsByStart() {
        let plex = [PlexMarker(id: 2, type: "credits", startTimeOffset: 9000, endTimeOffset: 9500),
                    PlexMarker(id: 1, type: "intro", startTimeOffset: 100, endTimeOffset: 200)]
        XCTAssertEqual(PlexPlaybackMarkers.merged(plex: plex, community: []).compactMap(\.type), ["intro", "credits"])
    }

    func test_playbackMarkers_dropUnknownKindsAndHalfMarkers() {
        let markers = [
            PlexMarker(id: 1, type: "intro", startTimeOffset: 1000, endTimeOffset: 2000),
            PlexMarker(id: 2, type: "mystery", startTimeOffset: 1000, endTimeOffset: 2000),
            PlexMarker(id: 3, type: "credits", startTimeOffset: nil, endTimeOffset: 2000)
        ]
        XCTAssertEqual(PlexPlaybackMarkers.playbackMarkers(markers), [PlaybackMarker(kind: .intro, start: 1, end: 2)])
    }

    func test_community_episodeAsksIntroDBWithTheShowsImdbId() async {
        let network = StubNetwork()
        let show = try! JSONDecoder().decode(PlexMetadata.self, from: Data(
            #"{"ratingKey":"50","type":"show","Guid":[{"id":"imdb://tt0903747"}]}"#.utf8))
        network.metadata["50"] = show
        let episode = try! JSONDecoder().decode(PlexMetadata.self, from: Data(
            #"{"ratingKey":"51","type":"episode","grandparentRatingKey":"50","parentIndex":2,"index":3}"#.utf8))
        var asked: (String, Int, Int)?
        let markers = await PlexPlaybackMarkers.community(
            for: episode, serverURL: "http://s", token: "t", network: network
        ) { imdb, season, number in
            asked = (imdb, season, number)
            return [PlexMarker(id: -9001, type: "intro", startTimeOffset: 0, endTimeOffset: 1000)]
        }
        XCTAssertEqual(asked?.0, "tt0903747")
        XCTAssertEqual(asked?.1, 2)
        XCTAssertEqual(asked?.2, 3)
        XCTAssertEqual(markers.count, 1)
    }

    func test_community_movieDoesNotAsk() async {
        let movie = try! JSONDecoder().decode(PlexMetadata.self, from: Data(#"{"ratingKey":"1","type":"movie"}"#.utf8))
        var asked = false
        let markers = await PlexPlaybackMarkers.community(
            for: movie, serverURL: "http://s", token: "t", network: StubNetwork()
        ) { _, _, _ in asked = true; return [] }
        XCTAssertFalse(asked)
        XCTAssertTrue(markers.isEmpty)
    }
}
