// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TrackListHeaderSquashTests.swift
//  RivuletTests
//
//  An overflowing Subtitles panel scrolls its list instead of squashing the
//  header: the list's self-sizing height must not tie the header label's
//  compression resistance. Same tie as `InfoSheetOverflowTests`.
//

import XCTest
import UIKit
@testable import Rivulet

final class TrackListHeaderSquashTests: XCTestCase {

    func testHeaderKeepsItsHeightWhenTheListOverflowsTheCap() {
        let rows = [CardTrackListView.Row(title: "Off", subtitle: nil, trackId: nil, isSelected: true)]
            + (1...3).map {
                CardTrackListView.Row(title: "English \($0)", subtitle: "English • SRT",
                                      trackId: $0, isSelected: false)
            }
        let stepper = CardStepperConfig(title: "Delay", value: { "0.0s" }, onStep: { _ in })
        let list = CardTrackListView(header: "Subtitles", rows: rows,
                                     steppers: [stepper, stepper], onSelect: { _ in })

        // Capped, not fixed, like the panel (see InfoSheetOverflowTests).
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 480, height: 2000))
        list.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: host.topAnchor),
            list.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: 480),
            list.heightAnchor.constraint(lessThanOrEqualToConstant: PlayerRailPanelView.fullContentHeight),
        ])
        host.layoutIfNeeded()

        guard let header = list.subviews.compactMap({ $0 as? UILabel }).first(where: { $0.text == "Subtitles" }),
              let scroll = list.subviews.compactMap({ $0 as? UIScrollView }).first
        else { return XCTFail("header label or scroll view missing") }

        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height,
                             "fixture must overflow the cap or the test proves nothing")
        XCTAssertEqual(header.frame.height, header.intrinsicContentSize.height, accuracy: 0.5,
                       "header was squashed instead of the list scrolling")
    }
}

final class CardChoiceSubmenuScrollTests: XCTestCase {

    /// Issue #354: with many audio tracks the list is scrolled down when
    /// Enhance Dialogue is chosen. The short submenu then opened scrolled past
    /// its own end, so the card looked empty.
    func testOpeningAChoiceResetsTheScrollOffset() {
        let rows = (1...30).map {
            CardTrackListView.Row(title: "Track \($0)", subtitle: nil, trackId: $0, isSelected: false)
        }
        let choice = CardChoiceConfig(title: "Enhance Dialogue", options: ["Off", "Low", "High"],
                                      selected: { 0 }, onSelect: { _ in })
        let list = CardTrackListView(header: "Audio", rows: rows, choices: [choice], onSelect: { _ in })

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 480, height: 2000))
        list.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: host.topAnchor),
            list.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            list.widthAnchor.constraint(equalToConstant: 480),
            list.heightAnchor.constraint(lessThanOrEqualToConstant: PlayerRailPanelView.fullContentHeight),
        ])
        host.layoutIfNeeded()

        guard let scroll = list.subviews.compactMap({ $0 as? UIScrollView }).first,
              let stack = scroll.subviews.compactMap({ $0 as? UIStackView }).first,
              let choiceRow = stack.arrangedSubviews.last as? CardTrackRowButton
        else { return XCTFail("scroll view or choice row missing") }

        scroll.contentOffset = CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height)
        choiceRow.onTap?()
        host.layoutIfNeeded()

        XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 0.5)
    }
}

final class CardTrackListStateTests: XCTestCase {

    func testDisabledStatusRowLeavesInitialFocusOnAnEnabledAction() throws {
        let list = CardTrackListView(header: "Silo Subtitles", rows: [
            CardTrackListView.Row(title: "Server Operation", subtitle: "Starting", trackId: 0,
                                 isSelected: true, isEnabled: false)
        ], actions: [CardActionConfig(title: "Close", run: { _ in })], onSelect: { _ in })
        let rows = try buttons(in: list)
        let status = try XCTUnwrap(rows.first { $0.row.title == "Server Operation" })
        let close = try XCTUnwrap(rows.first { $0.row.title == "Close" })

        XCTAssertFalse(status.isEnabled)
        XCTAssertFalse(status.canBecomeFocused)
        XCTAssertTrue(list.preferredFocusEnvironments.first === close)
    }

