// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlaybackReloadTests.swift
//  RivuletTests
//
//  The playing provider stream again: a quality step, a track change on a
//  transcode, a fallback. Plus how a stream's plan reads for the player.
//

import XCTest
@testable import Rivulet

@MainActor
final class ProviderPlaybackReloadTests: XCTestCase {

    private func audio(_ id: String, index: Int, selected: Bool = false) -> AudioTrack {
        AudioTrack(id: id, index: index, codec: "eac3", profile: nil, channels: 6, channelLayout: nil,
                   language: "eng", title: "English", extendedTitle: nil, bitrate: nil, samplingRate: nil,
                   isDefault: selected, isForced: false, isSelected: selected)
    }

    private func source(kind: MediaSource.StreamKind = .directPlay, kbps: Int? = 20_000, url: String = "http://s/direct") -> MediaSource {
        MediaSource(
            id: "src", container: "mkv", duration: 100, bitrate: kbps.map { $0 * 1000 }, fileSize: nil, fileName: nil,
            videoResolution: "1080",
            videoTracks: [VideoTrack(id: "0", codec: "h264", profile: nil, level: nil, width: 1920, height: 1080,
                                     frameRate: nil, bitrate: nil, videoRange: .sdr, isDefault: true, scanType: nil)],
            audioTracks: [audio("1", index: 1, selected: true), audio("2", index: 2)],
            subtitleTracks: [], streamKind: kind, streamURL: URL(string: url))
    }

