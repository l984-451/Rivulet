// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EPGGuideBuildTests.swift
//  RivuletTests
//
//  The guide's row build runs off the main actor, and newer data overtakes an
//  older build instead of being rebuilt over it.
//

import XCTest
@testable import Rivulet

@MainActor
final class EPGGuideBuildTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ppm = EPGTheme.pointsPerMinute
    private let inset = EPGTheme.channelColumnWidth

    private func channels(_ n: Int) -> [UnifiedChannel] {
        (0..<n).map { UnifiedChannel(id: "c\($0)", sourceType: .xtream, sourceId: "s", name: "Channel \($0)") }
    }

    private func program(_ id: String, _ from: Double, _ to: Double, channel: String = "c0") -> UnifiedProgram {
        UnifiedProgram(id: id, channelId: channel, title: id,
                       startTime: t0.addingTimeInterval(from * 60), endTime: t0.addingTimeInterval(to * 60))
    }

    private func build(_ chans: [UnifiedChannel], _ epg: [String: [UnifiedProgram]], minutes: Int = 120) -> EPGGridRows {
        EPGGridRows.build(channels: chans, programsByChannel: epg, timelineStart: t0, totalMinutes: minutes,
                          pointsPerMinute: ppm, leadingInset: inset, placeholderTitle: "none")
    }

    /// The order and clipping the guide used before the build moved off the main actor.
    private func reference(_ guide: [UnifiedProgram], minutes: Int) -> [(id: String, x: CGFloat, w: CGFloat)] {
        let total = Double(minutes)
        let minStart = -Double(inset) / Double(ppm)
        let ranges = guide.compactMap { p -> (cs: Double, ce: Double, id: String)? in
            let s = p.startTime.timeIntervalSince(t0) / 60, e = p.endTime.timeIntervalSince(t0) / 60
            guard e > 0, s < total else { return nil }
            return (max(minStart, s), min(total, e), p.id)
        }.sorted { $0.cs < $1.cs }
        return ranges.enumerated().map { i, r in
            let x = CGFloat(r.cs) * ppm
            var w = CGFloat(r.ce - r.cs) * ppm
            if i + 1 < ranges.count { w = min(w, CGFloat(ranges[i + 1].cs) * ppm - x) }
            return (r.id, x, max(w, 2))
        }
    }

    func test_build_matchesTheOldRowRules() {
        // Unsorted, one overlap, one ended before the timeline, one past its end.
        let guide = [program("b", 30, 90), program("a", 0, 40), program("past", -90, -30),
                     program("clipped", 100, 200), program("late", 130, 160)]
        let rows = build(channels(1), ["c0": guide])
        let expected = reference(guide, minutes: 120)
        XCTAssertEqual(rows.programs[0].map(\.id), expected.map(\.id))
        XCTAssertEqual(rows.programs[0].map(\.id), ["a", "b", "clipped"])
        XCTAssertEqual(rows.spans[0].map(\.x), expected.map(\.x))
        XCTAssertEqual(rows.spans[0].map(\.width), expected.map(\.w))
    }

    func test_build_aSortedRowIsKeptWhole() {
        let guide = [program("a", 0, 30), program("b", 30, 60), program("c", 60, 120)]
        XCTAssertEqual(build(channels(1), ["c0": guide]).programs[0], guide)
    }

    func test_build_aChannelWithNoGuideGetsPlaceholders() {
        let rows = build(channels(2), ["c0": [program("a", 0, 30)]], minutes: 480)
        XCTAssertEqual(rows.programs[1].count, 2)
        XCTAssertTrue(rows.programs[1].allSatisfy { $0.title == "none" && $0.channelId == "c1" })
        XCTAssertEqual(rows.spans.count, 2)
    }

    // MARK: Coalescing

    private func guide(_ chans: [UnifiedChannel], perChannel: Int) -> EPGGuide {
        var epg: [String: [UnifiedProgram]] = [:]
        for c in chans {
            epg[c.id] = (0..<perChannel).map { program("\(c.id):\($0)", Double($0) * 30, Double($0 + 1) * 30, channel: c.id) }
        }
        return EPGGuide(channels: chans, programsByChannel: epg, timelineStart: t0,
                        totalMinutes: perChannel * 30, now: t0, categoryTitles: [], selectedCategory: nil,
                        onCategorySelect: { _ in }, onFocus: { _, _ in }, onSelect: { _, _ in })
    }

    /// The coordinator holds its collection view weakly.
    private var collectionView: UICollectionView?

    private func coordinator(_ first: EPGGuide) -> (EPGGuide.Coordinator, EPGLayout) {
        let layout = EPGLayout()
        let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), collectionViewLayout: layout)
        collectionView = cv
        let c = EPGGuide.Coordinator(first)
        c.collectionView = cv
        return (c, layout)
    }

    func test_smallGuide_installsBeforeApplyReturns() {
        let g = guide(channels(3), perChannel: 4)
        let (c, layout) = coordinator(g)
        c.apply(g, to: layout)
        XCTAssertEqual(c.sections.count, 3)
        XCTAssertEqual(c.programs.map(\.count), [4, 4, 4])
    }

    func test_largeGuide_buildsOffMainAndOnlyTheNewestDataLands() async throws {
        let first = guide(channels(50), perChannel: 100)
        let (c, layout) = coordinator(first)
        c.apply(first, to: layout)
        XCTAssertEqual(c.sections.count, 0, "installs after the build, not inline")
        // Two newer changes arrive while the first build runs.
        c.apply(guide(channels(60), perChannel: 100), to: layout)
        let last = guide(channels(70), perChannel: 100)
        c.apply(last, to: layout)
        for _ in 0..<200 where c.sections.count != 70 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(c.sections.count, 70)
        XCTAssertEqual(c.installCount, 1, "the overtaken builds were dropped, not installed")
    }

    func test_focusRequestWaitsForThePendingRows() async throws {
        let g = guide(channels(50), perChannel: 100)
        let (c, layout) = coordinator(g)
        c.apply(g, to: layout)
        c.requestLiveFocus(channelId: "c3")
        XCTAssertTrue(c.hasDeferredFocus)
        for _ in 0..<200 where c.hasDeferredFocus { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(c.hasDeferredFocus)
        XCTAssertEqual(c.sections.count, 50)
    }
}
