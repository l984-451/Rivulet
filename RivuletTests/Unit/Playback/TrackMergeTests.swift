// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The merge collapses the player's two parallel track lists into one.
///
/// The join key is the CONTAINER STREAM INDEX, which both sides already carry:
/// AetherEngine's `TrackInfo.id` is literally the container stream index, and
/// Plex reports the same value as `PlexStream.index`. Invariants:
///
///   1. The merged id is always the engine index (it's the selection key).
///   2. Plex's display metadata survives; the engine's disposition flags survive.
///   3. Streams only one side knows about are simply not joined — no shifting.
///   4. Engine membership wins: a track the engine can't select can't exist.
///   5. External sidecars pair by registration order (they have no stream index).
final class TrackMergeTests: XCTestCase {

    // MARK: - Builders

    /// An engine track as `AetherPlayer.translateTrack` produces it: the id IS
    /// the container stream index, and it carries the container's disposition
    /// bits but no long-form title.
    private func engine(
        id: Int,
        name: String = "",
        lang: String? = "eng",
        codec: String? = "subrip",
        channels: Int? = nil,
        isDefault: Bool = false,
        forced: Bool = false,
        hi: Bool = false,
        commentary: Bool = false,
        external: Bool = false
    ) -> MediaTrack {
        MediaTrack(
            id: id,
            name: name.isEmpty ? (lang ?? codec ?? "?") : name,
            language: lang,
            languageCode: lang,
            codec: codec,
            isDefault: isDefault,
            isForced: forced,
            isHearingImpaired: hi,
            isCommentary: commentary,
            extendedDisplayTitle: nil,   // engine never has this
            channels: channels,
            subtitleKey: nil,
            streamIndex: external ? nil : id,   // sidecars aren't in the container
            isExternal: external
        )
    }

    /// A Plex stream. `streamIndex` is `PlexStream.index` — the container index.
    private func plex(
        id: Int,
        streamIndex: Int?,
        name: String = "English",
        lang: String? = "eng",
        codec: String? = "srt",
        forced: Bool = false,
        hi: Bool = false,
        isDefault: Bool = false,
        extended: String? = nil,
        channels: Int? = nil,
        key: String? = nil
    ) -> MediaTrack {
        MediaTrack(
            id: id,
            name: name,
            language: lang,
            languageCode: lang,
            codec: codec,
            isDefault: isDefault,
            isForced: forced,
            isHearingImpaired: hi,
            extendedDisplayTitle: extended,
            channels: channels,
            subtitleKey: key,
            streamIndex: streamIndex,
            isExternal: false
        )
    }

    private func nativeSubtitle(index: Int, embedded: Bool, streamIndex: Int? = nil, url: URL? = nil) -> SubtitleTrack {
        SubtitleTrack(id: "subtitle:\(index)", index: index, codec: "subrip", language: "nld",
                      title: nil, extendedTitle: nil, isDefault: false, isForced: false,
                      isHearingImpaired: false, isEmbedded: embedded, externalURL: url,
                      isSelected: true, nativeStreamIndex: streamIndex)
    }

    func testNativeSubtitleUsesExplicitContainerIndexNotCombinedIndexOrOrdinal() {
        let selected = nativeSubtitle(index: 0, embedded: true, streamIndex: 7)
        XCTAssertEqual(NativeSubtitleSelection.engineID(ordinal: 0, tracks: [selected],
                                                       engine: [engine(id: 0), engine(id: 7)]), 7)
        XCTAssertNil(NativeSubtitleSelection.engineID(ordinal: 0, tracks: [selected],
                                                     engine: [engine(id: 0), engine(id: 8)]))
        let unknown = nativeSubtitle(index: 7, embedded: true)
        XCTAssertNil(NativeSubtitleSelection.engineID(ordinal: 0, tracks: [unknown], engine: [engine(id: 7)]))
    }

    func testNativeSidecarPairsOnlyActuallyRegisteredDeliveries() {
        let tracks = [
            nativeSubtitle(index: 0, embedded: false),
            nativeSubtitle(index: 1, embedded: true, streamIndex: 4),
            nativeSubtitle(index: 5, embedded: false, url: URL(string: "http://127.0.0.1/subtitle/selected.srt")!)
        ]
        let loaded = [engine(id: 4), engine(id: 100_000, external: true)]
        XCTAssertEqual(NativeSubtitleSelection.engineID(ordinal: 2, tracks: tracks, engine: loaded), 100_000)
        XCTAssertNil(NativeSubtitleSelection.engineID(ordinal: 0, tracks: tracks, engine: loaded))
        XCTAssertNil(NativeSubtitleSelection.engineID(ordinal: 3, tracks: tracks, engine: loaded))
    }

