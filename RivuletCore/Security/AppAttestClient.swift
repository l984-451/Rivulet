// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AppAttestClient.swift
//  Rivulet
//
//  Proves to our Cloudflare Workers that a request came from the genuine
//  Rivulet app on genuine Apple hardware.
//
//  Why this exists: anything the app can *send* (a bundle id, a baked-in API
//  key, an HMAC secret) ships inside the binary and is extractable, so a fork
//  could copy it. App Attest is the only mechanism on tvOS where the credential
//  is unforgeable: the private key is generated inside the Secure Enclave and
//  never leaves it, and Apple itself signs a certificate binding that key to
//  OUR bundle id and team id. A fork has a different bundle/team, so Apple will
//  not vouch for it, and no amount of source copying changes that.
//
//  Two phases:
//    - attest  (once per device, ever) — mint a Secure Enclave key, get Apple
//      to certify it, register the public key with the Worker.
//    - assert  (every request)         — sign the request with that key.
//
//  Failure is ALWAYS soft. If attestation can't complete (no network, Apple's
//  service is down, or we're in the Simulator where there is no Secure Enclave)
//  we still send the request, just unsigned. The Worker decides what to do with
//  that. An attestation bug must cost us a locked endpoint, never a bricked app.
//

import Foundation
import DeviceCheck
import CryptoKit
import os

private let log = Logger(subsystem: "com.rivulet.app", category: "AppAttest")

actor AppAttestClient {
    static let shared = AppAttestClient()

    private let service = DCAppAttestService.shared
    private let baseURL: URL
    private let session: URLSession

    /// The attested key id, once we have one. Persisted in the Keychain so a
    /// device attests once for its lifetime, not once per launch.
    private var keyId: String?

    /// Serializes enrollment so a burst of concurrent requests at launch
    /// triggers exactly one attestation, not N.
    private var enrollment: Task<String?, Never>?

    /// After a hard failure, stop hammering Apple / the Worker for a while.
    private var backoffUntil: Date?
    private static let backoff: TimeInterval = 60

    init(baseURL: URL = InsightsConfig.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.keyId = Keychain.load(Self.keychainAccount)
    }

    private static let keychainAccount = "app-attest-key-id"

    /// True on real hardware, false in the Simulator (no Secure Enclave).
    nonisolated var isSupported: Bool { DCAppAttestService.shared.isSupported }

    // MARK: - Signing

    /// Attach attestation headers to a request, enrolling this device first if
    /// needed. Returns the request unchanged if attestation is unavailable —
    /// the caller always gets a usable request.
    func attest(_ request: URLRequest) async -> URLRequest {
        #if DEBUG
        // The Simulator has no Secure Enclave, so App Attest cannot work there.
        // A dev key (never present in a release build) keeps the sim usable.
        if !isSupported, let devKey = Self.devKey {
            var r = request
            r.setValue(devKey, forHTTPHeaderField: "X-Rivulet-Dev-Key")
            return r
        }
        #endif

        guard isSupported else { return request }
        guard let keyId = await currentKeyId() else { return request }

        // The client data we sign must be byte-for-byte what the Worker
        // reconstructs. POST: the exact body. GET: path+query+timestamp.
        var r = request
        let clientData: Data
        if let body = request.httpBody, !body.isEmpty {
            clientData = body
        } else {
            let ts = String(Int(Date().timeIntervalSince1970 * 1000))
            r.setValue(ts, forHTTPHeaderField: "X-Rivulet-Timestamp")
            guard let url = request.url,
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return request
            }
            let query = comps.query.map { "?\($0)" } ?? ""
            clientData = Data("\(comps.path)\(query)\n\(ts)".utf8)
        }

        do {
            let digest = Data(SHA256.hash(data: clientData))
            let assertion = try await service.generateAssertion(keyId, clientDataHash: digest)
            r.setValue(keyId, forHTTPHeaderField: "X-Rivulet-Key-Id")
            r.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Rivulet-Assertion")
            return r
        } catch {
            // A key the Secure Enclave no longer recognises (restored backup,
            // reinstall) is dead. Drop it so the next call re-enrolls.
            log.error("assertion failed: \(error.localizedDescription, privacy: .public)")
            invalidateKey()
            return request
        }
    }

    /// The Worker told us it doesn't know this key. Discard it and re-enroll on
    /// the next request.
    ///
    /// `ifCurrent` is the key the failed request actually signed with. When a
    /// burst of requests fails together, every one of them would otherwise
    /// discard whatever key an earlier failure had already re-enrolled, and each
    /// re-enrollment costs a round trip to Apple's attestation service. Naming
    /// the key makes all but the first discard a no-op.
    func invalidateKey(ifCurrent used: String? = nil) {
        if let used, used != keyId { return }
        keyId = nil
        Keychain.delete(Self.keychainAccount)
    }

    // MARK: - Enrollment

    private func currentKeyId() async -> String? {
        if let keyId { return keyId }

        if let until = backoffUntil, Date() < until { return nil }

        // Coalesce: many requests can land at launch; only one should enroll.
        if let inFlight = enrollment { return await inFlight.value }

        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.enroll()
        }
        enrollment = task
        let result = await task.value
        enrollment = nil
        return result
    }

    private func enroll() async -> String? {
        do {
            let newKeyId = try await service.generateKey()

            // The challenge must come from the server and be single-use;
            // otherwise a captured attestation could be replayed.
            let challenge = try await fetchChallenge()
            let digest = Data(SHA256.hash(data: Data(challenge.utf8)))
            let attestation = try await service.attestKey(newKeyId, clientDataHash: digest)

            try await postAttestation(keyId: newKeyId, attestation: attestation, challenge: challenge)

            // Only persist AFTER the Worker accepts it — a key it never
            // registered is worse than no key (every request would 401).
            Keychain.save(Self.keychainAccount, value: newKeyId)
            keyId = newKeyId
            log.info("device attested")
            return newKeyId
        } catch {
            log.error("attestation failed: \(error.localizedDescription, privacy: .public)")
            backoffUntil = Date().addingTimeInterval(Self.backoff)
            return nil
        }
    }

    private struct ChallengeResponse: Decodable { let challenge: String }

    private func fetchChallenge() async throws -> String {
        let url = baseURL.appendingPathComponent("attest/challenge")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AttestClientError.challengeFailed
        }
        return try JSONDecoder().decode(ChallengeResponse.self, from: data).challenge
    }

    private struct VerifyBody: Encodable {
        let keyId: String
        let attestationObject: String
        let challenge: String
    }

    private func postAttestation(keyId: String, attestation: Data, challenge: String) async throws {
        let url = baseURL.appendingPathComponent("attest/verify")
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(VerifyBody(
            keyId: keyId,
            attestationObject: attestation.base64EncodedString(),
            challenge: challenge,
        ))
        let (_, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AttestClientError.verifyRejected
        }
    }

    /// Dev-only bypass for the Simulator. Read from the build environment so
    /// the value is never committed, and the whole path is `#if DEBUG` so it
    /// cannot exist in a release binary.
    #if DEBUG
    private static var devKey: String? {
        ProcessInfo.processInfo.environment["RIVULET_DEV_KEY"]
    }
    #endif
}

enum AttestClientError: Error {
    case challengeFailed
    case verifyRejected
}

// MARK: - Keychain

/// The key id is not secret (it's a public identifier), but it must SURVIVE
/// app updates and be device-local. UserDefaults would be wiped on reinstall,
/// forcing a needless re-attest; the Keychain persists.
private enum Keychain {
    private static let service = "com.gstudios.rivulet.attest"

    static func save(_ account: String, value: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
