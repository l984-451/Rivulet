// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct SiloDeviceCapability: Decodable, Sendable {
    let state: String
    let cancel: Bool?
    var available: Bool { state == "available" }
}

nonisolated struct SiloDeviceStart: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let expiresAt: String
    let expiresIn: Int
    let interval: Int
}

nonisolated struct SiloDevicePoll: Decodable, Sendable {
    let status: String
    let pollAfter: Int
    let expiresAt: String?
    let tokens: SiloTokenPair?
    let temporary: Bool?
}

nonisolated struct SiloDeviceStartBody: Encodable, Sendable {
    let deviceName: String
    let devicePlatform: String
    let clientPurpose = "device_login"
    let temporary = false
}

nonisolated struct SiloDeviceCodeBody: Encodable, Sendable {
    let deviceCode: String
}

enum SiloDeviceSignInError: Error, LocalizedError {
    case unsupported, denied, expired, consumed, invalidCode

    var errorDescription: String? {
        switch self {
        case .unsupported: "This Silo server does not offer sign in by phone. Use your password instead."
        case .denied: "The sign in request was denied."
        case .expired: "The sign in code expired. Request a new code."
        case .consumed: "This sign in code has already been used. Request a new code."
        case .invalidCode: "Silo returned an invalid sign in code."
        }
    }
}
