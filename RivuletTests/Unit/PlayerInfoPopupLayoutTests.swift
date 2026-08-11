// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoPopupLayoutTests.swift
//  RivuletTests
//
//  Measurements for the Info popup, not assertions about intent: the pill row's
//  horizontal focus rule, the Description tab's vertical centering (an Auto
//  Layout claim — spacers that must collapse when the summary grows), and the
//  monospaced digits the Advanced tab's 1 Hz values depend on.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlayerInfoPopupLayoutTests: XCTestCase {

    // MARK: - Pill row: horizontal focus stops at the ends

    func testHorizontalMoveAllowedOnlyToAdjacentPill() {
        // Description(0) | Info(1) | Advanced(2)
        XCTAssertTrue(PillTabBarView.allowsHorizontalMove(from: 0, to: 1, movingLeft: false, pillCount: 3))
        XCTAssertTrue(PillTabBarView.allowsHorizontalMove(from: 2, to: 1, movingLeft: true, pillCount: 3))
    }

    func testLeftOnFirstPillIsRefused() {
        // The reported bug: Left on Description jumped to Advanced.
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 0, to: 2, movingLeft: true, pillCount: 3))
        // And with no candidate at all it still must not move.
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 0, to: nil, movingLeft: true, pillCount: 3))
    }

    func testRightOnLastPillIsRefused() {
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 2, to: nil, movingLeft: false, pillCount: 3))
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 2, to: 0, movingLeft: false, pillCount: 3))
    }

    func testMoveOffTheBarIsRefused() {
        // nil landing = the engine offered a view outside the bar.
        XCTAssertFalse(PillTabBarView.allowsHorizontalMove(from: 1, to: nil, movingLeft: false, pillCount: 3))
    }

    // MARK: - Description tab: title on top, summary directly under it

    private func descriptionView(summary: String) -> CardDescriptionView {
        var episode = PlexMetadata()
        episode.type = "episode"
        episode.title = "The Pilot"
        episode.grandparentTitle = "Some Show"
        episode.parentIndex = 1
        episode.index = 1
        episode.summary = summary
        let view = CardDescriptionView(metadata: episode)
        // The Info popup's real content area: 560 panel - 2*20 padding
        // - 2*8 pill inset wide, 520 - (56 bar + 16 spacing) tall.
        view.frame = CGRect(x: 0, y: 0, width: 504, height: 448)
        view.layoutIfNeeded()
        return view
    }

    private func label(withText text: String, in view: UIView) -> UILabel? {
        for subview in view.subviews {
            if let label = subview as? UILabel, label.text == text { return label }
            if let found = self.label(withText: text, in: subview) { return found }
        }
        return nil
    }

    /// Issue #278: a short summary used to be centered in the leftover height,
    /// which read as a spacing bug. It starts under the title now, and it must
    /// start there at BOTH lengths — the gap can't change with the summary.
    func testShortSummaryStartsDirectlyUnderTheTitle() throws {
        let summary = "A short summary."
        let view = descriptionView(summary: summary)
        let title = try XCTUnwrap(label(withText: "The Pilot", in: view))
        let body = try XCTUnwrap(label(withText: summary, in: view))

        let titleFrame = title.convert(title.bounds, to: view)
        let bodyFrame = body.convert(body.bounds, to: view)

        XCTAssertEqual(bodyFrame.minY - titleFrame.maxY, 20, accuracy: 2,
                       "short summary must sit one fixed gap under the title, not float mid-sheet")
    }

    func testLongSummaryStartsAtTheSameGapBelowTheTitle() throws {
        // Enough paragraphs to overflow 448pt: the sheet scrolls from the top
        // and the header gap is unchanged.
        let paragraphs = (1...12).map { "Paragraph number \($0) of a very long summary that wraps onto more than one line on its own." }
        let view = descriptionView(summary: paragraphs.joined(separator: "\n"))
        let title = try XCTUnwrap(label(withText: "The Pilot", in: view))
        let first = try XCTUnwrap(label(withText: paragraphs[0], in: view))

        let titleFrame = title.convert(title.bounds, to: view)
        let firstFrame = first.convert(first.bounds, to: view)

        XCTAssertEqual(firstFrame.minY - titleFrame.maxY, 20, accuracy: 2,
                       "the header gap is fixed; it must not depend on how long the summary is")
    }

    // MARK: - Focus only where there is something to scroll

    private func firstRow(in view: UIView) -> InfoFocusRowView? {
        for subview in view.subviews where !subview.isHidden {
            if let row = subview as? InfoFocusRowView { return row }
            if let found = firstRow(in: subview) { return found }
        }
        return nil
    }

    func testSheetThatFitsOnScreenTakesNoFocus() throws {
        let view = descriptionView(summary: "A short summary.")
        XCTAssertFalse(view.infoScrollView.needsFocusableRows)
        let row = try XCTUnwrap(firstRow(in: view))
        XCTAssertFalse(row.canBecomeFocused,
                       "nothing to scroll, so focus must stay on the pills")
    }

    func testOverflowingSheetTakesFocus() throws {
        let paragraphs = (1...12).map { "Paragraph number \($0) of a very long summary that wraps onto more than one line on its own." }
        let view = descriptionView(summary: paragraphs.joined(separator: "\n"))
        // The content must OVERFLOW, not squeeze: a sheet reporting
        // contentSize == bounds has clipped its text with nothing to scroll.
        XCTAssertGreaterThan(view.infoScrollView.contentSize.height, view.infoScrollView.bounds.height,
                             "a long summary must grow the scroll content, not compress its labels")
        XCTAssertTrue(view.infoScrollView.needsFocusableRows)
        let row = try XCTUnwrap(firstRow(in: view))
        XCTAssertTrue(row.canBecomeFocused, "an overflowing sheet needs focus to scroll it")
    }

    func testInfoSheetWithManySectionsOverflowsRatherThanClipping() {
        // The Info tab is the sheet that actually overflows in practice, and it
        // routes every row through the same builders.
        var movie = PlexMetadata()
        movie.type = "movie"
        movie.title = "Some Movie"
        movie.Media = [PlexMedia(
            id: 1, duration: 7_200_000, bitrate: 20_000, width: 3840, height: 2160,
            aspectRatio: 1.78, audioChannels: 6, audioCodec: "eac3", videoCodec: "hevc",
            videoResolution: "4k", container: "mkv", videoFrameRate: "24p", Part: nil)]
        let view = CardInfoView(
            metadata: movie,
            modes: StreamingModeInfo(video: .directPlay, audio: .directPlay, subtitles: .directPlay))
        // Deliberately shorter than one VIDEO section, which is all this
        // fixture has (no Part/Stream, so no AUDIO/SUBTITLES/FILE).
        view.frame = CGRect(x: 0, y: 0, width: 504, height: 100)
        view.layoutIfNeeded()

        XCTAssertGreaterThan(view.infoScrollView.contentSize.height, view.infoScrollView.bounds.height,
                             "sections taller than the sheet must scroll, not compress")
    }

    // MARK: - Same-press gate

    func testPressArrivingWithTheFocusMoveIsGated() {
        // tvOS delivers the press a few ms AFTER the focus move it caused, so a
        // just-moved timestamp must read as "this press is that move".
        XCTAssertTrue(SamePressFocusGate.justMovedFocus(at: CACurrentMediaTime()))
    }

    func testLaterPressIsNotGated() {
        let wellBefore = CACurrentMediaTime() - (SamePressFocusGate.window + 0.1)
        XCTAssertFalse(SamePressFocusGate.justMovedFocus(at: wellBefore))
    }

    func testNeverMovedFocusIsNotGated() {
        XCTAssertFalse(SamePressFocusGate.justMovedFocus(at: -.greatestFiniteMagnitude))
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
