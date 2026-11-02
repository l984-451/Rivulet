// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Owns one decorative playback request, including late results after leaving
/// a page. Keeping this separate from the player makes cancellation testable.
@MainActor
final class ThemeVideoSession {
    typealias Resolver = @MainActor @Sendable (MediaItemRef) async throws -> ThemeVideo?

    private let resolve: Resolver
    private var requestedItem: MediaItemRef?
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private(set) var video: ThemeVideo?
    var onChange: ((ThemeVideo?) -> Void)?

    init(resolve: @escaping Resolver) { self.resolve = resolve }

    deinit {
        loadTask?.cancel()
        if let video { Task { await video.stop() } }
    }

    /// Nil means the backdrop is no longer eligible (hidden, disabled, or
    /// covered). Repeated updates for the same item never repeat a lookup.
    func update(for item: MediaItemRef?) {
        guard requestedItem != item else { return }
        requestedItem = item
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        releaseVideo()
        guard let item else { return }
        let generation = generation
        let resolve = resolve
        loadTask = Task { [weak self] in
            do {
                let video = try await resolve(item)
                guard !Task.isCancelled, let self, self.generation == generation else {
                    if let video { await video.stop() }
                    return
                }
                self.video = video
                self.onChange?(video)
            } catch {
                // Theme media is optional. Keep the still artwork, without
                // retrying every visibility check or interrupting browsing.
            }
        }
    }

    /// A failed clip stays on artwork for this visit instead of retrying in a loop.
    func playbackFailed() { releaseVideo() }

    private func releaseVideo() {
        let previous = video
        video = nil
        onChange?(nil)
        if let previous { Task { await previous.stop() } }
    }
}
