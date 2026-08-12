// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLiveTunerGroupTests.swift
//  RivuletTests
//
//  Guide grouping for Plex Live TV: tuner group naming and the favourites tab.
//

import XCTest
@testable import Rivulet

final class PlexLiveTunerGroupTests: XCTestCase {

    private func makeDVR(
        key: String? = "159",
        friendlyName: String? = nil,
        device: String? = nil,
        model: String? = nil,
        make: String? = nil
    ) -> PlexDVR {
        PlexDVR(
            key: key, uuid: nil, friendlyName: friendlyName, device: device,
            model: model, make: make, status: nil, lineup: "lineup://tv.plex.providers.epg.xmltv/x",
            epgIdentifier: nil, Device: nil
        )
    }

    // MARK: - Tuner name

    /// The lineup fragment is the name the user chose their guide by, so it
    /// beats the hardware description.
    func test_lineupNameWins() {
        let dvr = PlexDVR(
            key: "161", uuid: nil, friendlyName: "Lounge Tuner", device: "TBS6209",
            model: "6209", make: "TBS", status: nil,
            lineup: "lineup://tv.plex.providers.epg.cloud/5fc7#Freeview - Perth (58 channels)",
            epgIdentifier: nil, Device: nil
        )
        XCTAssertEqual(dvr.guideGroupName, "Freeview - Perth")
    }

    /// Plex appends a channel count for its own picker. It goes stale the moment
    /// a channel is hidden, so it is not part of the name.
    func test_lineupChannelCountSuffixIsDropped() {
        XCTAssertEqual(
            PlexDVR.lineupName(from: "lineup://x/y#Freeview - Perth (58 channels)"),
            "Freeview - Perth"
        )
        XCTAssertEqual(PlexDVR.lineupName(from: "lineup://x/y#My Guide"), "My Guide")
    }

    func test_lineupNameHandlesPercentEncodingAndAbsence() {
        XCTAssertEqual(
            PlexDVR.lineupName(from: "lineup://x/y#Freeview%20-%20Perth%20(58%20channels)"),
            "Freeview - Perth"
        )
        XCTAssertNil(PlexDVR.lineupName(from: "lineup://x/y"))
        XCTAssertNil(PlexDVR.lineupName(from: "lineup://x/y#   "))
        XCTAssertNil(PlexDVR.lineupName(from: nil))
    }

    func test_friendlyNameWinsWhenTheLineupIsUnnamed() {
        let dvr = makeDVR(friendlyName: "Lounge Tuner", device: "TBS6209", make: "TBS", model: "6209")
        XCTAssertEqual(dvr.guideGroupName, "Lounge Tuner")
    }

    func test_fallsBackThroughDeviceThenMakeModel() {
        XCTAssertEqual(makeDVR(device: "TBS6209").guideGroupName, "TBS6209")
        XCTAssertEqual(makeDVR(make: "TBS", model: "6209").guideGroupName, "TBS 6209")
    }

    /// A numeric DVR key is a worse heading than none at all, so an unnamed
    /// tuner must leave its channels ungrouped rather than filed under "159".
    func test_unnamedTunerHasNoGroup() {
        XCTAssertNil(makeDVR().guideGroupName)
    }

    func test_blankNamesAreTreatedAsAbsent() {
        XCTAssertEqual(makeDVR(friendlyName: "   ", device: "TBS6209").guideGroupName, "TBS6209")
        XCTAssertNil(makeDVR(friendlyName: "", device: "  ").guideGroupName)
    }

    // MARK: - Channel → guide group

    private func makeChannel(tunerName: String?) -> PlexLiveTVChannel {
        PlexLiveTVChannel(
            ratingKey: "ABC", key: "/tv.plex.providers.epg.xmltv:159/metadata/ABC",
            guid: nil, type: "channel", title: "ABC", summary: nil, thumb: nil, art: nil,
            year: nil, channelCallSign: "ABC", channelIdentifier: "ABC", channelShortTitle: nil,
            channelThumb: nil, channelTitle: "ABC", channelNumber: "2", streamURL: nil,
            tunerName: tunerName
        )
    }

    func test_tunerNameBecomesTheGuideGroup() {
        let unified = makeChannel(tunerName: "Lounge Tuner")
            .toUnifiedChannel(sourceId: "s", serverURL: "https://example.invalid:32400", authToken: "t")
        XCTAssertEqual(unified.groupTitle, "Lounge Tuner")
    }

    /// The guide reads nil as "ungrouped", which is the behaviour Plex sources
    /// had before this existed — so an unnamed DVR is a no-op, not a new tab.
    func test_noTunerNameLeavesTheChannelUngrouped() {
        let unified = makeChannel(tunerName: nil)
            .toUnifiedChannel(sourceId: "s", serverURL: "https://example.invalid:32400", authToken: "t")
        XCTAssertNil(unified.groupTitle)
    }
}
