// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import XCTest
@testable import Rivulet

@MainActor
final class MediaCapabilityBadgeLayoutTests: XCTestCase {
    func testHDR10PlusRemainsCompleteOnOneLineWhenBadgesWrap() throws {
        let video = VideoTrack(id: "video", codec: "hevc", profile: "Main 10", level: nil,
                               width: 3840, height: 2160, frameRate: 24, bitrate: nil,
                               videoRange: .hdr10Plus, isDefault: true, scanType: "progressive")
        let source = MediaSource(id: "file", container: "mkv", duration: 7200, bitrate: nil,
                                 fileSize: nil, fileName: nil, videoResolution: "4k", videoTracks: [video],
                                 audioTracks: [], subtitleTracks: [], streamKind: .directPlay, streamURL: nil)
        // The narrow column wraps whole capsules; the wide hero keeps its row.
        for width in [CGFloat(160), 860] {
            let root = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
            let badges = MediaCapabilityBadgesView()
            badges.configure(source: source, style: .standard)
            badges.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(badges)
            NSLayoutConstraint.activate([
                badges.topAnchor.constraint(equalTo: root.topAnchor),
                badges.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                badges.widthAnchor.constraint(equalTo: root.widthAnchor)
            ])
            root.layoutIfNeeded()
            root.setNeedsLayout()
            root.layoutIfNeeded()
            let label = try XCTUnwrap(labels(in: badges).first { $0.text == "HDR10+" })
            let font = try XCTUnwrap(label.font)
            let textWidth = ("HDR10+" as NSString).size(withAttributes: [.font: font]).width
            XCTAssertGreaterThanOrEqual(label.bounds.width, textWidth - 0.5, "the plus must not be clipped")
            XCTAssertLessThanOrEqual(label.bounds.height, ceil(font.lineHeight) + 1,
                                     "the plus must not become a second line")
            XCTAssertTrue(root.bounds.contains(label.convert(label.bounds, to: root)),
                          "the whole capsule must stay inside the metadata column")
        }
    }

    private func labels(in view: UIView) -> [UILabel] {
        if let label = view as? UILabel { return [label] }
        return view.subviews.flatMap { labels(in: $0) }
    }
}
