// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct SiloProfile: Decodable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let hasPin: Bool
    var hasPIN: Bool { hasPin }
}

nonisolated struct SiloProfileCollection: Decodable, Sendable {
    let items: [SiloProfile]
}

nonisolated struct SiloSystemInfo: Decodable, Sendable {
    struct Links: Decodable, Sendable {
        let openapi: String
        let capabilities: String
        let identity: String
    }
    let apiMajor: Int
    let serverVersion: String
    let links: Links
    let requestOrigin: String?
}

nonisolated struct SiloServerIdentity: Decodable, Sendable {
    let serverId: String
}

/// Native GET /api/v2/theme/branding; identity itself carries only server_id.
nonisolated struct SiloBranding: Decodable, Sendable {
    let serverName: String
}

nonisolated struct SiloLoginAccount: Decodable, Sendable {
    let id: String
    let username: String
    let passwordChangeRequired: Bool
}

nonisolated struct SiloTokenPair: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: SiloLoginAccount
}

nonisolated struct SiloRefreshedTokens: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

nonisolated struct SiloLoginBody: Encodable, Sendable {
    let username: String
    let password: String
}

nonisolated struct SiloRefreshBody: Encodable, Sendable {
    let refreshToken: String
}

nonisolated struct SiloPINBody: Encodable, Sendable {
    let pin: String
}

nonisolated struct SiloProfileVerification: Decodable, Sendable {
    let valid: Bool
    let profileToken: String?
    let expiresAt: String?
}

nonisolated struct SiloCapability: Decodable, Sendable {
    let revision: String
    let state: String
    let allowed: Bool?
}

/// Native Problem Details. The server guarantees these explanations never echo
/// rejected credential values. Keep the code for decisions, and detail for UI.
nonisolated struct SiloAPIError: Error, Decodable, Sendable, LocalizedError {
    struct Field: Decodable, Sendable {
        let location: String
        let code: String
        let detail: String
    }
    let type: String
    let title: String
    let status: Int
    let detail: String
    let errors: [Field]?
    var code: String { type.split(separator: "/").last.map(String.init) ?? type }
    var errorDescription: String? {
        let fields = errors?.map { "\($0.location): \($0.detail)" }.joined(separator: "\n") ?? ""
        let message = detail.isEmpty ? title : detail
        return fields.isEmpty ? message : message + "\n" + fields
    }
}

nonisolated enum SiloSignInError: Error, Sendable, LocalizedError {
    case invalidAddress
    case notSilo
    case unsupportedAPI(Int)
    case originMismatch
    case serverChanged
    case accountChanged
    case profileMissing
    case pinRequired
    case incorrectPIN
    case passwordChangeRequired
    case untrustedCertificate
    case keychain
    case invalidResponse
    case signedOut

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an http:// or https:// Silo web address without embedded credentials."
        case .notSilo: "That address did not return Silo's native API. Enter the web address, including any reverse-proxy path."
        case .unsupportedAPI(let major): "This server uses native API \(major). Rivulet requires API 2."
        case .originMismatch: "The server reports a different address than the one entered. Check the address and reverse-proxy configuration before signing in."
        case .serverChanged: "This address now identifies a different Silo server. Sign out and sign in to the intended server."
        case .accountChanged: "The restored session belongs to a different account. Sign out and sign in again."
        case .profileMissing: "That profile is no longer available on this account. Choose another profile."
        case .pinRequired: "Enter this profile's PIN to unlock it."
        case .incorrectPIN: "Silo did not accept that profile PIN."
        case .passwordChangeRequired: "This account must change its temporary password in the Silo web app before signing in here."
        case .untrustedCertificate: "This server's HTTPS certificate is not trusted. Use a trusted certificate or its local http:// address."
        case .keychain: "Rivulet could not securely save this session. Please try signing in again."
        case .invalidResponse: "Silo returned an incomplete or invalid response."
        case .signedOut: "This Silo session has ended. Sign in again."
        }
    }
}
