// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TrackListHeaderSquashTests.swift
//  RivuletTests
//
//  The Subtitles panel (Off + three tracks + Delay and Height steppers)
//  overflows the rail panel's cap. With the list's self-sizing scroll height at
//  `.defaultHigh` it tied the header label's compression resistance, and the
//  solver squashed the header instead of scrolling the list: the title rendered
//  cut off at the top. Same tie as `InfoSheetOverflowTests`.
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
