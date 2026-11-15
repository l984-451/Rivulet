// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ScrubPreviews.swift
//  Rivulet
//
//  Server-made scrub previews for a provider item (Jellyfin trickplay), tried before
//  an engine frame decode. All three apps share it.
//

import CoreGraphics
import Foundation

/// Stills a server cut ahead of time. Dropping the source releases its memory.
protocol ScrubPreviewSource: Sendable {
    func image(at seconds: Double) async -> CGImage?
}

/// The previews for the item now playing. Asks the provider once (lazily, on the first
/// scrub); a provider without any, a transcode, or a failed sheet answers nil and the
/// caller falls back to engine frames.
@MainActor
final class ScrubPreviewHolder {
    private var key: String?
    private var task: Task<(any ScrubPreviewSource)?, Never>?

    func image(at seconds: Double, for playback: ProviderPlayback?) async -> CGImage? {
        // A transcode has no sheets for its (burned-in, re-timed) stream.
        guard let playback, playback.stream.source.streamKind == .directPlay else { clear(); return nil }
        let ref = playback.item.ref
        let sourceID = playback.stream.source.id
        let newKey = "\(ref.providerID)|\(ref.itemID)|\(sourceID)"
        if newKey != key {
            clear()
            key = newKey
            let provider = playback.provider
            task = Task { await provider.scrubPreviews(for: ref, sourceID: sourceID) }
        }
        guard let source = await task?.value else { return nil }
        return await source.image(at: seconds)
    }

    func clear() {
        task?.cancel()
        task = nil
        key = nil
    }
}
