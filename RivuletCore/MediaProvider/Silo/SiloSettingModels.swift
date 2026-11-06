import Foundation

/// Only the playback keys consumed by Rivulet. Each axis remains independent.
nonisolated enum SiloPlaybackSettingKey: String, CaseIterable, Sendable {
    case preferredQuality = "playback.preferred_quality"
    case maxBitrateKbps = "playback.max_bitrate_kbps"
    case subtitleLanguage = "playback.subtitle_language"
    case subtitleMode = "playback.subtitle_mode"
    case showForcedSubtitles = "playback.show_forced_subtitles"
    case audioLanguage = "playback.audio_language"
    case bufferingQualityMode = "playback.buffering_quality_mode"

    var minimumRevision: Int { self == .bufferingQualityMode ? 23 : 1 }
}

nonisolated enum SiloSettingJSON: Decodable, Equatable, Sendable {
    case null, bool(Bool), integer(Int), number(Double), string(String)
    case array([SiloSettingJSON]), object([String: SiloSettingJSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([SiloSettingJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: SiloSettingJSON].self)) }
    }
}

nonisolated enum SiloSettingScope: Equatable, Sendable {
    case account, profile, profileClient, profileDevice, profileLibrary, profileSeries, contractDefault, unknown(String)
    init(_ raw: String) {
        switch raw {
        case "account": self = .account
        case "profile": self = .profile
        case "profile_client": self = .profileClient
        case "profile_device": self = .profileDevice
        case "profile_library": self = .profileLibrary
        case "profile_series": self = .profileSeries
        case "default": self = .contractDefault
        default: self = .unknown(raw)
        }
    }
}

nonisolated struct SiloResolvedSetting<Value: Equatable & Sendable>: Equatable, Sendable {
    /// nil means no known typed value. `rawValue == .null` means explicit JSON null.
    let value: Value?
    let rawValue: SiloSettingJSON
    let source: SiloSettingScope
    let scope: SiloSettingScope?
    let profileId: String?
    let libraryId: String?
    let seriesId: String?
    let deviceId: String?
    let clientFamily: String?
    let storedValue: SiloSettingJSON?
    let constrained: Bool
}

nonisolated enum SiloSettingAvailability<Value: Equatable & Sendable>: Equatable, Sendable {
    case unavailable
    case resolved(SiloResolvedSetting<Value>)
}

nonisolated enum SiloSubtitleMode: String, Sendable { case auto, always, off }
nonisolated enum SiloBufferingQualityMode: String, Sendable { case never, ask, always }

nonisolated struct SiloEffectivePlaybackPreferences: Sendable {
    let preferredQuality: SiloSettingAvailability<String>
    let maxBitrateKbps: SiloSettingAvailability<Int>
    let subtitleLanguage: SiloSettingAvailability<String>
    let subtitleMode: SiloSettingAvailability<SiloSubtitleMode>
    let showForcedSubtitles: SiloSettingAvailability<Bool>
    let audioLanguage: SiloSettingAvailability<String>
    let bufferingQualityMode: SiloSettingAvailability<SiloBufferingQualityMode>
}

nonisolated struct SiloSettingsCapabilities: Decodable, Sendable {
    let state: String
    let allowed: Bool
    let manifestRevision: Int
    let supportsBatchedEffective: Bool
    var available: Bool { state == "available" && allowed && supportsBatchedEffective }
}

nonisolated struct SiloEffectiveSettingWire: Decodable, Sendable {
    let key: String
    let value: SiloSettingJSON
    let source: String
    let scope: String?
    let profileId: String?
    let libraryId: String?
    let seriesId: String?
    let deviceId: String?
    let clientFamily: String?
    let storedValue: SiloSettingJSON?
    let constrained: Bool

    enum CodingKeys: String, CodingKey {
        case key, value, source, scope, constrained
        case profileId, libraryId, seriesId
        case deviceId, clientFamily, storedValue
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        value = try c.decode(SiloSettingJSON.self, forKey: .value)
        source = try c.decode(String.self, forKey: .source)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
        libraryId = try c.decodeIfPresent(String.self, forKey: .libraryId)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        clientFamily = try c.decodeIfPresent(String.self, forKey: .clientFamily)
        storedValue = c.contains(.storedValue) ? try c.decode(SiloSettingJSON.self, forKey: .storedValue) : nil
        constrained = try c.decodeIfPresent(Bool.self, forKey: .constrained) ?? false
    }

    func typed<T: Equatable & Sendable>(_ convert: (SiloSettingJSON) -> T?) -> SiloResolvedSetting<T> {
        SiloResolvedSetting(value: convert(value), rawValue: value, source: .init(source),
            scope: scope.map(SiloSettingScope.init), profileId: profileId, libraryId: libraryId,
            seriesId: seriesId, deviceId: deviceId, clientFamily: clientFamily,
            storedValue: storedValue, constrained: constrained)
    }
}

