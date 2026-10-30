// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct SiloPlaybackAuthority: Hashable, Codable, Sendable {
    let providerID: String
    let accountID: String
    let profileID: String
}

nonisolated struct SiloPlaybackOverrideContext: Hashable, Codable, Sendable {
    let authority: SiloPlaybackAuthority
    let libraryID: String?
    let seriesID: String?
}

/// Inherit is absence at this scope; clear is an intentional nil that stops fallback.
nonisolated enum SiloLocalPolicyValue<Value: Equatable & Codable & Sendable>: Equatable, Codable, Sendable {
    case inherit
    case clear
    case value(Value)
}

/// Unavailable means no setting was supplied; clear means the winning scope supplied null.
nonisolated enum SiloResolvedPolicyValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case unavailable
    case clear
    case value(Value)
}

nonisolated struct SiloLocalPlaybackOverrides: Equatable, Codable, Sendable {
    var quality: SiloLocalPolicyValue<MediaQualityPreference> = .inherit
    var maxBitrateKbps: SiloLocalPolicyValue<Int> = .inherit
    var audioLanguage: SiloLocalPolicyValue<String> = .inherit
    var subtitleLanguage: SiloLocalPolicyValue<String> = .inherit
    var subtitleMode: SiloLocalPolicyValue<SiloLocalSubtitleMode> = .inherit
    var showForcedSubtitles: SiloLocalPolicyValue<Bool> = .inherit
    var bufferingPolicy: SiloLocalPolicyValue<BufferingQualityPolicy> = .inherit

    var isEmpty: Bool {
        quality == .inherit && maxBitrateKbps == .inherit && audioLanguage == .inherit
        && subtitleLanguage == .inherit && subtitleMode == .inherit
        && showForcedSubtitles == .inherit && bufferingPolicy == .inherit
    }
}

nonisolated enum SiloLocalSubtitleMode: String, Codable, Sendable { case auto, always, off }

nonisolated struct SiloResolvedPlaybackPolicy: Equatable, Sendable {
    let followsSilo: Bool
    let quality: SiloResolvedPolicyValue<MediaQualityPreference>
    let maxBitrateKbps: SiloResolvedPolicyValue<Int>
    let audioLanguage: SiloResolvedPolicyValue<String>
    let subtitleLanguage: SiloResolvedPolicyValue<String>
    let subtitleMode: SiloResolvedPolicyValue<SiloLocalSubtitleMode>
    let showForcedSubtitles: SiloResolvedPolicyValue<Bool>
    let bufferingPolicy: SiloResolvedPolicyValue<BufferingQualityPolicy>
}

