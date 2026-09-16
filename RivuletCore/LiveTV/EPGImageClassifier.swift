// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import CoreGraphics

public enum EPGImageKind: String, Sendable, Codable {
    case landscape  // aspect ratio >= 1.25 (e.g. 16:9, 4:3)
    case portrait   // aspect ratio < 1.25 (e.g. 2:3, 1:1, square)
}

/// Actor/thread-safe registry for classifying EPG programme image aspect ratios.
/// Allows views to quickly check if an image is landscape or portrait.
public final class EPGImageClassifier: @unchecked Sendable {
    public static let shared = EPGImageClassifier()

    private let lock = NSLock()
    private var classifications: [URL: EPGImageKind] = [:]

    private init() {}

    /// Instant in-memory check for whether an image's aspect ratio classification is known.
    public func kind(for url: URL?) -> EPGImageKind? {
        guard let url else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return classifications[url]
    }

    public func isLandscape(_ url: URL?) -> Bool {
        kind(for: url) == .landscape
    }

    public func isPortrait(_ url: URL?) -> Bool {
        kind(for: url) == .portrait
    }

    public func register(url: URL, kind: EPGImageKind) {
        lock.lock()
        classifications[url] = kind
        lock.unlock()
    }

    public func register(url: URL, width: Int, height: Int) {
        guard height > 0 else { return }
        let ratio = Double(width) / Double(height)
        register(url: url, kind: ratio >= 1.25 ? .landscape : .portrait)
    }

    public func register(url: URL, size: CGSize) {
        guard size.height > 0 else { return }
        let ratio = Double(size.width) / Double(size.height)
        register(url: url, kind: ratio >= 1.25 ? .landscape : .portrait)
    }

    /// Reset all classifications (useful for unit tests).
    public func reset() {
        lock.lock()
        classifications.removeAll()
        lock.unlock()
    }
}
