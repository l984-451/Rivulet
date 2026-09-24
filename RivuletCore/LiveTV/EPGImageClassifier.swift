// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import CoreGraphics

enum EPGImageKind: Sendable {
    case landscape  // ratio >= EPGImageClassifier.landscapeThreshold (16:9, 4:3)
    case portrait   // below it (2:3, 1:1)
}

/// Remembers the measured shape of EPG programme artwork whose feed declared no
/// dimensions, so a view that has already downloaded an icon can route it
/// (poster slot vs backdrop) without measuring it again.
///
/// Views only: the XMLTV parser must not consult this. Parsing reads declared
/// `width`/`height` alone, so the same bytes always parse the same way.
nonisolated final class EPGImageClassifier: @unchecked Sendable {
    static let shared = EPGImageClassifier()

    /// The one width/height ratio at or above which artwork counts as landscape.
    static let landscapeThreshold = 1.25

    /// Bounds the cache for a long-running process. A guide session touches far
    /// fewer icons than this, and a dropped entry is simply measured again.
    private static let capacity = 512

    static func kind(width: Double, height: Double) -> EPGImageKind? {
        guard width > 0, height > 0 else { return nil }
        return width / height >= landscapeThreshold ? .landscape : .portrait
    }

    private let lock = NSLock()
    private var classifications: [URL: EPGImageKind] = [:]

    private init() {}

    func kind(for url: URL?) -> EPGImageKind? {
        guard let url else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return classifications[url]
    }

    func isLandscape(_ url: URL?) -> Bool {
        kind(for: url) == .landscape
    }

    /// The remembered kind, or the kind measured from `loadSize`, which should
    /// read through the platform's image cache so measuring costs no extra
    /// fetch. Nil when the image cannot be loaded.
    @MainActor
    func classify(_ url: URL, loadSize: () async -> CGSize?) async -> EPGImageKind? {
        if let known = kind(for: url) { return known }
        guard let size = await loadSize(),
              let measured = Self.kind(width: size.width, height: size.height) else { return nil }
        lock.lock()
        if classifications.count >= Self.capacity { classifications.removeAll() }
        classifications[url] = measured
        lock.unlock()
        return measured
    }
}