/// Local-only shared state. All player and Settings consumers should use `shared`.
/// Server effective values are read only and never persisted or promoted between scopes.
actor SiloPlaybackPolicyStore {
    static let shared = SiloPlaybackPolicyStore()

    /// A profile's Silo preferences apply until the viewer opts out, which is
    /// what Silo's own clients do. A record stored before this default existed
    /// keeps whatever it holds, and a record missing the flag reads as true.
    private struct Record: Codable {
        var followsSilo = true
        var overrides: [OverrideEntry] = []

        init(followsSilo: Bool = true, overrides: [OverrideEntry] = []) {
            self.followsSilo = followsSilo
            self.overrides = overrides
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            followsSilo = try values.decodeIfPresent(Bool.self, forKey: .followsSilo) ?? true
            overrides = try values.decodeIfPresent([OverrideEntry].self, forKey: .overrides) ?? []
        }
    }
    private struct OverrideEntry: Codable {
        let context: SiloPlaybackOverrideContext
        let value: SiloLocalPlaybackOverrides
    }
    private struct Entry: Codable { let authority: SiloPlaybackAuthority; let record: Record }

    private let defaults: UserDefaults
    private let storageKey: String
    private var records: [SiloPlaybackAuthority: Record]

    init(defaults: UserDefaults = .standard, storageKey: String = "silo.localPlaybackPolicy.v2") {
        self.defaults = defaults
        self.storageKey = storageKey
        let entries = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        records = Dictionary(entries.map { ($0.authority, $0.record) }, uniquingKeysWith: { _, latest in latest })
    }

    func followsSilo(for authority: SiloPlaybackAuthority) -> Bool { records[authority]?.followsSilo ?? true }

    func setFollowsSilo(_ enabled: Bool, for authority: SiloPlaybackAuthority) {
        var record = records[authority] ?? Record()
        record.followsSilo = enabled
        records[authority] = record
        persist()
    }

    func setOverrides(_ value: SiloLocalPlaybackOverrides, for context: SiloPlaybackOverrideContext) {
        var record = records[context.authority] ?? Record()
        record.overrides.removeAll { $0.context == context }
        if !value.isEmpty { record.overrides.append(.init(context: context, value: value)) }
        records[context.authority] = record
        persist()
    }

    func overrides(for context: SiloPlaybackOverrideContext) -> SiloLocalPlaybackOverrides? {
        records[context.authority]?.overrides.first { $0.context == context }?.value
    }

    func resolve(context: SiloPlaybackOverrideContext, server: SiloEffectivePlaybackPreferences?,
                 manualQuality: MediaQualityPreference? = nil, manualAudioLanguage: String? = nil,
                 manualSubtitleLanguage: String? = nil) -> SiloResolvedPlaybackPolicy {
        let record = records[context.authority] ?? Record()
        let profile = record.overrides.first { $0.context == .init(authority: context.authority, libraryID: nil, seriesID: nil) }?.value
        let library = context.libraryID.flatMap { id in record.overrides.first { $0.context == .init(authority: context.authority, libraryID: id, seriesID: nil) }?.value }
        let series = context.seriesID.flatMap { id in record.overrides.first { $0.context == .init(authority: context.authority, libraryID: context.libraryID, seriesID: id) }?.value }
        let inherited = record.followsSilo ? server : nil
        func serverValue<Raw: Equatable & Sendable, Value: Equatable & Sendable>(
            _ availability: SiloSettingAvailability<Raw>?, _ map: (Raw) -> Value?) -> SiloResolvedPolicyValue<Value> {
            guard let availability, case .resolved(let row) = availability else { return .unavailable }
            guard let raw = row.value else { return row.rawValue == .null ? .clear : .unavailable }
            guard let mapped = map(raw) else { return .unavailable }
            return .value(mapped)
        }
        func choose<Value: Equatable & Codable & Sendable>(
            _ manual: Value?, _ series: SiloLocalPolicyValue<Value>?,
            _ library: SiloLocalPolicyValue<Value>?, _ profile: SiloLocalPolicyValue<Value>?,
            _ server: SiloResolvedPolicyValue<Value>) -> SiloResolvedPolicyValue<Value> {
            if let manual { return .value(manual) }
            for local in [series, library, profile] {
                switch local {
                case .value(let value): return .value(value)
                case .clear: return .clear
                case .inherit, .none: break
                }
            }
            return server
        }
        let quality: SiloResolvedPolicyValue<MediaQualityPreference> = serverValue(inherited?.preferredQuality) {
            $0 == "auto" ? .automatic : .offered(id: $0)
        }
        let bitrate: SiloResolvedPolicyValue<Int> = serverValue(inherited?.maxBitrateKbps) { $0 }
        let audio: SiloResolvedPolicyValue<String> = serverValue(inherited?.audioLanguage) { $0 }
        let subtitle: SiloResolvedPolicyValue<String> = serverValue(inherited?.subtitleLanguage) { $0 }
        let mode: SiloResolvedPolicyValue<SiloLocalSubtitleMode> = serverValue(inherited?.subtitleMode) { SiloLocalSubtitleMode(rawValue: $0.rawValue) }
        let forced: SiloResolvedPolicyValue<Bool> = serverValue(inherited?.showForcedSubtitles) { $0 }
        let buffering: SiloResolvedPolicyValue<BufferingQualityPolicy> = serverValue(inherited?.bufferingQualityMode) {
            switch $0 { case .never: .never; case .ask: .ask; case .always: .automatically }
        }
        return .init(followsSilo: record.followsSilo,
                     quality: choose(manualQuality, series?.quality, library?.quality, profile?.quality, quality),
                     maxBitrateKbps: choose(nil, series?.maxBitrateKbps, library?.maxBitrateKbps, profile?.maxBitrateKbps, bitrate),
                     audioLanguage: choose(manualAudioLanguage, series?.audioLanguage, library?.audioLanguage, profile?.audioLanguage, audio),
                     subtitleLanguage: choose(manualSubtitleLanguage, series?.subtitleLanguage, library?.subtitleLanguage, profile?.subtitleLanguage, subtitle),
                     subtitleMode: choose(nil, series?.subtitleMode, library?.subtitleMode, profile?.subtitleMode, mode),
                     showForcedSubtitles: choose(nil, series?.showForcedSubtitles, library?.showForcedSubtitles, profile?.showForcedSubtitles, forced),
                     bufferingPolicy: choose(nil, series?.bufferingPolicy, library?.bufferingPolicy, profile?.bufferingPolicy, buffering))
    }

    private func persist() {
        let entries = records.map { Entry(authority: $0.key, record: $0.value) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