nonisolated struct SiloEffectiveSettingsWire: Decodable, Sendable {
    let items: [SiloEffectiveSettingWire]
    let revision: Int
}

/// Server schema metadata for supported playback keys only.
nonisolated struct SiloPlaybackSettingDefinition: Decodable, Sendable {
    let key: String
    let introducedIn: Int
    let allowedScopes: [String]
    let resolutionOrder: [String]
    let valueSchema: SiloSettingJSON
    let defaultValue: SiloSettingJSON

    private enum CodingKeys: String, CodingKey {
        case key, introducedIn, allowedScopes, resolutionOrder, valueSchema, defaultValue
    }

    private enum Scope: Decodable {
        case name(String)

        private enum CodingKeys: String, CodingKey { case scope, introducedIn }

        init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self = .name(name)
                return
            }
            let object = try decoder.container(keyedBy: CodingKeys.self)
            let name = try object.decode(String.self, forKey: .scope)
            _ = try object.decode(Int.self, forKey: .introducedIn)
            self = .name(name)
        }

        var name: String { switch self { case .name(let value): value } }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        introducedIn = try values.decode(Int.self, forKey: .introducedIn)
        allowedScopes = try values.decode([Scope].self, forKey: .allowedScopes).map(\.name)
        resolutionOrder = try values.decode([String].self, forKey: .resolutionOrder)
        valueSchema = try values.decode(SiloSettingJSON.self, forKey: .valueSchema)
        defaultValue = try values.decode(SiloSettingJSON.self, forKey: .defaultValue)
    }
}

nonisolated struct SiloSettingsContractWire: Decodable, Sendable {
    let revision: Int
    let definitions: [SiloPlaybackSettingDefinition]
    /// Keys this build offers as language tags. A server that does not publish
    /// option sets leaves this empty and the picker falls back to Rivulet's own
    /// language list.
    let subtitleLanguages: [String]

    private enum CodingKeys: String, CodingKey { case revision, definitions, optionSets }

    private struct PlaybackDefinition: Decodable {
        let value: SiloPlaybackSettingDefinition?

        private enum CodingKeys: String, CodingKey { case key }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let key = try values.decode(String.self, forKey: .key)
            if SiloPlaybackSettingKey(rawValue: key) != nil {
                value = try SiloPlaybackSettingDefinition(from: decoder)
            } else {
                value = nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(Int.self, forKey: .revision)
        definitions = try values.decode([PlaybackDefinition].self, forKey: .definitions).compactMap(\.value)
        let sets = try values.decodeIfPresent(SiloSettingOptionSets.self, forKey: .optionSets)
        subtitleLanguages = sets?.values(named: "playback_subtitle_languages", upTo: revision) ?? []
    }
}

/// One server-published choice, in contract order.
nonisolated struct SiloSettingOption: Decodable, Sendable {
    let value: String
    let introducedIn: Int
}

nonisolated struct SiloSettingOptionSet: Decodable, Sendable {
    let options: [SiloSettingOption]
}

/// `option_sets` is a dictionary, so the snake-case key strategy rewrites the
/// set's own name too ("playback_subtitle_languages" becomes
/// "playbackSubtitleLanguages"). Compare names with separators removed.
nonisolated struct SiloSettingOptionSets: Decodable, Sendable {
    private let sets: [String: SiloSettingOptionSet]

    init(from decoder: Decoder) throws {
        sets = try [String: SiloSettingOptionSet](from: decoder)
    }

    func values(named name: String, upTo revision: Int) -> [String] {
        let wanted = Self.comparable(name)
        guard let set = sets.first(where: { Self.comparable($0.key) == wanted })?.value else { return [] }
        return set.options.filter { $0.introducedIn <= revision }.map(\.value)
    }

    private static func comparable(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: "").lowercased()
    }
}

nonisolated struct SiloPlaybackSettingsSchema: Sendable {
    let revision: Int
    let definitions: [SiloPlaybackSettingKey: SiloPlaybackSettingDefinition]
    /// The contract's own language tags, empty when the server publishes none.
    let subtitleLanguages: [String]
}
