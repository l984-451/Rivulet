// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import BackgroundTasks
import Combine
import UIKit

/// The system's Live Activity for downloads: one continued-processing task per batch.
/// It also keeps the app running in the background, so progress keeps arriving.
@MainActor
final class IOSDownloadActivity {
    static let shared = IOSDownloadActivity()
    private static let identifierPrefix = "com.gstudios.rivulet.downloads.activity"

    private let center = IOSDownloadCenter.shared
    private var task: BGContinuedProcessingTask?
    private var submitted = false
    /// Records shown in the running activity, kept until it ends so the bar never jumps back.
    private var batch: [String] = []
    private var shownTitle: (String, String)?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        guard cancellables.isEmpty else { return }
        center.$records
            .sink { [weak self] records in self?.update(records) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self.map { $0.update($0.center.records) } }
            .store(in: &cancellables)
    }

    private func update(_ records: [DownloadRecord]) {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let running = records.filter { !$0.state.isSettled && $0.state != .waitingForNetwork }
        batch = batch.filter { byID[$0] != nil }
        batch += running.map(\.id).filter { !batch.contains($0) }

        guard let task else {
            // A request can only be made from the foreground.
            if !submitted, !running.isEmpty, UIApplication.shared.applicationState == .active { submit(running) }
            return
        }
        let items = batch.compactMap { byID[$0] }
        guard items.contains(where: { !$0.state.isSettled }) else {
            return finish(task, success: !items.contains { if case .failed = $0.state { true } else { false } })
        }
        task.progress.totalUnitCount = Int64(items.count) * 1000
        task.progress.completedUnitCount = items.reduce(0) { $0 + Int64($1.overallFraction * 1000) }
        let title = Self.title(items)
        if shownTitle.map({ $0 != title }) ?? true {
            shownTitle = title
            task.updateTitle(title.0, subtitle: title.1)
        }
    }

    private func submit(_ running: [DownloadRecord]) {
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { IOSDownloadActivity.shared.began(task) }
        }
        guard registered else { return }
        let (title, subtitle) = Self.title(running)
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // Run now or not at all; a queued request could start long after the batch.
        request.strategy = .fail
        // Refused under load or with background launches denied; downloads run without it.
        submitted = (try? BGTaskScheduler.shared.submit(request)) != nil
    }

    private func began(_ newTask: BGTask) {
        guard let newTask = newTask as? BGContinuedProcessingTask else { return newTask.setTaskCompleted(success: false) }
        // Ending the activity leaves the transfers to the background session.
        newTask.expirationHandler = { [weak newTask] in
            Task { @MainActor in
                guard let newTask else { return }
                IOSDownloadActivity.shared.finish(newTask, success: false)
            }
        }
        task = newTask
        update(center.records)
    }

    private func finish(_ ended: BGContinuedProcessingTask, success: Bool) {
        guard ended === task else { return }
        ended.setTaskCompleted(success: success)
        task = nil
        submitted = false
        batch = []
        shownTitle = nil
    }

    private static func title(_ items: [DownloadRecord]) -> (String, String) {
        let open = items.filter { !$0.state.isSettled }
        let current = open.first { $0.state == .downloading } ?? open.first ?? items.first
        let name = current.map { record in
            let item = record.item
            guard item.kind == .episode else { return item.displayTitle }
            return [item.seriesTitle, item.episodeNumber.map { String(localized: "E\($0)") }, item.displayTitle].compactMap { $0 }.joined(separator: " · ")
        } ?? ""
        guard items.count > 1 else { return (String(localized: "Downloading"), name) }
        let done = items.count - open.count
        return (String(localized: "Downloading \(min(done + 1, items.count)) of \(items.count)"), name)
    }
}

extension DownloadRecord {
    /// 0 to 1 across the whole download: a conversion's server half, then the transfer.
    var overallFraction: Double {
        let converted = quality != StreamingQuality.original.rawValue
        switch state {
        case .completed, .failed: return 1
        case .preparing: return (progress ?? 0) * 0.5
        case .downloading, .pausedByUser: return (converted ? 0.5 : 0) + (progress ?? 0) * (converted ? 0.5 : 1)
        default: return 0
        }
    }
}
