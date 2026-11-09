// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CryptoKit
import Foundation

/// The slice of `NSUbiquitousKeyValueStore` the mirror uses, so tests can use a dictionary.
protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    /// nil removes the key.
    func set(_ value: Any?, forKey key: String)
    func allKeys() -> [String]
    func synchronize()
}

/// The real store.
final class UbiquitousKeyValueStore: KeyValueStore {
    private let store = NSUbiquitousKeyValueStore.default

    func object(forKey key: String) -> Any? { store.object(forKey: key) }
    func set(_ value: Any?, forKey key: String) {
        if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
    }
    func allKeys() -> [String] { Array(store.dictionaryRepresentation.keys) }
    func synchronize() { store.synchronize() }
}

/// Keeps the allowlisted `UserDefaults` keys equal to their KVS twins. `UserDefaults` stays the
/// source of truth for every reader. Per key it remembers the value both sides last agreed on,
/// which says who changed since: one side wins alone, both changed means the cloud wins.
/// A key nobody has agreed on yet (the first pass on a device) never lets an empty value beat a filled one.
@MainActor
final class PreferenceMirror {
    private let defaults: UserDefaults
    /// Explicit values only: `register(defaults:)` values are not a choice anyone made, so they never sync.
    private let domain: String
    private let store: KeyValueStore
    /// Largest value written. The store holds 1 MB in all, so one value gets a small share.
    private let maxValueBytes: Int
    nonisolated static let defaultMaxValueBytes = 64_000

    init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "",
         store: KeyValueStore, maxValueBytes: Int = PreferenceMirror.defaultMaxValueBytes) {
        self.defaults = defaults
        self.domain = domain
        self.store = store
        self.maxValueBytes = maxValueBytes
    }

    /// One pass over every synced key. Returns the keys the cloud changed here, for readers that cache.
    @discardableResult
    func reconcile() -> Set<String> {
        let saved = defaults.dictionary(forKey: SyncCatalog.stateKey) as? [String: String] ?? [:]
        let savedHeld = defaults.dictionary(forKey: SyncCatalog.heldKey) as? [String: String] ?? [:]
        var agreed = saved
        var held = savedHeld
        var applied: Set<String> = []
        let persisted = defaults.persistentDomain(forName: domain) ?? [:]
        let keys = Set(persisted.keys).union(store.allKeys()).union(agreed.keys).union(held.keys).filter(SyncCatalog.isSynced)

        for key in keys {
            let localRaw = persisted[key]
            let local = localRaw.map { SyncCatalog.outgoing(key, $0) }
            let cloud = store.object(forKey: key)
            let localPrint = Self.fingerprint(local)
            let cloudPrint = Self.fingerprint(cloud)
            // Kept out of a new Apple account until it changes on this device.
            var isHeld = false
            if let heldPrint = held[key] {
                if heldPrint == localPrint { isHeld = true } else { held[key] = nil }
            }
            if localPrint == cloudPrint {
                agreed[key] = localPrint
                held[key] = nil
                continue
            }
            let base = agreed[key]
            var pull: Bool
            switch (localPrint, cloudPrint) {
            case (nil, _): pull = base == nil || base != cloudPrint
            case (_, nil): pull = base == localPrint
            default: pull = base != cloudPrint || base == localPrint
            }
            if pull, base == nil, let local, let cloud, Self.isEmpty(cloud), !Self.isEmpty(local) { pull = false }

            if pull {
                if let value = SyncCatalog.incoming(key, cloud: cloud, local: localRaw) {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                agreed[key] = cloudPrint
                held[key] = nil
                applied.insert(key)
            } else if !isHeld {
                if let local {
                    if push(local, forKey: key) { agreed[key] = localPrint }
                } else {
                    store.set(nil, forKey: key)
                    agreed[key] = nil
                }
            }
        }
        // Written only on change: the write itself posts didChangeNotification.
        if agreed != saved { defaults.set(agreed, forKey: SyncCatalog.stateKey) }
        if held != savedHeld { defaults.set(held, forKey: SyncCatalog.heldKey) }
        store.synchronize()
        if !applied.isEmpty { DiagLog.notice(.sync, "Preferences from iCloud: \(applied.count) keys") }
        return applied
    }

    /// The Apple account changed: forget what was agreed, and keep every value this device has out of the
    /// new account until it is changed here. The new account's values still come in.
    func holdLocalValues() {
        resetState()
        let persisted = defaults.persistentDomain(forName: domain) ?? [:]
        var held: [String: String] = [:]
        for (key, value) in persisted where SyncCatalog.isSynced(key) {
            held[key] = Self.fingerprint(SyncCatalog.outgoing(key, value))
        }
        defaults.set(held, forKey: SyncCatalog.heldKey)
    }

    /// Forget what was agreed, so the next pass adopts afresh.
    func resetState() {
        defaults.removeObject(forKey: SyncCatalog.stateKey)
    }

    private func push(_ value: Any, forKey key: String) -> Bool {
        guard SyncCatalog.fitsKVS(key: key) else {
            DiagLog.error(.sync, "Key too long for iCloud, left on this device: \(key.prefix(40))")
            return false
        }
        let size = (try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0).count) ?? .max
        guard size <= maxValueBytes else {
            DiagLog.error(.sync, "Value too large for iCloud, left on this device: \(key.prefix(40)) (\(size) bytes)")
            return false
        }
        store.set(value, forKey: key)
        return true
    }

    /// An empty string, list or table, or JSON data holding one. Numbers and flags are never empty.
    private static func isEmpty(_ value: Any) -> Bool {
        switch value {
        case let string as String: return string.isEmpty
        case let array as [Any]: return array.isEmpty
        case let dict as [String: Any]: return dict.isEmpty
        case let data as Data:
            guard !data.isEmpty else { return true }
            let text = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
            return text == "{}" || text == "[]"
        default: return false
        }
    }

    /// A short hash of a property-list value that ignores dictionary order. nil for nil.
    nonisolated static func fingerprint(_ value: Any?) -> String? {
        guard let value else { return nil }
        let digest = SHA256.hash(data: Data(canonical(value).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func canonical(_ value: Any) -> String {
        switch value {
        case let dict as [String: Any]:
            return "{" + dict.keys.sorted().map { "\($0.count):\($0)=" + canonical(dict[$0]!) }.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(canonical).joined(separator: ",") + "]"
        case let data as Data:
            return "d:" + data.base64EncodedString()
        case let date as Date:
            return "t:\(date.timeIntervalSince1970)"
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "b:\(number.boolValue)" : "n:\(number.stringValue)"
        case let string as String:
            return "s:\(string.count):\(string)"
        default:
            return "?:\(value)"
        }
    }
}
