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
    /// Signs a request with App Attest, sends it, and retries once on 401. Only
    /// `unknown_key` discards the key and re-enrolls (a fresh deploy or reinstall);
    /// other rejections just re-sign, since re-enrolling costs a trip to Apple.
    func attestedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let signed = await AppAttestClient.shared.attest(request)
        let (data, response) = try await self.data(for: signed)

        guard let http = response as? HTTPURLResponse, http.statusCode == 401 else {
            return (data, response)
        }

        let reason = String(decoding: data.prefix(80), as: UTF8.self)
        await AppAttestClient.shared.reportRejection(
            reason: reason, path: request.url?.path ?? "?",
            signed: signed.value(forHTTPHeaderField: "X-Rivulet-Assertion") != nil)
        if reason.contains("unknown_key") {
            await AppAttestClient.shared.invalidateKey(
                ifCurrent: signed.value(forHTTPHeaderField: "X-Rivulet-Key-Id")
            )
        }
        let retried = await AppAttestClient.shared.attest(request)
        return try await self.data(for: retried)
    }
}
