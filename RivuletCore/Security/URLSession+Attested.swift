// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  URLSession+Attested.swift
//  Rivulet
//
//  The one way to call our own Workers: `session.attestedData(for:)` signs every
//  request. Never use it for third-party hosts (Plex, image CDNs).
//

import Foundation

extension URLSession {
    /// Signs a request with App Attest, sends it, and retries once on a 401 the
    /// Worker might accept the second time. Only `unknown_key` discards the key and
    /// re-enrolls (a fresh deploy or reinstall); `replay` and `stale_timestamp` just
    /// re-sign, since re-enrolling costs a trip to Apple.
    ///
    /// On real hardware an unsigned request fails here instead of going out: both
    /// Workers enforce attestation, so it could only come back 401.
    func attestedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let client = AppAttestClient.shared
        let signed = await client.attest(request)
        if client.isSupported && !AppAttestClient.isSigned(signed) {
            throw URLError(.userAuthenticationRequired)
        }
        let (data, response) = try await self.data(for: signed)

        guard let http = response as? HTTPURLResponse, http.statusCode == 401 else {
            return (data, response)
        }

        let reason = String(decoding: data.prefix(80), as: UTF8.self)
        await client.reportRejection(
            reason: reason, path: request.url?.path ?? "?",
            signed: AppAttestClient.isSigned(signed))
        if reason.contains("unknown_key") {
            await client.invalidateKey(
                ifCurrent: signed.value(forHTTPHeaderField: "X-Rivulet-Key-Id")
            )
        }
        // Anything else (bad_signature, attestation_required) fails the same way again.
        let retryable = ["unknown_key", "replay", "stale_timestamp"].contains { reason.contains($0) }
        guard retryable else { return (data, response) }
        let retried = await client.attest(request)
        guard AppAttestClient.isSigned(retried) else { return (data, response) }
        return try await self.data(for: retried)
    }
}
