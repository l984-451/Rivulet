import Foundation

nonisolated struct SiloThemeMusicSetting: Codable, Equatable, Sendable {
    var enabled = false
    var loop = false
}

/// The opt-in belongs to one login and profile on this device. No Silo UI settings are read or written.
@MainActor
struct SiloThemeMusicPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(account: SiloSession.Account) -> String {
        "silo.themeAudio.\(account.credentialID.uuidString).\(account.providerID)"
    }
    func read(account: SiloSession.Account) -> SiloThemeMusicSetting {
        guard let data = defaults.data(forKey: key(account: account)),
              let saved = try? JSONDecoder().decode(SiloThemeMusicSetting.self, from: data) else {
            return SiloThemeMusicSetting()
        }
        return saved
    }
    func write(_ value: SiloThemeMusicSetting, account: SiloSession.Account) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key(account: account))
    }
}

nonisolated struct SiloThemeSong: Decodable, Sendable {
    let id: String
    let title: String?
}

nonisolated struct SiloThemeSongSet: Decodable, Sendable {
    let ownerId: String
    let items: [SiloThemeSong]
}

nonisolated struct SiloThemeMusicGrant: Sendable {
    let url: URL
    let converted: Bool
}

nonisolated struct SiloThemeMusicAPI: Sendable {
    let client: SiloClient

    private nonisolated struct Capability: Decodable, Sendable {
        let state: String
        let allowed: Bool?
        var available: Bool { state == "available" && allowed != false }
    }
    private nonisolated struct Detail: Decodable, Sendable { let themes: SiloThemeSongSet? }
    private nonisolated struct PlaybackBody: Encodable, Sendable {
        nonisolated struct Format: Encodable, Sendable { let container: String; let audioCodec: String }
        let acceptedFormats: [Format]
    }
    private nonisolated struct PlaybackResponse: Decodable, Sendable {
        let url: String
        let delivery: String?
    }

    func isOffered() async throws -> Bool {
        let capability: Capability = try await client.get("catalog/themes/capabilities")
        return capability.available
    }

    /// Item detail performs the server's season/episode inheritance and viewer authorization.
    func firstTheme(for ownerID: String) async throws -> (ownerID: String, themeID: String)? {
        guard !ownerID.isEmpty else { return nil }
        let detail: Detail = try await client.get("catalog/items/\(SiloClient.pathComponent(ownerID))")
        guard let themes = detail.themes, !themes.ownerId.isEmpty,
              let song = themes.items.first, !song.id.isEmpty else { return nil }
        return (themes.ownerId, song.id)
    }

    func grant(ownerID: String, themeID: String) async throws -> SiloThemeMusicGrant {
        guard !ownerID.isEmpty, !themeID.isEmpty else { throw SiloSignInError.invalidResponse }
        let body = PlaybackBody(acceptedFormats: [
            .init(container: "mp3", audioCodec: "mp3"),
            .init(container: "m4a", audioCodec: "aac"),
            .init(container: "mp4", audioCodec: "aac")
        ])
        let response: PlaybackResponse = try await client.post(
            "catalog/items/\(SiloClient.pathComponent(ownerID))/themes/\(SiloClient.pathComponent(themeID))/playback", body: body
        )
        guard let url = client.mediaURL(response.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { throw SiloSignInError.invalidResponse }
        guard response.delivery == nil || response.delivery == "original" || response.delivery == "converted" else {
            throw SiloSignInError.invalidResponse
        }
        return SiloThemeMusicGrant(url: url, converted: response.delivery == "converted")
    }
}
