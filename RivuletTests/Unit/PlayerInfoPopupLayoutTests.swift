// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoPopupLayoutTests.swift
//  RivuletTests
//
//  Measurements for the player's info panes, not assertions about intent: the
//  Details pane's sections and columns, section headings, and the monospaced
//  digits its 1 Hz stats depend on.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlayerInfoPopupLayoutTests: XCTestCase {

    // MARK: - Details pane

    func testAudioRowShowsParsedFieldsOnly() throws {
        func stream(_ title: String) throws -> PlexStream {
            try JSONDecoder().decode(PlexStream.self, from: Data("""
            {"id": 7, "streamType": 2, "codec": "truehd", "profile": "dolby truehd + dolby atmos",
             "channels": 8, "audioChannelLayout": "7.1", "language": "English", "title": "\(title)"}
            """.utf8))
        }
        let release = PlayerDetailsPaneView.audioRow(
            try stream("Baywatch.2017.UNRATED.2160p.BluRay.REMUX.HEVC.TrueHD.7.1.Atmos-FGT"), index: 0)
        XCTAssertEqual(release, .init(label: "English", value: "TrueHD 7.1 Atmos"))
        let commentary = PlayerDetailsPaneView.audioRow(try stream("Director's Commentary"), index: 1)
        XCTAssertEqual(commentary, .init(label: "English", value: "TrueHD 7.1 Atmos · Commentary"))
    }

    func testAudioMenuNamesTrackByLanguageAndFormat() {
        let plexStyle = MediaTrack(id: 1, name: "English (TRUEHD 7.1)", language: "English", codec: "truehd",
                                   channels: 8, profile: "dolby truehd + dolby atmos")
        XCTAssertEqual(plexStyle.audioMenuTitle, "English")
        XCTAssertEqual(plexStyle.audioMenuSubtitle, "TrueHD 7.1 Atmos")
        let described = MediaTrack(id: 2, name: "Audio Description", language: "English", codec: "ac3", channels: 2)
        XCTAssertEqual(described.audioMenuSubtitle, "AC3 2.0 • Audio Description")
    }

    func testSubtitleMenuShowsLanguageOverFlagsTitleAndFormat() {
        func track(_ title: String?, forced: Bool = false) -> MediaTrack {
            MediaTrack(id: 1, name: "English (SRT)", language: "English", languageCode: "en", codec: "subrip",
                       isForced: forced, title: title)
        }
        XCTAssertEqual(track(nil).subtitleMenuTitle, "English")
        XCTAssertEqual(track(nil).subtitleMenuSubtitle, "SRT")
        XCTAssertEqual(track("English Forced", forced: true).subtitleMenuSubtitle, "Forced • SRT")
        XCTAssertEqual(track("Commentary").subtitleMenuSubtitle, "Commentary • SRT")
        XCTAssertEqual(track("Signs & Songs", forced: true).subtitleMenuSubtitle, "Forced • Signs & Songs • SRT")
    }

    func testDetailsMediaSectionsCarryEveryVideoFact() {
        var movie = PlexMetadata()
        movie.type = "movie"
        movie.title = "Some Movie"
        movie.Media = [PlexMedia(
            id: 1, duration: 7_200_000, bitrate: 20_000, width: 3840, height: 2160,
            aspectRatio: 1.78, audioChannels: 6, audioCodec: "eac3", videoCodec: "hevc",
            videoResolution: "4k", container: "mkv", videoFrameRate: "24p", Part: nil)]
        let sections = PlayerDetailsPaneView.mediaSections(
            metadata: movie,
            modes: StreamingModeInfo(video: .directPlay, audio: .directPlay, subtitles: .directPlay))
        XCTAssertEqual(sections.map(\.title), ["VIDEO"], "no Part, so no AUDIO, SUBTITLES or FILE")
        XCTAssertEqual(sections[0].rows.map(\.label), ["Mode", "Codec", "Resolution", "Dimensions", "Frame Rate", "Bitrate"])
        XCTAssertEqual(sections[0].rows.first { $0.label == "Bitrate" }?.value, PlayerInfoSheetStyle.bitrate(20_000_000))
    }

    func testDetailsStatsDropSectionsTheEngineDoesNotReport() {
        XCTAssertTrue(PlayerDetailsPaneView.statsSections(AetherAdvancedStats()).isEmpty)
    }

    func testDetailsLiveStatsFollowAudioAndDecodeStreamFitsOneColumn() {
        let full = AetherAdvancedStats(
            backend: "VideoToolbox HEVC (HW)", audioBridge: "Stream-copy (AAC)", audioDelivery: "Stream copy",
            instantBitrateMbps: 31.4, averageBitrateMbps: 29.9, audioBridgeBitrateMbps: 0.6,
            observedFps: 24, droppedFrameCount: 12, forwardBufferSeconds: 30, cachedBytes: 1_000_000,
            networkThroughputMbps: 80, networkTransferredBytes: 2_000_000, avSyncGapMs: 4,
            producerRestartCount: 0, rssMb: 300)
        let row = { (title: String) in PlayerDetailsPaneView.Section(title: title, rows: [.init(label: "A", value: "B")]) }
        let pane = PlayerDetailsPaneView(media: [row("VIDEO"), row("AUDIO"), row("FILE")], statsProvider: { full })

        func labels(in view: UIView) -> [UILabel] {
            (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels)
        }
        let all = labels(in: pane)
        func x(_ view: UIView) -> CGFloat { view.convert(view.bounds, to: pane).minX }
        let titles = ["VIDEO", "AUDIO", "DECODE / STREAM", "BUFFER / NETWORK", "FILE", "ENGINE"]
        let headers = titles.compactMap { title in all.first { $0.text == title }?.superview }
        XCTAssertEqual(headers.count, titles.count)
        XCTAssertEqual(headers.map(x), headers.map(x).sorted(), "sections run in \(titles) order")

        let last = try? XCTUnwrap(all.first { $0.attributedText?.string.hasPrefix("Audio Bitrate:") == true })
        XCTAssertEqual(last.map(x), x(headers[2]), "DECODE / STREAM's last row stays in its header's column")
    }

    // MARK: - Section headings

    func testSectionHeadingRuleFillsTheRemainingWidth() throws {
        let heading = try XCTUnwrap(PlayerInfoSheetStyle.sectionLabel("VIDEO") as? UIStackView)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 504, height: 40))
        heading.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            heading.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        host.layoutIfNeeded()

        let label = try XCTUnwrap(heading.arrangedSubviews.first as? UILabel)
        let rule = try XCTUnwrap(heading.arrangedSubviews.last)
        XCTAssertEqual(label.bounds.width, label.intrinsicContentSize.width, accuracy: 1,
                       "the title must keep its own width; the rule takes the slack")
        XCTAssertGreaterThan(rule.bounds.width, 300)
        XCTAssertEqual(rule.bounds.height, 2)
    }

    // MARK: - Advanced tab: values must not reflow as they tick

    func testInfoRowValueUsesMonospacedDigits() throws {
        let text = PlayerInfoSheetStyle.infoRowText("Bitrate", "12.3 Mbps")
        let valueFont = try XCTUnwrap(
            text.attribute(.font, at: text.length - 1, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(valueFont, UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular))
    }

    func testDigitWidthIsStableAcrossValues() {
        // The actual property that matters: a counter changing digits must not
        // change the string's width.
        let font = UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        let width: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: [.font: font]).width }
        XCTAssertEqual(width("111 MB"), width("888 MB"), accuracy: 0.5)
    }
}
