// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  KeychainHelper.swift
//  Rivulet
//
//  Secure storage for sensitive credentials using iOS Keychain
//

import Foundation
import Security

enum KeychainHelper {

    private static let service = "com.rivulet.plex"

    // MARK: - Public API

    /// Retrieve a string value from the Keychain
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// Store a string value in the Keychain
    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Delete a value from the Keychain
    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - PIN Storage for Plex Home Users

    private static let pinKeyPrefix = "plexPin_"

    /// Store a PIN for a Plex Home user
    @discardableResult
    static func setPin(_ pin: String, forUserUUID uuid: String) -> Bool {
        set(pin, forKey: pinKeyPrefix + uuid)
    }

    /// Retrieve a stored PIN for a Plex Home user
    static func getPin(forUserUUID uuid: String) -> String? {
        get(pinKeyPrefix + uuid)
    }

    /// Delete a stored PIN for a Plex Home user
    @discardableResult
    static func deletePin(forUserUUID uuid: String) -> Bool {
        delete(pinKeyPrefix + uuid)
    }

    /// Check if a PIN is stored for a Plex Home user
    static func hasSavedPin(forUserUUID uuid: String) -> Bool {
        getPin(forUserUUID: uuid) != nil
    }

    /// Delete all stored PINs (for sign out)
    static func deleteAllPins(forUserUUIDs uuids: [String]) {
        for uuid in uuids {
            deletePin(forUserUUID: uuid)
        }
    }
}
