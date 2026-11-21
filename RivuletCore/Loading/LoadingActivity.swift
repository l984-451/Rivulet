// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The large loads a viewer waits on (an IPTV source's channel list, its guide), for the
//  loading pill each app shows over its main screen. A load reports
//  through a `LoadingReport` from any thread; the pill reads `text`, which stays nil until a
//  load has run for `delay`, so a quick one never flashes. Pills: tvOS `LoadingPillView`,
//  iOS and Mac `LoadingPill`.

import Combine
import Foundation
import os

nonisolated struct LoadingItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case channels, guide
    }

    let id: UUID
    let kind: Kind
    let startedAt: Date
    var received: Int64 = 0
    /// The download's size, when the server sends one.
    var expected: Int64?
    /// Downloaded; being read.
    var processing = false
}

@MainActor
final class LoadingActivity: ObservableObject {
    static let shared = LoadingActivity()

    /// Seconds a load runs before the pill shows it.
    nonisolated static let delay: TimeInterval = 1

    @Published private(set) var items: [LoadingItem] = []
    /// What the pill says; nil hides it.
    @Published private(set) var text: String?

    private var finished = Set<UUID>()
    private var tick: Timer?

    /// Starts reporting a load; call `finish()` on the report when it ends, however it ends.
    nonisolated static func begin(_ kind: LoadingItem.Kind) -> LoadingReport {
        let report = LoadingReport(id: UUID(), kind: kind, startedAt: Date())
        Task { @MainActor in shared.add(report) }
        return report
    }

    // MARK: Text

    /// The pill's line: the oldest load shown, its progress, and how many more run beside it.
    nonisolated static func text(for items: [LoadingItem], now: Date = Date()) -> String? {
        let shown = items.filter { now.timeIntervalSince($0.startedAt) >= delay }
        guard let first = shown.first else { return nil }
        var line = [title(first.kind), detail(first)].compactMap { $0 }.joined(separator: " · ")
        if shown.count > 1 { line += " +\(shown.count - 1)" }
        return line
    }

    nonisolated static func title(_ kind: LoadingItem.Kind) -> String {
        switch kind {
        case .channels: String(localized: "Loading channels")
        case .guide: String(localized: "Loading guide")
        }
    }

    /// "38%" with a known size, "38 MB" without; nil before the first byte.
    nonisolated static func detail(_ item: LoadingItem) -> String? {
        if item.processing { return String(localized: "Processing…") }
        if let expected = item.expected, expected > 0 {
            let fraction = min(Double(item.received) / Double(expected), 1)
            return fraction.formatted(.percent.precision(.fractionLength(0)))
        }
        guard item.received > 0 else { return nil }
        return item.received.formatted(.byteCount(style: .file))
    }

    // MARK: Updates

    fileprivate func add(_ report: LoadingReport) {
        guard !finished.contains(report.id) else { return }
        items.append(LoadingItem(id: report.id, kind: report.kind, startedAt: report.startedAt))
        refresh()
    }

    fileprivate func update(_ id: UUID, received: Int64, expected: Int64?, processing: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // Processing sticks: a byte count still on its way must not take it back.
        if processing || items[index].processing {
            items[index].processing = true
        } else {
            items[index].received = received
            items[index].expected = expected
        }
        refresh()
    }

    fileprivate func finish(_ id: UUID) {
        finished.insert(id)
        items.removeAll { $0.id == id }
        refresh()
    }

    /// The text now, and a tick while anything loads, so a load passing `delay` shows.
    private func refresh() {
        let next = Self.text(for: items)
        if next != text { text = next }
        // A finish can arrive before its start (both hop to the main actor); the ids stay
        // until there are many, so a late start is still turned away.
        if finished.count > 500 { finished.removeAll() }
        if items.isEmpty {
            tick?.invalidate()
            tick = nil
        } else if tick == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in LoadingActivity.shared.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            tick = timer
        }
    }
}

/// One load's reporter, safe from any thread. Byte counts reach the pill at most a few times
/// a second.
nonisolated final class LoadingReport: Sendable {
    let id: UUID
    let kind: LoadingItem.Kind
    let startedAt: Date

    private struct State {
        var lastSent = Date.distantPast
        var done = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    fileprivate init(id: UUID, kind: LoadingItem.Kind, startedAt: Date) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
    }

    func received(_ bytes: Int64, of expected: Int64?) {
        let send = state.withLock { state -> Bool in
            let now = Date()
            guard !state.done, now.timeIntervalSince(state.lastSent) >= 0.25 else { return false }
            state.lastSent = now
            return true
        }
        guard send else { return }
        let id = id
        Task { @MainActor in LoadingActivity.shared.update(id, received: bytes, expected: expected, processing: false) }
    }

    /// The download is in; what follows is reading it.
    func processing() {
        guard state.withLock({ !$0.done }) else { return }
        let id = id
        Task { @MainActor in LoadingActivity.shared.update(id, received: 0, expected: nil, processing: true) }
    }

    func finish() {
        let first = state.withLock { state -> Bool in
            defer { state.done = true }
            return !state.done
        }
        guard first else { return }
        let id = id
        Task { @MainActor in LoadingActivity.shared.finish(id) }
    }
}
