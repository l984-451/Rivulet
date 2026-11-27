// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import Rivulet_iOS

/// The iOS guide builds its rows off the main actor on large lineups, and newer
/// data overtakes an older build instead of being rebuilt over it.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct IOSLiveGuideBuildTests {
    private let base = IOSLiveGuideCoordinator.floorToHalfHour(Date())

    private func channels(_ n: Int) -> [UnifiedChannel] {
        (0..<n).map { UnifiedChannel(id: "c\($0)", sourceType: .xtream, sourceId: "s", name: "Channel \($0)") }
    }

    private func epg(_ chans: [UnifiedChannel], perChannel: Int) -> [String: [UnifiedProgram]] {
        var result: [String: [UnifiedProgram]] = [:]
        for c in chans {
            result[c.id] = (0..<perChannel).map {
                UnifiedProgram(id: "\(c.id):\($0)", channelId: c.id, title: "p",
                               startTime: base.addingTimeInterval(Double($0) * 1800 - 7200),
                               endTime: base.addingTimeInterval(Double($0 + 1) * 1800 - 7200))
            }
        }
        return result
    }

    private func view(_ chans: [UnifiedChannel], perChannel: Int, jump: Int = 0) -> IOSLiveGuideView {
        IOSLiveGuideView(channels: chans, epg: epg(chans, perChannel: perChannel),
                         loadedThrough: base.addingTimeInterval(Double(perChannel) * 1800),
                         recordingIds: [], jumpToken: jump,
                         actions: .init(play: { _ in }, details: { _ in }, menu: { _, _ in UIMenu() }))
    }

    private func wait(until done: () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func buildClipsToTheWindowAndFillsEmptyChannels() {
        let start = base, end = base.addingTimeInterval(3600)
        let chans = channels(2)
        func program(_ id: String, _ from: Double, _ to: Double) -> UnifiedProgram {
            UnifiedProgram(id: id, channelId: "c0", title: id,
                           startTime: start.addingTimeInterval(from * 60), endTime: start.addingTimeInterval(to * 60))
        }
        let guide = ["c0": [program("past", -60, -10), program("a", -10, 20), program("b", 20, 90), program("late", 70, 100)]]
        let rows = IOSGuideRows.build(IOSGuideSnapshot(channels: chans, epg: guide, recordingIds: [], start: start, end: end))
        #expect(rows[0].map { $0.program?.id } == ["a", "b"])
        #expect(rows[0].map(\.startMinute) == [0, 20])
        #expect(rows[0].map(\.minutes) == [20, 40])
        #expect(rows[1].count == 1 && rows[1][0].program == nil && rows[1][0].minutes == 60)
    }

    @Test func smallGuideInstallsBeforeUpdateReturns() {
        let coordinator = IOSLiveGuideCoordinator()
        coordinator.update(view(channels(3), perChannel: 12))
        #expect(coordinator.channels.count == 3)
        #expect(coordinator.rows.map(\.count) == [12, 12, 12])
        #expect(coordinator.installCount == 1)
    }

    @Test func largeGuideBuildsOffMainAndOnlyTheNewestDataLands() async throws {
        let coordinator = IOSLiveGuideCoordinator()
        coordinator.update(view(channels(50), perChannel: 100))
        #expect(coordinator.rows.isEmpty, "installs after the build, not inline")
        coordinator.update(view(channels(60), perChannel: 100))
        coordinator.update(view(channels(70), perChannel: 100))
        try await wait { coordinator.channels.count == 70 }
        #expect(coordinator.channels.count == 70)
        #expect(coordinator.installCount == 1, "the overtaken builds were dropped")
    }

    @Test func aJumpAskedForBeforeTheRowsLandAppliesAfter() async throws {
        let coordinator = IOSLiveGuideCoordinator()
        let container = IOSLiveGuideContainer(coordinator: coordinator)
        container.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        coordinator.update(view(channels(50), perChannel: 200))
        container.layoutIfNeeded()
        #expect(coordinator.rows.isEmpty)
        #expect(coordinator.collectionView.contentOffset.x == 0)
        try await wait { !coordinator.rows.isEmpty }
        #expect(coordinator.collectionView.contentOffset.x > 0, "Now is two hours in")
    }
}
#endif
