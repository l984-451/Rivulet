// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTunerBusy.swift
//  Rivulet
//
//  Tells a live source that is out of connections apart from one that is
//  broken, so the player can say so instead of walking its fallbacks into
//  the same refusal.
//

import Foundation

nonisolated enum LiveTunerBusy {

    /// Dispatcharr, once every provider connection is taken, holds a stream
    /// request about 3 s and then answers 503 with a JSON body:
    /// `{"error": "All active M3U profiles have reached maximum connection limits", ...}`.
    static func isBusyResponse(status: Int, body: Data) -> Bool {
        guard status == 503,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = object["error"] as? String else { return false }
        return message.localizedCaseInsensitiveContains("maximum connection limits")
    }

    /// Asks the source once, after a live load has already failed, whether it
    /// refused for lack of a free connection. AetherEngine rides out a 503 as
    /// rate limiting and then reports only that the live source never opened,
    /// so the status has to come from here.
    ///
    /// Reads the status and at most 4 KB, then cancels. A source that has a
    /// connection free by now starts streaming, and holding that open would
    /// take the slot the next attempt needs.
    static func sourceIsBusy(_ url: URL, headers: [String: String]) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return false }
        defer { bytes.task.cancel() }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 503 else { return false }
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 4096 { break }
            }
        } catch {
            // A truncated body still classifies on what arrived.
        }
        return isBusyResponse(status: status, body: body)
    }
}
