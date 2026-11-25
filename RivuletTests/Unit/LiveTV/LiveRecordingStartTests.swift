// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  LiveRecordingStartTests.swift
//  RivuletTests
//
//  Start from Beginning (#444): which tuned URLs can play a recording from its
//  first segment, when that segment aired, and which recording counts.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveRecordingStartTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// A Plex direct-play grant as `PlexLiveTVProvider.directPlayURL` builds it.
    private let grant = URL(string: "http://pms:32400/livetv/sessions/acd6/rivulet-444/index.m3u8?offset=91.833336&X-Plex-Incomplete-Segments=1&X-Plex-Session-Identifier=rivulet-444&X-Plex-Token=t")!

    private func recording(_ status: LiveTVScheduledRecording.Status, channel: String = "plex:s:203",
                           from start: TimeInterval = -600, to end: TimeInterval = 600) -> LiveTVScheduledRecording {
        LiveTVScheduledRecording(id: "g", sourceId: "s", title: "Game", subtitle: nil,
                                 startTime: now.addingTimeInterval(start), endTime: now.addingTimeInterval(end),
                                 status: status, channelName: nil, channelId: channel, programGuid: nil,
                                 ruleId: nil, posterURL: nil)
    }

    func test_playlistFromStart_setsOffsetZeroAndKeepsTheSession() throws {
        let url = try XCTUnwrap(LiveRecordingStart.playlistFromStart(grant))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "offset" }.map(\.value), ["0"])
        XCTAssertEqual(items.first { $0.name == "X-Plex-Session-Identifier" }?.value, "rivulet-444")
        XCTAssertEqual(url.path, grant.path)
    }

    func test_playlistFromStart_refusesTheTranscodeLegAndOtherSources() {
        XCTAssertNil(LiveRecordingStart.playlistFromStart(
            URL(string: "http://pms:32400/video/:/transcode/universal/start.m3u8?path=/livetv/sessions/x")!))
        XCTAssertNil(LiveRecordingStart.playlistFromStart(URL(string: "http://hdhr:5004/auto/v203")!))
    }

    func test_firstSegmentAired_isTheGrantOffsetAgo() {
        XCTAssertEqual(LiveRecordingStart.firstSegmentAired(tunedURL: grant, at: now),
                       now.addingTimeInterval(-91.833336))
        XCTAssertEqual(LiveRecordingStart.firstSegmentAired(
            tunedURL: URL(string: "http://pms:32400/livetv/sessions/a/b/index.m3u8?offset=-1.000000")!, at: now), now)
    }

    func test_recordingInProgress_onlyARecordingOnThisChannelNow() {
        let match = recording(.recording)
        XCTAssertEqual(LiveRecordingStart.recordingInProgress(on: "plex:s:203", in: [match], at: now), match)
        XCTAssertNil(LiveRecordingStart.recordingInProgress(on: "plex:s:203", in: [recording(.scheduled)], at: now))
        XCTAssertNil(LiveRecordingStart.recordingInProgress(on: "plex:s:204", in: [match], at: now))
        XCTAssertNil(LiveRecordingStart.recordingInProgress(on: "plex:s:203",
                                                            in: [recording(.recording, from: -600, to: -1)], at: now))
    }

    func test_joining_asksTheListFromThatOffsetAndMeasuresLagFromIt() throws {
        let start = LiveRecordingStart(recording: recording(.recording),
                                       url: try XCTUnwrap(LiveRecordingStart.playlistFromStart(grant)),
                                       firstSegmentAired: now.addingTimeInterval(-900))
        XCTAssertEqual(start.lag(at: now), 900)
        let later = start.joining(atOffset: 600)
        XCTAssertEqual(URLComponents(url: later.url, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "offset" }.map(\.value), ["600"])
        XCTAssertEqual(later.lag(at: now), 300)
        XCTAssertEqual(later.reach(lag: 300).before, 600)
        XCTAssertEqual(later.reach(lag: 300).after, 280)
        XCTAssertEqual(start.reach(lag: 10).after, 0)
    }

    func test_rejoinOffset_onlyOutsideWhatTheEngineHolds() throws {
        let start = LiveRecordingStart(recording: recording(.recording), url: grant,
                                       firstSegmentAired: now.addingTimeInterval(-900))
        let window = LiveSeekableWindow(lowerBound: 10, upperBound: 40)
        // The edge (session 40) is 880 s into the recording.
        let edgeWall = now.addingTimeInterval(-20)
        XCTAssertNil(start.rejoinOffset(forSessionPosition: 30, in: window, edgeWall: edgeWall))
        XCTAssertEqual(start.rejoinOffset(forSessionPosition: 100, in: window, edgeWall: edgeWall), 940)
        // No offset behind the first join: the window already reaches the start.
        XCTAssertNil(start.rejoinOffset(forSessionPosition: 5, in: window, edgeWall: edgeWall))
        XCTAssertEqual(start.joining(atOffset: 600).rejoinOffset(forSessionPosition: 5, in: window,
                                                                 edgeWall: edgeWall), 845)
    }

    /// A programme that airs every two hours lists all its airings under one grab
    /// (measured, PMS 1.43); `mediaIndex` names the one being recorded.
    func test_plexGrab_takesTheAiringMediaIndexNames() throws {
        let airing = { (begins: Int) -> [String: Any] in
            ["beginsAt": begins, "endsAt": begins + 7200, "channelIdentifier": "203"]
        }
        let operation: [String: Any] = [
            "id": "g", "status": "inprogress", "mediaIndex": 2,
            "Metadata": [["title": "Weather", "type": "movie",
                          "Media": [airing(1_795_107_600), airing(1_795_114_800), airing(1_795_122_000)]]],
        ]
        let grab = try XCTUnwrap(PlexNetworkManager.grab(from: operation))
        XCTAssertEqual(grab.beginsAt, Date(timeIntervalSince1970: 1_795_122_000))
        XCTAssertEqual(grab.endsAt, Date(timeIntervalSince1970: 1_795_129_200))
    }
}