    private func playback(_ provider: StubMediaProvider, kind: MediaSource.StreamKind = .directPlay,
                          plan: StreamPlan = .original) -> ProviderPlayback {
        let item = JellyfinFixtures.mediaItem("m1")
        let direct = source()
        let detail = MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [], chapters: [],
            mediaSources: [direct], trailerURL: nil, contentRating: nil, nextEpisode: nil, collections: [])
        var quality = ProviderQuality()
        quality.plan = plan
        return ProviderPlayback(
            provider: provider, item: item, detail: detail,
            stream: StreamInfo(source: source(kind: kind), playSessionID: "ps1", trackInfoAvailable: true),
            extras: PlaybackExtras(), quality: quality)
    }

    private let step4 = QualityStep.step(kbps: 4000)!

    private func provider() -> StubMediaProvider {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        provider.transcodeResult = StreamInfo(source: source(kind: .hlsTranscode, url: "http://s/hls"),
                                              playSessionID: "ps2", trackInfoAvailable: true)
        provider.streamResult = StreamInfo(source: source(), playSessionID: "ps3", trackInfoAvailable: true)
        return provider
    }

    func test_reload_forcedTranscode_startsAtTheTimeUnderTheStepsBitrate() async throws {
        let stub = provider()
        let next = try await playback(stub).reloaded(quality: .auto, plan: .transcode(step4), at: 125,
                                                     tracks: TrackPicks(audio: 2, subtitle: .off))
        XCTAssertEqual(stub.transcodeRequests.first?.startTime, 125)
        XCTAssertEqual(stub.transcodeRequests.first?.sourceID, "src")
        XCTAssertEqual(stub.transcodeBitrates, [4_000_000])
        XCTAssertEqual(stub.transcodeTracks.first?.audio, 2)
        XCTAssertEqual(stub.transcodeTracks.first?.subtitle, -1, "off is -1 on a provider")
        XCTAssertEqual(next.stream.playSessionID, "ps2")
        XCTAssertEqual(next.quality.plan, .transcode(step4))
        XCTAssertEqual(next.quality.choice, .auto)
    }

    func test_reload_subtitleStreamZeroIsATrackNotOff() async throws {
        let stub = provider()
        _ = try await playback(stub).reloaded(quality: .auto, plan: .transcode(step4), at: 0,
                                              tracks: TrackPicks(audio: nil, subtitle: .track(0)))
        XCTAssertEqual(stub.transcodeTracks.first?.subtitle, 0)
    }

    func test_reload_forcedOriginal_asksForTheUncappedFile() async throws {
        let stub = provider()
        let next = try await playback(stub, kind: .hlsTranscode, plan: .transcode(step4))
            .reloaded(quality: .original, plan: .original, at: 50)
        XCTAssertEqual(stub.resolveBitrates, [nil])
        XCTAssertTrue(stub.transcodeRequests.isEmpty)
        XCTAssertEqual(next.stream.playSessionID, "ps3")
        XCTAssertEqual(next.quality.plan, .original)
    }

    func test_reload_serverThatWontTranscode_playsTheFile() async throws {
        let stub = provider()
        stub.transcodeResult = nil
        let next = try await playback(stub).reloaded(quality: .auto, plan: .transcode(step4), at: 10)
        XCTAssertEqual(next.quality.plan, .original)
        XCTAssertEqual(next.stream.source.streamKind, .directPlay)
    }

    func test_reload_undecided_aStepBelowTheFilesBitrateTranscodes() async throws {
        let stub = provider()
        let next = try await playback(stub).reloaded(quality: .step(step4), plan: nil, at: 10)
        XCTAssertEqual(next.quality.plan, .transcode(step4))
        XCTAssertEqual(stub.transcodeBitrates, [4_000_000])
    }

    func test_reload_undecided_originalSettingStaysOriginal() async throws {
        let stub = provider()
        let next = try await playback(stub, kind: .hlsTranscode, plan: .transcode(step4))
            .reloaded(quality: .original, plan: nil, at: 10)
        XCTAssertEqual(next.quality.plan, .original)
        XCTAssertEqual(next.quality.choice, .original)
    }

    func test_reload_keepsTheVersionItWasPlaying() async throws {
        let stub = provider()
        _ = try await playback(stub).reloaded(quality: .auto, plan: .original, at: 0)
        XCTAssertEqual(stub.playbackCalls, ["stream(m1,src)"])
    }

    // MARK: - Plan as the player reads it

    func test_effectivePlan_directPlay_isTheDecidedPlan() {
        XCTAssertEqual(playback(provider()).effectivePlan, .original)
        XCTAssertEqual(playback(provider(), plan: .transcode(step4)).effectivePlan, .transcode(step4))
    }

    func test_effectivePlan_aTranscodeTheServerChose_readsAsAStep() {
        let chosen = playback(provider(), kind: .hlsTranscode, plan: .original).effectivePlan
        guard case .transcode(let step) = chosen else { return XCTFail("expected a transcode, got \(chosen)") }
        XCTAssertEqual(step, QualityDecision.highestStep(atMost: 20_000))
    }

    func test_startOffset_resumesUnlessFromTheBeginning() {
        XCTAssertEqual(ProviderPlayback.startOffset(detailOffset: 754, fromBeginning: false), 754)
        XCTAssertNil(ProviderPlayback.startOffset(detailOffset: 754, fromBeginning: true))
        XCTAssertNil(ProviderPlayback.startOffset(detailOffset: 0, fromBeginning: false))
    }

    // MARK: - Track picks on the display shim

    func test_applyingPicks_marksTheChosenStreamsSelected() {
        let detail = playback(provider()).detail
        let picked = ProviderPlaybackMetadata.make(
            detail: detail, source: ProviderPlaybackMetadata.applying(TrackPicks(audio: 2, subtitle: .off), to: source()),
            extras: PlaybackExtras())
        let streams = picked.Media?.first?.Part?.first?.Stream ?? []
        XCTAssertEqual(streams.filter { $0.isAudio && $0.selected == true }.map(\.id), [2])
        XCTAssertTrue(streams.filter(\.isSubtitle).allSatisfy { $0.selected != true })
    }

    func test_applyingPicks_subtitleStreamZeroIsSelectable() {
        var withSubs = source()
        withSubs.subtitleTracks = [subtitle("0", index: 0), subtitle("3", index: 3)]
        let picked = ProviderPlaybackMetadata.applying(TrackPicks(audio: nil, subtitle: .track(0)), to: withSubs)
        XCTAssertEqual(picked.subtitleTracks.filter(\.isSelected).map(\.id), ["0"])
        let off = ProviderPlaybackMetadata.applying(TrackPicks(audio: nil, subtitle: .off), to: picked)
        XCTAssertTrue(off.subtitleTracks.allSatisfy { !$0.isSelected })
    }

    private func subtitle(_ id: String, index: Int) -> SubtitleTrack {
        SubtitleTrack(id: id, index: index, codec: "srt", language: "eng", title: nil, extendedTitle: nil,
                      isDefault: false, isForced: false, isHearingImpaired: false, isEmbedded: false,
                      externalURL: URL(string: "http://s/sub\(id).srt"), isSelected: false)
    }
}
