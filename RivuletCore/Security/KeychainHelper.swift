// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  KeychainHelper.swift
//  Rivulet
//
//  Secure storage for sensitive credentials in the Keychain
//

import Foundation
import Security

enum KeychainHelper {

    private static let plexService = "com.rivulet.plex"

    // MARK: - Public API

    /// Retrieve a string value from the Keychain
    static func get(_ key: String, service: String = plexService) -> String? {
        if let data = copy(query(key, service)) { return String(data: data, encoding: .utf8) }
        // A Mac item saved before the move sits in the file keychain: move it once.
        guard let data = copy(query(key, service, fileKeychain: true)) else { return nil }
        if add(data, to: query(key, service)) == errSecSuccess {
            SecItemDelete(query(key, service, fileKeychain: true) as CFDictionary)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Store a string value in the Keychain
    @discardableResult
    static func set(_ value: String, forKey key: String, service: String = plexService) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(key, service: service)
        var status = add(data, to: query(key, service))
        // A build with no app identity can't use the data protection keychain.
        if status == errSecMissingEntitlement { status = add(data, to: query(key, service, fileKeychain: true)) }
        return status == errSecSuccess
    }

    /// Delete a value from the Keychain
    @discardableResult
    static func delete(_ key: String, service: String = plexService) -> Bool {
        let statuses = [false, true].map { SecItemDelete(query(key, service, fileKeychain: $0) as CFDictionary) }
        return statuses.allSatisfy { $0 == errSecSuccess || $0 == errSecItemNotFound || $0 == errSecMissingEntitlement }
    }

    // MARK: - Queries

    /// The data protection keychain, where an item belongs to the app. On the Mac the file keychain
    /// ties each item to the signature that saved it, so every differently signed build asks for each read.
    /// On iOS and tvOS both are the same keychain.
    private static func query(_ key: String?, _ service: String, fileKeychain: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let key { query[kSecAttrAccount as String] = key }
        if !fileKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    private static func copy(_ query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func add(_ data: Data, to query: [String: Any]) -> OSStatus {
        var query = query
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
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

    /// Deletes every stored PIN, including profiles no longer in the home-user list.
    static func deleteAllPins() { deleteAll(withPrefix: pinKeyPrefix) }

    /// Deletes every item whose key starts with `prefix`.
    static func deleteAll(withPrefix prefix: String) {
        var accounts = Set<String>()
        for fileKeychain in [false, true] {
            var search = query(nil, plexService, fileKeychain: fileKeychain)
            search[kSecMatchLimit as String] = kSecMatchLimitAll
            search[kSecReturnAttributes as String] = true
            var result: CFTypeRef?
            guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[String: Any]] else { continue }
            accounts.formUnion(items.compactMap { $0[kSecAttrAccount as String] as? String })
        }
        for account in accounts where account.hasPrefix(prefix) {
            delete(account)
        }
    }
}