    func testNativePlanAudioSurvivesEngineStartupDefaultSelection() {
        // The native plan selects English TrueHD, not the same-language AC3
        // fallback. FFmpeg stream IDs also include video/subtitle streams.
        let tracks = [
            engine(id: 1, codec: "ac3", channels: 6, isDefault: true),
            engine(id: 4, codec: "truehd", channels: 8)
        ]
        var selection = NativeAudioSelection()
        var playing = 1
        if let id = selection.resolve(ordinal: 1, engine: tracks, loadReturned: false) {
            playing = id
        }
        // After publishing the probe, engine.load resolves its own initial
        // default and starts that transport. A premature selection is lost.
        playing = 1
        if let id = selection.resolve(ordinal: 1, engine: tracks, loadReturned: true) {
            playing = id
        }
        XCTAssertEqual(playing, 4, "The authoritative TrueHD track must be selected after startup settles.")
        XCTAssertNil(selection.resolve(ordinal: 1, engine: tracks, loadReturned: true),
                     "Duplicate track publications must not trigger another engine reload.")
    }

    func testNativePlanWaitsForSelectedAudioInsteadOfConsumingPartialInventory() {
        let ac3 = engine(id: 1, codec: "ac3", channels: 6)
        let truehd = engine(id: 4, codec: "truehd", channels: 8)
        var selection = NativeAudioSelection()
        XCTAssertNil(selection.resolve(ordinal: 1, engine: [ac3], loadReturned: true))
        XCTAssertEqual(selection.resolve(ordinal: 1, engine: [ac3, truehd], loadReturned: true), 4)
    }

    func testNativeReplanCanSelectAnotherTrackWithoutChangingContainerIDSpace() {
        let tracks = [
            engine(id: 1, codec: "ac3", channels: 6),
            engine(id: 4, codec: "truehd", channels: 8)
        ]
        var selection = NativeAudioSelection()
        XCTAssertEqual(selection.resolve(ordinal: 1, engine: tracks, loadReturned: true), 4)
        // A fresh provider load, including a seek/replan, resets selection.
        selection = NativeAudioSelection()
        XCTAssertNil(selection.resolve(ordinal: 0, engine: tracks, loadReturned: false))
        XCTAssertEqual(selection.resolve(ordinal: 0, engine: tracks, loadReturned: true), 1)
    }

    // MARK: - Invariant 1: the engine's id survives

