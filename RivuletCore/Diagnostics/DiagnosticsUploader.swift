// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Sends a diagnostics report (JSON) to our own Worker, attested like every other call to it.
// The server mints the short code, so a code exists only for a report that was stored.
// A failed send is kept on disk and tried once more with the next report.

import Compression
import Foundation

nonisolated enum DiagnosticsUploader {
    enum Failure: Error { case tooLarge, rejected(Int), network }

    private static let maxBytes = 2 * 1024 * 1024
    private static var pendingURL: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Diagnostics/pending-report.json.gz")
    }

    /// Uploads `json` and returns the server's code. On failure the report is kept for the next send.
    static func send(json: Data, baseURL: URL = InsightsConfig.apiBaseURL) async -> Result<String, Failure> {
        await retryPending(baseURL: baseURL)
        guard let body = gzip(json) else { return .failure(.tooLarge) }
        let result = await post(body, baseURL: baseURL)
        if case .failure = result {
            try? FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? body.write(to: pendingURL, options: .atomic)
        }
        return result
    }

    /// One try for a report that failed earlier; it is dropped either way so it cannot pile up.
    private static func retryPending(baseURL: URL) async {
        guard let body = try? Data(contentsOf: pendingURL) else { return }
        try? FileManager.default.removeItem(at: pendingURL)
        if case .success(let code) = await post(body, baseURL: baseURL) {
            DiagLog.notice(.attest, "Earlier diagnostics report sent as \(code)")
        }
    }

    private static func post(_ body: Data, baseURL: URL) async -> Result<String, Failure> {
        guard body.count <= maxBytes else { return .failure(.tooLarge) }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/diagnostics"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        guard let (data, response) = try? await URLSession(configuration: config).attestedData(for: request),
              let http = response as? HTTPURLResponse else { return .failure(.network) }
        guard http.statusCode == 201,
              let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
        else { return .failure(.rejected(http.statusCode)) }
        return .success(code)
    }

    // MARK: - gzip

    /// RFC 1952 member around Compression's raw deflate. Nil when compression fails.
    static func gzip(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(deflated)
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crcTable[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) }
    }
}
