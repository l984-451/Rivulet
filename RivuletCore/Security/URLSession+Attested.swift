// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  URLSession+Attested.swift
//  Rivulet
//
//  One choke point for every request to our own Workers.
//
//  Call sites use `session.attestedData(for:)` instead of `session.data(for:)`.
//  Keeping this to a single helper means a new endpoint cannot silently ship
//  unauthenticated by forgetting to attach headers — the only way to call our
//  Workers is through here.
//
//  Never use this for third-party hosts (Plex, image CDNs): it would leak an
//  assertion to a server that has no business seeing one.
//

import Foundation

extension URLSession {
    /// Sign a request with App Attest, send it, and retry once on 401.
    ///
    /// The retry exists because a 401 is recoverable: the Worker may not know
    /// our key (fresh deploy, restored backup, reinstalled app). Re-enrolling
    /// once turns what would be a permanently dead client into a self-healing
    /// one. Any other status is returned untouched.
    ///
    /// Only `unknown_key` justifies discarding the key. Every other rejection is
    /// about the signature, not the enrollment, and re-enrolling for one costs a
    /// round trip to Apple that a fresh assertion would have avoided — with a
    /// burst of concurrent requests that compounds into seconds of stalled UI.
    func attestedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let signed = await AppAttestClient.shared.attest(request)
        let (data, response) = try await self.data(for: signed)

        guard let http = response as? HTTPURLResponse, http.statusCode == 401 else {
            return (data, response)
        }

        if String(data: data, encoding: .utf8)?.contains("unknown_key") == true {
            await AppAttestClient.shared.invalidateKey(
                ifCurrent: signed.value(forHTTPHeaderField: "X-Rivulet-Key-Id")
            )
        }
        let retried = await AppAttestClient.shared.attest(request)
        return try await self.data(for: retried)
    }
}