    func testMergedTrackKeepsEngineIdNotPlexId() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engine(id: 3), engine(id: 4)],
            plex: [plex(id: 500, streamIndex: 3), plex(id: 501, streamIndex: 4)]
        )
        XCTAssertEqual(merged.map(\.id), [3, 4], "id must be the engine index — it's the selection key")
    }

    // MARK: - Invariant 2: metadata from both sides survives

    /// The #201 case: three English subtitles, first forced. Each is separately
    /// addressable AND keeps its label.
    func testForcedBitAndLabelsSurviveTheMerge() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engine(id: 3), engine(id: 4), engine(id: 5)],
            plex: [
                plex(id: 500, streamIndex: 3, name: "English (Forced)", forced: true),
                plex(id: 501, streamIndex: 4, name: "English"),
                plex(id: 502, streamIndex: 5, name: "English (SDH)", hi: true)
            ]
        )

        XCTAssertEqual(merged.map(\.id), [3, 4, 5])
        XCTAssertEqual(merged.map(\.isForced), [true, false, false])
        XCTAssertEqual(merged.map(\.isHearingImpaired), [false, false, true])
        XCTAssertEqual(merged.map(\.name), ["English (Forced)", "English", "English (SDH)"])
    }

    /// Disposition flags are OR'd: the engine reads the container's bits, Plex
    /// adds its own scan. Either asserting is enough.
    func testDispositionFlagsAreOrdAcrossSources() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engine(id: 3, isDefault: false, forced: true, hi: false)],
            plex: [plex(id: 500, streamIndex: 3, forced: false, hi: true, isDefault: true)]
        )
        XCTAssertTrue(merged[0].isForced, "engine asserted forced")
        XCTAssertTrue(merged[0].isHearingImpaired, "Plex asserted SDH")
        XCTAssertTrue(merged[0].isDefault, "Plex asserted default")
    }

    /// Commentary detection: the engine's disposition flag is authoritative, and
    /// Plex's long title is the fallback for files that don't set it.
    func testCommentaryIsDetectedFromEitherSource() {
        let merged = TrackMerge.mergeAudio(
            engine: [
                engine(id: 1, codec: "eac3", channels: 6),
                engine(id: 2, codec: "eac3", channels: 6, commentary: true),  // engine flag
                engine(id: 3, codec: "eac3", channels: 6)                     // Plex title only
            ],
            plex: [
                plex(id: 50, streamIndex: 1, codec: "eac3", extended: "English (EAC3 5.1)", channels: 6),
                plex(id: 51, streamIndex: 2, codec: "eac3", extended: "English (EAC3 5.1)", channels: 6),
                plex(id: 52, streamIndex: 3, codec: "eac3",
                     extended: "English (EAC3 5.1) - Director's Commentary", channels: 6)
            ]
        )

        XCTAssertFalse(TrackCommentary.isCommentaryOrDescription(merged[0]))
        XCTAssertTrue(TrackCommentary.isCommentaryOrDescription(merged[1]), "engine disposition flag")
        XCTAssertTrue(TrackCommentary.isCommentaryOrDescription(merged[2]), "Plex extendedDisplayTitle")
    }

    /// End to end: auto-selection must not land on the commentary track when it
    /// shares codec and channel count with the main mix.
    func testAutoSelectAvoidsCommentaryAfterMerge() {
        let merged = TrackMerge.mergeAudio(
            engine: [
                engine(id: 1, codec: "eac3", channels: 6),
                engine(id: 2, codec: "eac3", channels: 6)
            ],
            plex: [
                plex(id: 50, streamIndex: 1, codec: "eac3", extended: "English (EAC3 5.1)", channels: 6),
                plex(id: 51, streamIndex: 2, codec: "eac3",
                     extended: "English (EAC3 5.1) - Director's Commentary", channels: 6)
            ]
        )

        let picked = TrackIntentResolver.resolveAudio(intent: AudioIntent(language: "eng"), in: merged)
        XCTAssertEqual(picked?.id, 1, "should pick the main mix, not the commentary")
    }

    // MARK: - Invariant 3: streams only one side knows about don't shift anything

    /// Plex lists baked-in EIA-608 captions as their own stream, which the engine
    /// never reports. Joining on stream index ignores that phantom; ordinals
    /// would shift every subtitle by one.
    func testPlexEmbeddedCCPseudoStreamDoesNotShiftTheMerge() {
        // Container: video=0, audio=1, subs at 2/3/4.
        // Plex ALSO lists a baked-in CC stream, which has no container index of
        // its own that the engine can see (Plex synthesizes a negative id).
        let engineTracks = [engine(id: 2), engine(id: 3), engine(id: 4)]
        let plexTracks = [
            plex(id: -3000001, streamIndex: nil, name: "English CC"),   // embeddedInVideo
            plex(id: 500, streamIndex: 2, name: "English (Forced)", forced: true),
            plex(id: 501, streamIndex: 3, name: "English"),
            plex(id: 502, streamIndex: 4, name: "English (SDH)", hi: true)
        ]

        let merged = TrackMerge.mergeSubtitles(engine: engineTracks, plex: plexTracks)

        XCTAssertEqual(merged.count, 3, "the phantom CC stream must not become a row")
        // Each engine track got ITS OWN Plex metadata, not the previous one's.
        XCTAssertEqual(merged.map(\.name), ["English (Forced)", "English", "English (SDH)"])
        XCTAssertEqual(merged.map(\.isForced), [true, false, false])
        XCTAssertEqual(merged.map(\.id), [2, 3, 4])
    }

    /// Plex listing a stream the engine never demuxed must not produce a row —
    /// it would be unselectable.
    func testPlexStreamsWithNoEngineCounterpartAreDropped() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engine(id: 2), engine(id: 3)],
            plex: [plex(id: 500, streamIndex: 2), plex(id: 501, streamIndex: 3),
                   plex(id: 502, streamIndex: 4)]
        )
        XCTAssertEqual(merged.map(\.id), [2, 3])
    }

    // MARK: - Invariant 4: engine membership wins

    func testEngineTracksWithoutAPlexCounterpartSurviveUnenriched() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engine(id: 2), engine(id: 3)],
            plex: [plex(id: 500, streamIndex: 2, name: "English (Forced)", forced: true)]
        )
        XCTAssertEqual(merged.count, 2, "an engine track must never be dropped")
        XCTAssertTrue(merged[0].isForced)
        XCTAssertFalse(merged[1].isForced, "no counterpart — passes through unenriched")
    }

    func testEmptyPlexMetadataLeavesEngineTracksIntact() {
        let merged = TrackMerge.mergeAudio(
            engine: [engine(id: 1, codec: "eac3", channels: 6)],
            plex: []
        )
        XCTAssertEqual(merged.map(\.id), [1])
        XCTAssertEqual(merged[0].channels, 6)
    }

    func testEmptyEngineListYieldsEmptyMerge() {
        XCTAssertTrue(TrackMerge.mergeAudio(engine: [], plex: [plex(id: 50, streamIndex: 1)]).isEmpty)
        XCTAssertTrue(TrackMerge.mergeSubtitles(engine: [], plex: [plex(id: 500, streamIndex: 2)]).isEmpty)
    }

    // MARK: - Invariant 5: sidecars pair by registration order

    func testExternalSubtitlesPairByRegistrationOrderNotStreamIndex() {
        // 2 embedded (container indices 2, 3) then 2 registered sidecars.
        let engineTracks = [
            engine(id: 2, lang: "eng"),
            engine(id: 3, lang: "spa"),
            engine(id: 100_000, lang: "eng", external: true),
            engine(id: 100_001, lang: "fra", external: true)
        ]
        // Plex interleaves them; sidecars carry a key and (being outside the
        // container) no meaningful stream index to join on.
        let plexTracks = [
            plex(id: 500, streamIndex: 2, name: "English (Forced)", lang: "eng", forced: true),
            plex(id: 600, streamIndex: nil, name: "English SDH sidecar", lang: "eng",
                 hi: true, key: "/library/streams/600"),
            plex(id: 501, streamIndex: 3, name: "Spanish", lang: "spa"),
            plex(id: 601, streamIndex: nil, name: "French sidecar", lang: "fra",
                 key: "/library/streams/601")
        ]

        let merged = TrackMerge.mergeSubtitles(engine: engineTracks, plex: plexTracks)

        XCTAssertEqual(merged.map(\.id), [2, 3, 100_000, 100_001])
        // Embedded joined on stream index, NOT position.
        XCTAssertEqual(merged[0].name, "English (Forced)")
        XCTAssertTrue(merged[0].isForced)
        XCTAssertEqual(merged[1].name, "Spanish")
        // Sidecars paired among themselves, in order, keeping their keys.
        XCTAssertEqual(merged[2].name, "English SDH sidecar")
        XCTAssertTrue(merged[2].isExternal)
        XCTAssertEqual(merged[2].subtitleKey, "/library/streams/600")
        XCTAssertEqual(merged[3].name, "French sidecar")
        XCTAssertEqual(merged[3].subtitleKey, "/library/streams/601")
    }

    // MARK: - Field precedence

    /// The engine is decoding the stream, so it wins on the stream's real shape.
    /// Plex's scan can be stale if a file was replaced in place.
    func testEngineWinsOnCodecAndChannels() {
        let merged = TrackMerge.mergeAudio(
            engine: [engine(id: 1, codec: "truehd", channels: 8)],
            plex: [plex(id: 50, streamIndex: 1, codec: "ac3", channels: 6)]
        )
        XCTAssertEqual(merged[0].codec, "truehd")
        XCTAssertEqual(merged[0].channels, 8)
    }

    /// An empty Plex display title must not blank out the engine's synthesized name.
    func testEmptyPlexNameFallsBackToEngineName() {
        let merged = TrackMerge.mergeSubtitles(
            engine: [engine(id: 2, name: "English")],
            plex: [plex(id: 500, streamIndex: 2, name: "  ")]
        )
        XCTAssertEqual(merged[0].name, "English")
    }
}
