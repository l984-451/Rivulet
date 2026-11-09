// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Combine
import Foundation

/// The state behind a "Search for Subtitles" sheet on iOS and Mac: search once, show the list, install a pick.
@MainActor
final class SubtitleSearchModel: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case searching
        case results([SubtitleSearchResult])
        case failed
        case downloading
    }

    @Published private(set) var phase = Phase.searching
    private let search: () async throws -> [SubtitleSearchResult]
    private let install: (SubtitleSearchResult) async -> Bool
    private var task: Task<Void, Never>?

    /// `install` returns false when the subtitle never arrived.
    init(search: @escaping () async throws -> [SubtitleSearchResult],
         install: @escaping (SubtitleSearchResult) async -> Bool) {
        self.search = search
        self.install = install
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                phase = .results(try await search())
            } catch {
                if !Task.isCancelled { phase = .failed }
            }
        }
    }

    /// Runs the install; `done` is called when the sheet should close.
    func choose(_ result: SubtitleSearchResult, done: @escaping () -> Void) {
        guard case .results = phase else { return }
        phase = .downloading
        task = Task { [weak self] in
            guard let self else { return }
            if await install(result) { done() } else { phase = .failed }
        }
    }

    func cancel() { task?.cancel() }
}
