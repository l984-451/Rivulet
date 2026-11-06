// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyLiveTVTests.swift
//  RivuletTests
//
//  UNVERIFIED: Live TV is untested against a real Premiere server. Only the empty
//  envelope (a free server's answer to every read) is a captured response; every
//  fixture named *_unverified is hand-written from the Emby.SDK schema and the
//  Jellyfin fixtures, so a passing test here proves the code matches that guess.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyLiveTVTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let base = EmbyBrowseFixtures.baseURL
    private let sourceID = "emby:srv"
    private let hiddenKey = EmbyLiveTVProvider.hiddenKey

    private let sourcesKey = "liveTVSourceConfigurations"
    private var savedHidden: Any?
    private var savedSources: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedHidden = UserDefaults.standard.object(forKey: hiddenKey)
        savedSources = UserDefaults.standard.data(forKey: sourcesKey)
        UserDefaults.standard.removeObject(forKey: hiddenKey)
    }

    override func tearDown() async throws {
        if let savedHidden { UserDefaults.standard.set(savedHidden, forKey: hiddenKey) } else {
            UserDefaults.standard.removeObject(forKey: hiddenKey)
        }
        UserDefaults.standard.set(savedSources, forKey: sourcesKey)
        EmbyLiveTVProvider.hiddenSource = nil
        LiveTVDataStore.shared.setServerSource(nil, of: .emby)
        XCTAssertEqual(server.headerProblems, [])
        try await super.tearDown()
    }

    private func embyProvider() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Den", userID: "u1", policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: base, token: "tok", transport: server.transport))
    }

    private func live() -> EmbyLiveTVProvider { EmbyLiveTVProvider(provider: embyProvider()) }

    private func client() -> EmbyClient { EmbyClient(baseURL: base, token: "tok", transport: server.transport) }

    // Captured on Emby 4.10.2 free, with and without a tuner and guide provider (admin-livetv-channels-empty.json).
    private let emptyEnvelope = #"{"Items":[],"TotalRecordCount":0}"#

    // Hand-written from BaseItemDto (SDK 4.1.1.0); Number and ChannelNumber are both strings there.
    private let channels_unverified = #"""
        {"Items":[
          {"Name":"KXAN","Id":"5021","Number":"36","ChannelNumber":"36","Type":"TvChannel","ChannelType":"TV",
           "UserData":{"IsFavorite":true},"ImageTags":{"Primary":"abc123"}},
          {"Name":"KVUE-DT","Id":"5022","Number":"24.1","Type":"TvChannel","ChannelType":"TV",
           "UserData":{"IsFavorite":false},"ImageTags":{}},
          {"Name":"No Id Channel"}],
         "TotalRecordCount":3}
        """#

    // Hand-written. Dates in Emby's seven-digit Z form, and one without the fraction.
    private let programs_unverified = #"""
        {"Items":[
          {"Name":"Evening News","Id":"9002","ChannelId":"5021","Overview":"Headlines.","Genres":["News"],
           "StartDate":"2026-11-04T23:00:00.0000000Z","EndDate":"2026-11-05T00:00:00.0000000Z",
           "IsNews":true,"IsLive":true,"ImageTags":{"Primary":"p2"}},
          {"Name":"Morning Show","Id":"9001","ChannelId":"5021","Genres":[],
           "StartDate":"2026-11-04T12:00:00.0000000Z","EndDate":"2026-11-04T13:30:00.0000000Z",
           "IsSeries":true,"IsRepeat":false,"EpisodeTitle":"Pilot","IndexNumber":4,"ParentIndexNumber":2,
           "OfficialRating":"TV-PG","ImageTags":{},"BackdropImageTags":["bd1"]},
          {"Name":"Late Movie","Id":"9003","ChannelId":"5022","IsMovie":true,"ProductionYear":1999,"Genres":["Drama"],
           "StartDate":"2026-11-04T23:00:00Z","EndDate":"2026-11-05T01:00:00Z"},
          {"Name":"Elsewhere","Id":"9004","ChannelId":"9999",
           "StartDate":"2026-11-04T12:00:00.0000000Z","EndDate":"2026-11-04T13:00:00.0000000Z"},
          {"Name":"Zero Length","Id":"9005","ChannelId":"5021",
           "StartDate":"2026-11-04T12:00:00.0000000Z","EndDate":"2026-11-04T12:00:00.0000000Z"}]}
        """#

    // Hand-written: an M3U tuner's TS source, after AutoOpenLiveStream.
    private let playbackDirect_unverified = #"""
        {"MediaSources":[{"Protocol":"Http","Id":"ms-5021","Container":"ts","SupportsDirectPlay":false,
          "SupportsDirectStream":true,"SupportsTranscoding":true,"IsInfiniteStream":true,
          "RequiresOpening":false,"RequiresClosing":true,"LiveStreamId":"ls-77"}],
         "PlaySessionId":"play-1"}
        """#

    private func decode(_ json: String) throws -> EmbyPlaybackInfoResponse {
        try EmbyJSON.decoder().decode(EmbyPlaybackInfoResponse.self, from: Data(json.utf8))
    }

    private func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - The gate

    func test_sync_emptyChannels_installsNothing_andAsksWithTheUser() async {
        server.respond("/LiveTv/Channels", body: emptyEnvelope)
        await EmbyLiveTVProvider.sync(embyProvider())?.value

        XCTAssertFalse(LiveTVDataStore.shared.hasSource(id: sourceID), "no ghost source on a free server")
        XCTAssertNil(EmbyLiveTVProvider.hiddenSource)
        XCTAssertEqual(server.requests.map { $0.url!.path }, ["/LiveTv/Channels"], "LiveTv/Info is not the gate")
        let asked = query(server.requests[0].url!)
        XCTAssertEqual(asked["UserId"], "u1")
        XCTAssertEqual(asked["Limit"], "1")
    }

    func test_sync_withChannels_installsTheSource() async {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        await EmbyLiveTVProvider.sync(embyProvider())?.value

        XCTAssertTrue(LiveTVDataStore.shared.hasSource(id: sourceID))
        XCTAssertEqual(LiveTVDataStore.shared.sources.first { $0.id == sourceID }?.sourceType, .emby)
        XCTAssertNil(EmbyLiveTVProvider.hiddenSource)
    }

    func test_sync_aLaterEmptyAnswerRemovesTheSource() async {
        server.respond("/LiveTv/Channels", replies: [
            .init(body: channels_unverified), .init(body: emptyEnvelope)])
        await EmbyLiveTVProvider.sync(embyProvider())?.value
        XCTAssertTrue(LiveTVDataStore.shared.hasSource(id: sourceID))

        await EmbyLiveTVProvider.sync(embyProvider())?.value
        XCTAssertFalse(LiveTVDataStore.shared.hasSource(id: sourceID), "the licence lapsed or the tuner went")
    }

    func test_sync_aFailedCheckChangesNothing() async {
        server.respond("/LiveTv/Channels", replies: [
            .init(body: channels_unverified), .init(status: 500, body: "boom", contentType: "text/plain")])
        await EmbyLiveTVProvider.sync(embyProvider())?.value
        await EmbyLiveTVProvider.sync(embyProvider())?.value
        XCTAssertTrue(LiveTVDataStore.shared.hasSource(id: sourceID))
    }

    func test_sync_signedOut_removesTheSourceAndTheHiddenEntry() async {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        await EmbyLiveTVProvider.sync(embyProvider())?.value
        XCTAssertTrue(LiveTVDataStore.shared.hasSource(id: sourceID))

        XCTAssertNil(EmbyLiveTVProvider.sync(nil), "nothing to wait for")
        XCTAssertFalse(LiveTVDataStore.shared.hasSource(id: sourceID))
        XCTAssertNil(EmbyLiveTVProvider.hiddenSource)
    }

    /// The seam's sign-out and restricted-profile path (`ServerDataStore.reload`) calls this with nil.
    func test_seam_syncLiveTV_installsAndRemoves() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        let entry = try XCTUnwrap(OtherServerKind.entry(for: .emby))
        entry.syncLiveTV(embyProvider())
        for _ in 0..<100 where !LiveTVDataStore.shared.hasSource(id: sourceID) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(LiveTVDataStore.shared.hasSource(id: sourceID))

        entry.syncLiveTV(nil)
        XCTAssertFalse(LiveTVDataStore.shared.hasSource(id: sourceID))
    }

    func test_hidden_keepsTheSourceOutButListedAsOff_andShowingBringsItBack() async {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        UserDefaults.standard.set(true, forKey: hiddenKey)
        await EmbyLiveTVProvider.sync(embyProvider())?.value
        XCTAssertFalse(LiveTVDataStore.shared.hasSource(id: sourceID))
        XCTAssertEqual(EmbyLiveTVProvider.hiddenSource?.id, sourceID)
        XCTAssertEqual(EmbyLiveTVProvider.hiddenSource?.sourceType, .emby)
        XCTAssertEqual(EmbyLiveTVProvider.hiddenSource?.displayName, "Den Live TV")

        UserDefaults.standard.set(false, forKey: hiddenKey)
        await EmbyLiveTVProvider.sync(embyProvider())?.value
        XCTAssertTrue(LiveTVDataStore.shared.hasSource(id: sourceID))
        XCTAssertNil(EmbyLiveTVProvider.hiddenSource)
    }

    func test_hiddenKey_isItsOwn() {
        XCTAssertEqual(EmbyLiveTVProvider.hiddenKey, "liveTVHideEmby")
        XCTAssertNotEqual(EmbyLiveTVProvider.hiddenKey, JellyfinLiveTVProvider.hiddenKey)
    }

    func test_serverSource_isNeverSaved() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        await EmbyLiveTVProvider.sync(embyProvider())?.value
        XCTAssertTrue(LiveTVDataStore.shared.hasSource(id: sourceID))
        await LiveTVDataStore.shared.removeSource(id: "unrelated")  // any removal rewrites the saved list
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: sourcesKey))
        let configs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertFalse(configs.contains { ($0["type"] as? String) == "emby" || ($0["id"] as? String) == sourceID })
    }

    func test_sync_signOutDuringTheProbe_installsNothing() async {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        let probe = EmbyLiveTVProvider.sync(embyProvider())
        EmbyLiveTVProvider.sync(nil)
        await probe?.value
        XCTAssertFalse(LiveTVDataStore.shared.hasSource(id: sourceID))
    }

    // MARK: - Channels

    func test_channels_mapNumberLogoAndFavourite() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        let lineup = try await live().refreshChannels()

        XCTAssertEqual(lineup.map(\.id), ["emby:emby:srv:5021", "emby:emby:srv:5022"], "a channel with no id is dropped")
        XCTAssertEqual(lineup[0].sourceType, .emby)
        XCTAssertEqual(lineup[0].channelNumber, 36)
        XCTAssertTrue(lineup[0].isFavourite)
        XCTAssertEqual(lineup[0].logoURL?.absoluteString, "http://emby.local:8096/Items/5021/Images/Primary?Tag=abc123")
        XCTAssertFalse(lineup[0].logoURL?.absoluteString.contains("tok") ?? true, "images are anonymous")
        XCTAssertEqual(lineup[1].channelNumber?.description, "24.1", "Number alone is enough, a sub-channel keeps its minor")
        XCTAssertNil(lineup[1].logoURL)
        XCTAssertNil(lineup[0].streamURL, "resolved at play time")

        let asked = query(server.requests[0].url!)
        XCTAssertEqual(asked["UserId"], "u1")
        XCTAssertEqual(asked["AddCurrentProgram"], "false")
    }

    func test_fetchChannels_cachesTheLineup() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        let provider = live()
        _ = try await provider.fetchChannels()
        _ = try await provider.fetchChannels()
        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: - Guide

    func test_guide_onePerChannelSortedAndDatesParsed() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/LiveTv/Programs", body: programs_unverified)
        let provider = live()
        let lineup = try await provider.refreshChannels()
        let window = try Date("2026-11-04T12:00:00Z", strategy: .iso8601)
        let guide = try await provider.fetchEPG(for: lineup, startDate: window, endDate: window.addingTimeInterval(86400))

        let first = try XCTUnwrap(guide[lineup[0].id])
        XCTAssertEqual(first.map(\.title), ["Morning Show", "Evening News"], "sorted, zero-length dropped")
        XCTAssertEqual(guide.count, 2, "programmes for channels outside the lineup are dropped")

        let morning = first[0]
        XCTAssertEqual(morning.startTime, try Date("2026-11-04T12:00:00Z", strategy: .iso8601))
        XCTAssertEqual(morning.endTime, try Date("2026-11-04T13:30:00Z", strategy: .iso8601), "seven-digit fraction")
        XCTAssertEqual(morning.subtitle, "Pilot")
        XCTAssertEqual(morning.episodeNumber, "S2 E4")
        XCTAssertEqual(morning.contentRating, "TV-PG")
        XCTAssertTrue(morning.isNew)
        XCTAssertNil(morning.category, "no genres and no flag")
        XCTAssertEqual(morning.landscapeURL?.absoluteString, "http://emby.local:8096/Items/9001/Images/Backdrop?Tag=bd1")
        XCTAssertNil(morning.iconURL)

        let news = first[1]
        XCTAssertEqual(news.category, "News")
        XCTAssertTrue(news.isLive)
        XCTAssertEqual(news.iconURL?.absoluteString, "http://emby.local:8096/Items/9002/Images/Primary?Tag=p2")

        let movie = try XCTUnwrap(guide[lineup[1].id]?.first)
        XCTAssertTrue(movie.isMovie)
        XCTAssertEqual(movie.year, 1999)
        XCTAssertEqual(movie.startTime, try Date("2026-11-04T23:00:00Z", strategy: .iso8601), "no fraction parses too")
    }

    func test_guide_isOneRequestForTheWindow_withoutAChannelList() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/LiveTv/Programs", body: programs_unverified)
        let provider = live()
        let lineup = try await provider.refreshChannels()
        let start = try Date("2026-11-04T12:00:00Z", strategy: .iso8601)
        _ = try await provider.fetchEPG(for: lineup, startDate: start, endDate: start.addingTimeInterval(21600))

        let requests = server.requests("GET", "/LiveTv/Programs")
        XCTAssertEqual(requests.count, 1)
        let asked = query(requests[0].url!)
        XCTAssertEqual(asked["MinEndDate"], "2026-11-04T12:00:00Z", "a programme already airing at the start is included")
        XCTAssertEqual(asked["MaxStartDate"], "2026-11-04T18:00:00Z")
        XCTAssertEqual(asked["UserId"], "u1")
        XCTAssertNil(asked["ChannelIds"], "107 channel ids would ride in the URL")
    }

    func test_currentProgram_asksForOneChannelAndTheAiringProgramme() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/LiveTv/Programs", body: programs_unverified)
        let provider = live()
        let channel = try await provider.refreshChannels()[0]
        let program = await provider.getCurrentProgram(for: channel)

        XCTAssertEqual(program?.title, "Evening News", "the first row the server returns, which it limits to one")
        XCTAssertEqual(program?.channelId, channel.id)
        let asked = query(server.requests("GET", "/LiveTv/Programs")[0].url!)
        XCTAssertEqual(asked["ChannelIds"], "5021")
        XCTAssertEqual(asked["Limit"], "1")
        XCTAssertEqual(asked["MinEndDate"], asked["MaxStartDate"], "airing now")
    }

    func test_currentProgram_isNilWhenTheGuideFails() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/LiveTv/Programs", status: 500, body: "x", contentType: "text/plain")
        let provider = live()
        let channel = try await provider.refreshChannels()[0]
        let program = await provider.getCurrentProgram(for: channel)
        XCTAssertNil(program)
    }

    // MARK: - Playback

    func test_resolve_opensTheLiveStreamAndPlaysTheStaticStream() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/Items/5021/PlaybackInfo", method: "POST", body: playbackDirect_unverified)
        let provider = live()
        let channel = try await provider.refreshChannels()[0]
        let resolved = try await provider.resolveStreamURL(for: channel)
        let url = try XCTUnwrap(resolved)

        let body = server.jsonBody(server.requests.count - 1)
        XCTAssertEqual(body["AutoOpenLiveStream"] as? Bool, true)
        XCTAssertEqual(body["IsPlayback"] as? Bool, true)
        XCTAssertEqual(body["UserId"] as? String, "u1")

        XCTAssertEqual(url.path, "/Videos/5021/stream.ts", "no /emby prefix")
        let asked = query(url)
        XCTAssertEqual(asked["Static"], "true")
        XCTAssertEqual(asked["MediaSourceId"], "ms-5021")
        XCTAssertEqual(asked["LiveStreamId"], "ls-77")
        XCTAssertEqual(asked["PlaySessionId"], "play-1")
        XCTAssertEqual(asked["api_key"], "tok")
        XCTAssertNil(asked["ApiKey"], "Emby's key is api_key")
    }

    func test_streamURL_fallsBackToTheTranscode_addingTheLiveStreamIdAndKey() throws {
        let info = try decode(#"""
            {"MediaSources":[{"Id":"ms","SupportsDirectStream":false,"LiveStreamId":"ls-1",
              "TranscodingUrl":"/videos/5021/master.m3u8?DeviceId=dev&MediaSourceId=ms&PlaySessionId=ps&VideoCodec=h264"}],
             "PlaySessionId":"ps"}
            """#)
        let url = try XCTUnwrap(info.liveStreamURL(channelID: "5021", client: client()))
        XCTAssertEqual(url.path, "/videos/5021/master.m3u8")
        XCTAssertEqual(query(url)["LiveStreamId"], "ls-1")
        XCTAssertEqual(query(url)["api_key"], "tok")
        XCTAssertEqual(query(url)["VideoCodec"], "h264", "the server's own query is kept")
    }

    func test_streamURL_keepsTheTranscodesOwnKeyAndLiveStreamId() throws {
        let info = try decode(#"""
            {"MediaSources":[{"Id":"ms","LiveStreamId":"ls-1",
              "TranscodingUrl":"/videos/5021/master.m3u8?livestreamid=ls-1&api_key=other"}]}
            """#)
        let url = try XCTUnwrap(info.liveStreamURL(channelID: "5021", client: client()))
        XCTAssertEqual(url.query?.components(separatedBy: "api_key").count, 2, "not added twice")
        XCTAssertEqual(url.query?.lowercased().components(separatedBy: "livestreamid").count, 2)
    }

    func test_streamURL_playsARemoteHLSSourceFromItsOrigin() throws {
        let info = try decode(#"""
            {"MediaSources":[{"Id":"ms","Container":"hls","SupportsDirectStream":false,
              "Path":"https://fast.example/live/master.m3u8","LiveStreamId":"ls-1",
              "TranscodingUrl":"/videos/5021/master.m3u8?LiveStreamId=ls-1"}]}
            """#)
        let url = try XCTUnwrap(info.liveStreamURL(channelID: "5021", client: client()))
        XCTAssertEqual(url.absoluteString, "https://fast.example/live/master.m3u8")
        XCTAssertNil(EmbyLiveTVProvider.closeRequest(for: url), "closed at resolve, not by the keepalive")
    }

    func test_resolve_remoteHLS_closesTheOpenedStreamAtOnce() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/Items/5021/PlaybackInfo", method: "POST", body: #"""
            {"MediaSources":[{"Id":"ms","Container":"hls","SupportsDirectStream":false,
              "Path":"https://fast.example/live/master.m3u8","LiveStreamId":"ls-1"}],"PlaySessionId":"ps"}
            """#)
        server.respond("/Sessions/Playing/Stopped", method: "POST", status: 204)
        server.respond("/LiveStreams/Close", method: "POST", status: 204)
        let provider = live()
        let channel = try await provider.refreshChannels()[0]
        let url = try await provider.resolveStreamURL(for: channel)
        XCTAssertEqual(url?.host, "fast.example")
        XCTAssertEqual(server.requests("POST", "/LiveStreams/Close").count, 1)
        XCTAssertEqual(server.requests("POST", "/Sessions/Playing/Stopped").count, 1)
    }

    func test_resolve_noOpenedStream_isChannelNotFound() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/Items/5021/PlaybackInfo", method: "POST",
                       body: #"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#)
        let provider = live()
        let channel = try await provider.refreshChannels()[0]
        do {
            _ = try await provider.resolveStreamURL(for: channel)
            XCTFail("expected a throw")
        } catch LiveTVProviderError.channelNotFound(let name) {
            XCTAssertEqual(name, "KXAN")
        }
    }

    /// UNVERIFIED wording: the text of the server's refusal was never observed, so any 500 that
    /// names a tuner is read as busy.
    func test_resolve_exhaustedTuners_isTunersBusy() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/Items/5021/PlaybackInfo", method: "POST", status: 500,
                       body: "No tuner available for this channel.", contentType: "text/plain")
        let provider = live()
        let channel = try await provider.refreshChannels()[0]
        do {
            _ = try await provider.resolveStreamURL(for: channel)
            XCTFail("expected a throw")
        } catch LiveTVProviderError.tunersBusy {
            XCTAssertEqual(LiveTVProviderError.tunersBusy.errorDescription,
                           "Couldn't tune this channel. All tuners may be busy.")
        }
    }

    func test_resolve_anotherFailure_isNotCalledBusy() async throws {
        server.respond("/LiveTv/Channels", body: channels_unverified)
        server.respond("/Items/5021/PlaybackInfo", method: "POST", status: 500, body: "NullReference", contentType: "text/plain")
        let provider = live()
        let channel = try await provider.refreshChannels()[0]
        do {
            _ = try await provider.resolveStreamURL(for: channel)
            XCTFail("expected a throw")
        } catch LiveTVProviderError.tunersBusy {
            XCTFail("not a tuner fault")
        } catch {}
    }

    // MARK: - Release

    func test_closeRequest_readsBaseTokenAndLiveStream() throws {
        let url = URL(string: "http://emby.local:8096/emby/Videos/5021/stream.ts?Static=true&MediaSourceId=ms&LiveStreamId=ls-1&PlaySessionId=ps&api_key=tok")!
        let close = try XCTUnwrap(EmbyLiveTVProvider.closeRequest(for: url))
        XCTAssertEqual(close.base.absoluteString, "http://emby.local:8096/emby", "a typed subpath is kept")
        XCTAssertEqual(close.token, "tok")
        XCTAssertEqual(close.request, .init(itemID: "5021", liveStreamID: "ls-1", mediaSourceID: "ms",
                                            playSessionID: "ps", encodeDeviceID: nil))

        let hls = URL(string: "http://emby.local:8096/videos/5021/master.m3u8?DeviceId=dev&LiveStreamId=ls-1&PlaySessionId=ps&api_key=tok")!
        XCTAssertEqual(EmbyLiveTVProvider.closeRequest(for: hls)?.request.encodeDeviceID, "dev")
        let noDevice = URL(string: "http://emby.local:8096/videos/5021/master.m3u8?LiveStreamId=ls-1&api_key=tok")!
        XCTAssertEqual(EmbyLiveTVProvider.closeRequest(for: noDevice)?.request.encodeDeviceID, "", "this device")
    }

    func test_closeRequest_proxySubpathWithAVideosSegment() throws {
        let url = URL(string: "https://host/media/videos/emby/Videos/5021/stream.ts?LiveStreamId=ls&api_key=tok")!
        let close = try XCTUnwrap(EmbyLiveTVProvider.closeRequest(for: url))
        XCTAssertEqual(close.base.absoluteString, "https://host/media/videos/emby")
        XCTAssertEqual(close.request.itemID, "5021")
    }

    func test_closeRequest_ignoresOtherServers() {
        XCTAssertNil(EmbyLiveTVProvider.closeRequest(for: URL(string: "http://dispatcharr:9191/proxy/ts/stream/x")!))
        XCTAssertNil(EmbyLiveTVProvider.closeRequest(
            for: URL(string: "http://pms:32400/livetv/sessions/u/c/index.m3u8?X-Plex-Token=t")!))
        XCTAssertNil(EmbyLiveTVProvider.closeRequest(
            for: URL(string: "http://emby.local:8096/Videos/5021/stream.ts?Static=true&api_key=tok")!), "no live stream id")
    }

    /// `LiveStreams/Close` answers 204 for any id, so a stop sends both calls, and ends an encode.
    func test_close_sendsTheStoppedReportAndTheClose_andStopsAnEncode() async throws {
        server.respond("/Sessions/Playing/Stopped", method: "POST", status: 204)
        server.respond("/LiveStreams/Close", method: "POST", status: 204)
        server.respond("/Videos/ActiveEncodings", method: "DELETE", status: 204)

        await EmbyLiveTVProvider.close(.init(itemID: "5021", liveStreamID: "ls-1", mediaSourceID: "ms",
                                             playSessionID: "ps", encodeDeviceID: "dev"), client: client())

        let stopped = try XCTUnwrap(server.requests("POST", "/Sessions/Playing/Stopped").first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: stopped.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["ItemId"] as? String, "5021")
        XCTAssertEqual(body["LiveStreamId"] as? String, "ls-1")
        XCTAssertEqual(body["PlaySessionId"] as? String, "ps")
        XCTAssertEqual(body["PositionTicks"] as? Int, 0)

        let close = try XCTUnwrap(server.requests("POST", "/LiveStreams/Close").first)
        XCTAssertEqual(query(close.url!)["LiveStreamId"], "ls-1")
        let encode = try XCTUnwrap(server.requests("DELETE", "/Videos/ActiveEncodings").first)
        XCTAssertEqual(query(encode.url!)["DeviceId"], "dev")
        XCTAssertEqual(query(encode.url!)["PlaySessionId"], "ps")
    }

    func test_close_aStaticStreamHasNoEncodeToStop() async {
        server.respond("/Sessions/Playing/Stopped", method: "POST", status: 204)
        server.respond("/LiveStreams/Close", method: "POST", status: 204)
        await EmbyLiveTVProvider.close(.init(itemID: "5021", liveStreamID: "ls-1", mediaSourceID: nil,
                                             playSessionID: "ps", encodeDeviceID: nil), client: client())
        XCTAssertTrue(server.requests("DELETE", "/Videos/ActiveEncodings").isEmpty)
        XCTAssertEqual(server.requests.count, 2)
    }

    func test_close_aFailingFirstCallStillSendsTheSecond() async {
        server.respond("/Sessions/Playing/Stopped", method: "POST", status: 500, body: "x", contentType: "text/plain")
        server.respond("/LiveStreams/Close", method: "POST", status: 204)
        await EmbyLiveTVProvider.close(.init(itemID: "5021", liveStreamID: "ls-1", mediaSourceID: nil,
                                             playSessionID: nil, encodeDeviceID: nil), client: client())
        XCTAssertEqual(server.requests("POST", "/LiveStreams/Close").count, 1)
    }

    /// Both servers share the `/videos/` + liveStreamId URL shape, so the source id, not the URL, picks the closer.
    func test_keepalive_routesAnEmbySourceToTheEmbyCloser() {
        var closed: [String] = []
        let saved = PlexLiveTimelineKeepalive.otherSessionClosers
        PlexLiveTimelineKeepalive.otherSessionClosers = [
            "jellyfin": { _ in closed.append("jellyfin") },
            MediaProviderKind.emby.rawValue: { _ in closed.append("emby") }
        ]
        defer { PlexLiveTimelineKeepalive.otherSessionClosers = saved }
        let url = URL(string: "http://host/videos/5021/stream.ts?LiveStreamId=ls-1&api_key=tok")!

        PlexLiveTimelineKeepalive.release(url, sourceID: sourceID)
        XCTAssertEqual(closed, ["emby"])
        PlexLiveTimelineKeepalive.release(url, sourceID: "jellyfin:srv")
        XCTAssertEqual(closed, ["emby", "jellyfin"])
    }

    func test_keepalive_releasesAnEmbySessionOncePerStart() {
        var released: [URL] = []
        let saved = PlexLiveTimelineKeepalive.otherSessionClosers
        PlexLiveTimelineKeepalive.otherSessionClosers = ["emby": { released.append($0) }]
        defer { PlexLiveTimelineKeepalive.otherSessionClosers = saved }
        let url = URL(string: "http://emby.local:8096/Videos/5021/stream.ts?LiveStreamId=ls-1&api_key=tok")!

        let keepalive = PlexLiveTimelineKeepalive(transport: { _ in })
        keepalive.start(url: url, sourceID: sourceID)
        keepalive.stop()
        keepalive.stop()
        XCTAssertEqual(released, [url])
    }

    // MARK: - Source type

    func test_sourceType_followsTheServer_andIsNamed() async {
        XCTAssertTrue(LiveTVSourceType.emby.followsServer)
        XCTAssertEqual(LiveTVSourceType.emby.rawValue, "emby")
        let provider = live()
        let (type, name) = (await provider.sourceType, await provider.displayName)
        XCTAssertEqual(type, .emby)
        XCTAssertEqual(name, "Den Live TV")
        XCTAssertEqual(UnifiedChannel.makeId(sourceType: .emby, sourceId: sourceID, channelId: "5021"), "emby:emby:srv:5021")
    }
}
