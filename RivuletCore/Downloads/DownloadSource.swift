// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A server's original file for a version, as a plain ranged GET a background session can carry.
/// Neither server answers HEAD, so a size comes from the detail or from a one-byte range.
nonisolated struct DownloadSource: Sendable, Equatable {
    var url: URL
    var headers: [String: String]

    var request: URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }
}