    func testActionAvailabilityDoesNotTargetLanguageOrStyleRows() throws {
        var canCancel = false
        let list = CardTrackListView(header: "Subtitles", rows: [
            CardTrackListView.Row(title: "On", subtitle: nil, trackId: 1, isSelected: false),
            CardTrackListView.Row(title: "Off", subtitle: nil, trackId: nil, isSelected: true)
        ], actions: [
            CardActionConfig(title: "Cancel Silo Job", isEnabled: { canCancel }, run: { _ in })
        ], choices: [
            CardChoiceConfig(title: "Style", options: ["Default", "Large"], selected: { 0 }, onSelect: { _ in })
        ], languageRows: [
            CardTrackListView.Row(title: "Unavailable", subtitle: nil, trackId: 1,
                                 isSelected: false, isEnabled: false)
        ], languageValue: "Unavailable", onSelect: { _ in })
        let rows = try buttons(in: list)
        let cancel = try XCTUnwrap(rows.first { $0.row.title == "Cancel Silo Job" })
        let language = try XCTUnwrap(rows.first { $0.row.title == "Language" })
        let style = try XCTUnwrap(rows.first { $0.row.title == "Style" })

        XCTAssertFalse(cancel.isEnabled)
        canCancel = true
        list.refreshActionAvailability()
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertTrue(language.isEnabled)
        XCTAssertTrue(style.isEnabled)
        canCancel = false
        list.refreshActionAvailability()
        XCTAssertFalse(cancel.isEnabled)
        XCTAssertTrue(language.isEnabled)
        XCTAssertTrue(style.isEnabled)

        language.onTap?()
        let track = try XCTUnwrap(try buttons(in: list).first)
        XCTAssertFalse(track.isEnabled)
        XCTAssertFalse(track.canBecomeFocused)
        canCancel = true
        list.refreshActionAvailability()
        XCTAssertFalse(track.isEnabled, "Hidden actions must not update Language's track rows")
        XCTAssertTrue(list.handleMenuPress())
        let rebuiltCancel = try XCTUnwrap(try buttons(in: list).first { $0.row.title == "Cancel Silo Job" })
        XCTAssertTrue(rebuiltCancel.isEnabled)
    }

    func testGeneratedSelectionAndDownloadProgressSurviveLanguageNavigation() throws {
        let generatedID = UniversalPlayerViewModel.generatedSubtitleId
        var pickedID: Int?
        let list = CardTrackListView.subtitleMenu(tracks: [
            MediaTrack(id: 1, name: "French", language: "French"),
            MediaTrack(id: generatedID, name: "English", language: "Generated")
        ], selectedTrackId: nil, onTrackId: 1, onSelect: { pickedID = $0 })

        list.checkTrack(generatedID)
        list.updateTrack(generatedID, subtitle: "Downloading 50%")
        let root = try buttons(in: list)
        XCTAssertTrue(try XCTUnwrap(root.first { $0.row.title == "On" }).isChecked)
        XCTAssertFalse(try XCTUnwrap(root.first { $0.row.title == "Off" }).isChecked)
        try XCTUnwrap(root.first { $0.row.title == "Language" }).onTap?()
        let generated = try XCTUnwrap(try buttons(in: list).first { $0.row.trackId == generatedID })
        XCTAssertTrue(generated.isChecked)
        XCTAssertEqual(generated.row.subtitle, "Downloading 50%")

        list.updateTrack(generatedID, subtitle: "Downloading 60%")
        XCTAssertTrue(list.handleMenuPress())
        let rebuiltRoot = try buttons(in: list)
        try XCTUnwrap(rebuiltRoot.first { $0.row.title == "On" }).onTap?()
        XCTAssertEqual(pickedID, generatedID)
        try XCTUnwrap(rebuiltRoot.first { $0.row.title == "Language" }).onTap?()
        let rebuiltGenerated = try XCTUnwrap(try buttons(in: list).first { $0.row.trackId == generatedID })
        XCTAssertTrue(rebuiltGenerated.isChecked)
        XCTAssertEqual(rebuiltGenerated.row.subtitle, "Downloading 60%")
    }

    private func buttons(in list: CardTrackListView) throws -> [CardTrackRowButton] {
        let scroll = try XCTUnwrap(list.subviews.compactMap { $0 as? UIScrollView }.first)
        let stack = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIStackView }.first)
        return stack.arrangedSubviews.compactMap { $0 as? CardTrackRowButton }
    }
}
