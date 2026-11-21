// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class LoadingActivityTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)

    private func item(_ kind: LoadingItem.Kind, after seconds: TimeInterval = 0, received: Int64 = 0,
                      expected: Int64? = nil, processing: Bool = false) -> LoadingItem {
        LoadingItem(id: UUID(), kind: kind, startedAt: start.addingTimeInterval(seconds),
                    received: received, expected: expected, processing: processing)
    }

    func test_aQuickLoad_neverShows() {
        XCTAssertNil(LoadingActivity.text(for: [item(.channels)], now: start.addingTimeInterval(0.5)))
        XCTAssertNil(LoadingActivity.text(for: [], now: start))
    }

    func test_aKnownSize_readsAsAPercentage() throws {
        let text = try XCTUnwrap(LoadingActivity.text(for: [item(.channels, received: 38, expected: 100)],
                                                      now: start.addingTimeInterval(2)))
        XCTAssertTrue(text.hasPrefix(LoadingActivity.title(.channels)))
        XCTAssertTrue(text.contains("38"))
    }

    func test_noSize_readsAsBytes_andNothingBeforeTheFirstByte() {
        let bytes = item(.guide, received: 38_000_000)
        XCTAssertEqual(LoadingActivity.detail(bytes), Int64(38_000_000).formatted(.byteCount(style: .file)))
        XCTAssertNil(LoadingActivity.detail(item(.guide)))
        XCTAssertEqual(LoadingActivity.text(for: [item(.guide)], now: start.addingTimeInterval(2)),
                       LoadingActivity.title(.guide))
    }

    func test_processing_replacesTheCount() {
        XCTAssertEqual(LoadingActivity.detail(item(.guide, received: 5, expected: 10, processing: true)),
                       String(localized: "Processing…"))
    }

    func test_theOldestShows_withHowManyMoreRun() throws {
        let items = [item(.channels), item(.guide, after: 0.2), item(.guide, after: 1.8)]
        let text = try XCTUnwrap(LoadingActivity.text(for: items, now: start.addingTimeInterval(2)))
        XCTAssertTrue(text.hasPrefix(LoadingActivity.title(.channels)))
        // The guide started under a second ago: not counted yet.
        XCTAssertTrue(text.hasSuffix(" +1"))
    }

    @MainActor
    func test_aReport_comesAndGoes() async throws {
        let report = LoadingActivity.begin(.channels)
        for _ in 0..<50 where !LoadingActivity.shared.items.contains(where: { $0.id == report.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(LoadingActivity.shared.items.contains { $0.id == report.id })
        report.finish()
        for _ in 0..<50 where LoadingActivity.shared.items.contains(where: { $0.id == report.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(LoadingActivity.shared.items.contains { $0.id == report.id })
    }
}
