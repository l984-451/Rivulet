import Foundation

nonisolated enum SiloPlaybackPreferencesError: Error { case staleAuthority, invalidResponse }

/// Read-only server resolution; consumers apply local overrides after reading this result.
actor SiloPlaybackPreferences {
    private let client: SiloClient
    private let profileID: String
    private let ownerIsCurrent: @Sendable () async -> Bool

    init(provider: SiloProvider, ownerIsCurrent: (@Sendable () async -> Bool)? = nil) {
        client = provider.client
        profileID = provider.profileID
        self.ownerIsCurrent = ownerIsCurrent ?? {
            let current = await MainActor.run { SiloSession.storedProvider() }
            return current?.id == provider.id && current?.authorityRevision == provider.authorityRevision
        }
    }

    private func checkOwner() async throws {
        guard await ownerIsCurrent() else { throw SiloPlaybackPreferencesError.staleAuthority }
    }

    func capabilities() async throws -> SiloSettingsCapabilities {
        try await checkOwner()
        do {
            let result: SiloSettingsCapabilities = try await client.get("settings/contract/capabilities")
            try await checkOwner()
            return result
        } catch let error as SiloAPIError where [404, 405, 501].contains(error.status) {
            try await checkOwner()
            return SiloSettingsCapabilities(state: "unsupported", allowed: false,
                                            manifestRevision: 0, supportsBatchedEffective: false)
        }
    }

    /// Read the public manifest, exposing only this service's playback definitions.
    func schema() async throws -> SiloPlaybackSettingsSchema? {
        let capability = try await capabilities()
        guard capability.available else { return nil }
        let contract: SiloSettingsContractWire = try await client.get("settings/contract")
        try await checkOwner()
        guard contract.revision == capability.manifestRevision else { return nil }
        var definitions: [SiloPlaybackSettingKey: SiloPlaybackSettingDefinition] = [:]
        for definition in contract.definitions {
            guard let key = SiloPlaybackSettingKey(rawValue: definition.key) else { continue }
            definitions[key] = definition
        }
        return SiloPlaybackSettingsSchema(revision: contract.revision, definitions: definitions,
                                          subtitleLanguages: contract.subtitleLanguages)
    }

    /// Optional library and series context lets Silo resolve their precedence itself.
    func effective(libraryID: Int? = nil, seriesID: String? = nil) async throws -> SiloEffectivePlaybackPreferences {
        let capability = try await capabilities()
        guard capability.available else { return Self.unavailable }
        let keys = SiloPlaybackSettingKey.allCases.filter { capability.manifestRevision >= $0.minimumRevision }
        let query = keys.map { URLQueryItem(name: "keys", value: $0.rawValue) }
            + (libraryID.map { [URLQueryItem(name: "library_ids", value: String($0))] } ?? [])
            + (seriesID.map { [URLQueryItem(name: "series_ids", value: $0)] } ?? [])
        try await checkOwner()
        let response: SiloEffectiveSettingsWire
        do { response = try await client.get("settings/values/effective", query) }
        catch {
            try await checkOwner()
            throw error
        }
        try await checkOwner()
        guard response.revision >= 1 else { return Self.unavailable }
        var rows: [String: SiloEffectiveSettingWire] = [:]
        for row in response.items {
            guard row.profileId == nil || row.profileId == profileID,
                  rows.updateValue(row, forKey: row.key) == nil else { throw SiloPlaybackPreferencesError.invalidResponse }
        }
        func setting<T: Equatable & Sendable>(_ key: SiloPlaybackSettingKey,
                                                _ convert: (SiloSettingJSON) -> T?) -> SiloSettingAvailability<T> {
            guard capability.manifestRevision >= key.minimumRevision,
                  response.revision >= key.minimumRevision,
                  let row = rows[key.rawValue] else { return .unavailable }
            return .resolved(row.typed(convert))
        }
        return SiloEffectivePlaybackPreferences(
            preferredQuality: setting(.preferredQuality) { if case .string(let v) = $0 { return v }; return nil },
            maxBitrateKbps: setting(.maxBitrateKbps) { if case .integer(let v) = $0, v > 0 { return v }; return nil },
            subtitleLanguage: setting(.subtitleLanguage) { if case .string(let v) = $0 { return v }; return nil },
            subtitleMode: setting(.subtitleMode) { if case .string(let v) = $0 { return SiloSubtitleMode(rawValue: v) }; return nil },
            showForcedSubtitles: setting(.showForcedSubtitles) { if case .bool(let v) = $0 { return v }; return nil },
            audioLanguage: setting(.audioLanguage) { if case .string(let v) = $0 { return v }; return nil },
            bufferingQualityMode: setting(.bufferingQualityMode) { if case .string(let v) = $0 { return SiloBufferingQualityMode(rawValue: v) }; return nil })
    }

    private static var unavailable: SiloEffectivePlaybackPreferences {
        .init(preferredQuality: .unavailable, maxBitrateKbps: .unavailable,
              subtitleLanguage: .unavailable, subtitleMode: .unavailable,
              showForcedSubtitles: .unavailable, audioLanguage: .unavailable,
              bufferingQualityMode: .unavailable)
    }
}
