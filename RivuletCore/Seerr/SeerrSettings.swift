// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Where Seerr is, and its API key.

import Foundation

/// The server address lives in UserDefaults; the API key in the Keychain. Neither is in
/// `SyncCatalog`, so neither goes to iCloud: the key is an admin credential.
enum SeerrSettings {
    static let serverKey = "seerrServerURL"
    static let apiKeyKey = "seerrAPIKey"

    static var serverAddress: String {
        get { UserDefaults.standard.string(forKey: serverKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: serverKey) }
            else { UserDefaults.standard.set(trimmed, forKey: serverKey) }
        }
    }

    static var apiKey: String {
        get { KeychainHelper.get(apiKeyKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { _ = KeychainHelper.delete(apiKeyKey) }
            else { _ = KeychainHelper.set(trimmed, forKey: apiKeyKey) }
        }
    }

    /// The API base, or nil until both an address and a key are set.
    static var baseURL: URL? {
        guard !apiKey.isEmpty else { return nil }
        return apiBase(from: serverAddress)
    }

    static var isConfigured: Bool { baseURL != nil }

    static func clear() {
        serverAddress = ""
        apiKey = ""
    }

    /// "seerr.lan:5055", "http://10.0.0.5:5055/", "https://seerr.example.com/api/v1" all become
    /// "<scheme>://host[:port][/path]/api/v1". No scheme means http, which is how Seerr runs on a LAN.
    static func apiBase(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api/v1") { text.removeLast("/api/v1".count) }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil else { return nil }
        return URL(string: text + "/api/v1")
    }

    /// The address as the row shows it: the host, without scheme or path.
    static var displayHost: String {
        guard let base = apiBase(from: serverAddress), let host = base.host else { return "" }
        return base.port.map { "\(host):\($0)" } ?? host
    }
}
