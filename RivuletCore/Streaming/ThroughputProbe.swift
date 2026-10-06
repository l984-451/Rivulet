// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Measures the link to a server by timing a ranged read of the file Auto would play.
nonisolated enum ThroughputProbe {
    static let byteLimit = 4 << 20
    static let timeLimit: TimeInterval = 2

    /// Rate from bytes received after the first byte; nil when too little arrived to judge.
    static func kbps(bytes: Int, seconds: TimeInterval) -> Int? {
        guard bytes >= 64 * 1024, seconds > 0.05 else { return nil }
        return Int(Double(bytes) * 8 / seconds / 1000)
    }

    /// Off the caller's actor: the byte loop runs for up to two seconds.
    @concurrent static func measure(url: URL, headers: [String: String] = [:], session: URLSession = .shared) async -> Int? {
        var request = URLRequest(url: url, timeoutInterval: 5)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(byteLimit - 1)", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await session.bytes(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            return nil
        }
        let start = Date()
        let task = bytes.task
        let deadline = Task { try? await Task.sleep(for: .seconds(timeLimit)); task.cancel() }
        defer { deadline.cancel(); task.cancel() }
        var count = 0
        do {
            for try await _ in bytes {
                count += 1
                if count >= byteLimit { break }
            }
        } catch {}
        let seconds = Date().timeIntervalSince(start)
        // A link too slow to reach the floor by the deadline is still a measurement.
        if seconds >= timeLimit, count > 0 { return Int(Double(count) * 8 / seconds / 1000) }
        return kbps(bytes: count, seconds: seconds)
    }
}
