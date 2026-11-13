// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The error-report server only takes events whose DSN path carries a pass (`<expiry>.<hmac>`)
// minted by insights-api for an attested device. Kept in the Keychain; refreshed weekly.

import Foundation

enum IngestPass {
    private static let keychainKey = "errorReportIngestPass"
    /// Passes last 30 days; a launch with fewer than 23 left fetches the next one.
    static let refreshMargin: TimeInterval = 23 * 24 * 3600

    /// The stored pass while it has at least `margin` left.
    static func cached(now: Date = Date(), margin: TimeInterval = 0) -> String? {
        guard let pass = KeychainHelper.get(keychainKey), let expiry = expiry(of: pass),
              expiry > now.timeIntervalSince1970 + margin else { return nil }
        return pass
    }

    static func expiry(of pass: String) -> TimeInterval? {
        let parts = pass.split(separator: ".")
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return TimeInterval(parts[0])
    }

    /// `https://key@host/1` becomes `https://key@host/<pass>/1`; the SDK keeps the prefix.
    static func dsn(_ dsn: String, pass: String) -> String? {
        guard var components = URLComponents(string: dsn), !components.path.isEmpty else { return nil }
        components.path = "/\(pass)\(components.path)"
        return components.string
    }

    /// Asks the Worker for a new pass and stores it. Nil when the device can't attest or the call fails.
    static func fetch(baseURL: URL = InsightsConfig.apiBaseURL) async -> String? {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ingest-pass"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.attestedData(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let pass = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["pass"] as? String,
              expiry(of: pass) != nil
        else { return nil }
        _ = KeychainHelper.set(pass, forKey: keychainKey)
        return pass
    }
}
