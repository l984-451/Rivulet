// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Page-owned snapshot of the local policy actor. Server settings are read only.
@MainActor
enum SiloPlaybackSettingsContent {
    private static var authority: SiloPlaybackAuthority?
    private static var revision: UInt64 = 0
    private static var follows = true
    private static var overrides = SiloLocalPlaybackOverrides()
    private static var effective: SiloEffectivePlaybackPreferences?
    private static var schema: SiloPlaybackSettingsSchema?
    private static var loading = false
    private static var generation = UUID()

    private static func owner(_ provider: SiloProvider, _ account: SiloSession.Account) -> Bool {
        SiloSession.account == account && SiloSession.authorityRevision == provider.authorityRevision
    }

    static func refresh(provider: SiloProvider, account: SiloSession.Account, reload: @escaping () -> Void) {
        let key = SiloPlaybackAuthority(providerID: provider.id, accountID: account.userID, profileID: account.profileID)
        let token = UUID()
        generation = token
        authority = key
        revision = provider.authorityRevision
        effective = nil
        schema = nil
        loading = true
        reload()
        Task { @MainActor in
            let context = SiloPlaybackOverrideContext(authority: key, libraryID: nil, seriesID: nil)
            let store = SiloPlaybackPolicyStore.shared
            let savedFollow = await store.followsSilo(for: key)
            let savedOverrides = await store.overrides(for: context) ?? SiloLocalPlaybackOverrides()
            let preferences = SiloPlaybackPreferences(provider: provider)
            let contract = try? await preferences.schema()
            let server = contract == nil ? nil : try? await preferences.effective()
            await SiloThemeMusicController.shared.refresh(provider: provider)
            guard generation == token, owner(provider, account) else { return }
            follows = savedFollow
            overrides = savedOverrides
            schema = contract
            effective = server
            loading = false
            reload()
        }
    }

    static func rows(provider: SiloProvider, account: SiloSession.Account) -> [SettingsRowItem] {
        let key = SiloPlaybackAuthority(providerID: provider.id, accountID: account.userID, profileID: account.profileID)
        guard authority == key, revision == provider.authorityRevision, owner(provider, account) else { return [] }
        if loading { return [SettingsRowItem(id: "siloPlaybackLoading", title: "Loading Playback Settings…", kind: .info(value: { "" }))] }
        var rows: [SettingsRowItem] = []
        if schema != nil {
            rows.append(SettingsRowItem(id: "siloFollowPlayback", title: "Follow Silo Playback", kind: .toggle(
                get: { follows }, set: { value in
                    guard owner(provider, account) else { return }
                    follows = value
                    Task { await SiloPlaybackPolicyStore.shared.setFollowsSilo(value, for: key) }
                }
            )))
            if effective == nil {
                rows.append(SettingsRowItem(id: "siloPlaybackUnavailable", title: "Silo Preferences Unavailable",
                                            kind: .info(value: { "" })))
            }
        }
        // Local policy applies whether or not the profile's preferences are followed.
        rows.append(cycle("siloBufferingPolicy", "Buffering Quality", value: overrides.bufferingPolicy,
                          options: [(.inherit, "Ask First"), (.value(.never), "Never"),
                                    (.value(.ask), "Ask First"), (.value(.automatically), "Automatically"), (.clear, "Clear")],
                          provider: provider, account: account) { overrides.bufferingPolicy = $0 })
        if schema?.definitions[.preferredQuality] != nil {
            rows.append(text("siloQualityOverride", "Preferred Quality", value: {
                switch overrides.quality { case .inherit: ""; case .clear: "clear";
                case .value(.automatic): "auto"; case .value(.offered(let id)): id }
            }, save: { raw in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                overrides.quality = value.isEmpty ? .inherit : value == "clear" ? .clear :
                    .value(value == "auto" ? .automatic : .offered(id: value))
            }, provider: provider, account: account, hint: "Use Auto, an exact Silo quality ID, or Clear. Empty inherits."))
        }
        if schema?.definitions[.maxBitrateKbps] != nil {
            rows.append(text("siloBitrateOverride", "Maximum Bitrate (kbps)", value: {
                switch overrides.maxBitrateKbps { case .inherit: ""; case .clear: "clear"; case .value(let kbps): String(kbps) }
            }, save: { raw in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { overrides.maxBitrateKbps = .inherit }
                else if value == "clear" { overrides.maxBitrateKbps = .clear }
                else if let kbps = Int(value), kbps > 0 { overrides.maxBitrateKbps = .value(kbps) }
            }, provider: provider, account: account, hint: "Positive kbps, Clear, or empty to inherit."))
        }
        if schema?.definitions[.audioLanguage] != nil {
            rows.append(language("siloAudioLanguageOverride", "Audio Language", provider: provider, account: account,
                                 get: { overrides.audioLanguage }, set: { overrides.audioLanguage = $0 }))
        }
        // The profile's own subtitle settings, in Silo's names. Following the
        // profile is the default; a local choice overrides this Apple TV only.
        if schema?.definitions[.subtitleLanguage] != nil {
            rows.append(SettingsRowItem(id: "siloSubtitleLanguageOverride", title: "Subtitle Language",
                kind: .navigationValue(.siloSubtitleLanguagePicker, value: {
                    SiloSubtitlePreferenceLabels.languageValue(override: overrides.subtitleLanguage,
                                                              resolved: resolvedSubtitleLanguage)
                })))
        }
        if schema?.definitions[.subtitleMode] != nil {
            rows.append(cycle("siloSubtitleModeOverride", "Subtitles", value: overrides.subtitleMode,
                              options: SiloSubtitlePreferenceLabels.modeOptions(resolved: resolvedSubtitleMode),
                              provider: provider, account: account) {
                overrides.subtitleMode = $0
            })
        }
        if schema?.definitions[.showForcedSubtitles] != nil {
            rows.append(cycle("siloForcedSubtitleOverride", "Forced Subtitles", value: overrides.showForcedSubtitles,
                              options: SiloSubtitlePreferenceLabels.forcedOptions(resolved: resolvedForcedSubtitles),
                              provider: provider, account: account) {
                overrides.showForcedSubtitles = $0
            })
        }
        rows += SettingsContent.siloThemeMusicRows(provider: provider)
        return rows
    }

    // MARK: Profile resolution

    /// What Silo's profile resolves to for this client, or nil when the server
    /// answered nothing for that axis.
    private static var resolvedSubtitleLanguage: String? {
        guard case .resolved(let row) = effective?.subtitleLanguage else { return nil }
        return row.value
    }

    private static var resolvedSubtitleMode: SiloSubtitleMode? {
        guard case .resolved(let row) = effective?.subtitleMode else { return nil }
        return row.value
    }

    private static var resolvedForcedSubtitles: Bool? {
        guard case .resolved(let row) = effective?.showForcedSubtitles else { return nil }
        return row.value
    }

    /// The picker pushed from the Silo page. Values are the contract's own
    /// language tags when the server publishes them.
    static var siloSubtitleLanguagePicker: [SettingsRowItem] {
        guard let provider = SiloSession.storedProvider(), let account = SiloSession.account,
              owner(provider, account) else { return [] }
        func choose(_ value: SiloLocalPolicyValue<String>) {
            overrides.subtitleLanguage = value
            save(provider: provider, account: account)
        }
        var rows = [
            SettingsRowItem(id: "siloSL_inherit", title: "Follow Silo",
                            kind: .option(isSelected: { overrides.subtitleLanguage == .inherit },
                                          select: { choose(.inherit) })),
            SettingsRowItem(id: "siloSL_clear", title: "None",
                            kind: .option(isSelected: { overrides.subtitleLanguage == .clear },
                                          select: { choose(.clear) }))
        ]
        rows += subtitleLanguageOptions.map { tag in
            SettingsRowItem(id: "siloSL_\(tag)", title: SiloSubtitlePreferenceLabels.languageName(tag),
                            kind: .option(isSelected: { sameLanguage(selectedSubtitleLanguage, tag) },
                                          select: { choose(.value(tag)) }))
        }
        return rows
    }

    private static var selectedSubtitleLanguage: String? {
        if case .value(let tag) = overrides.subtitleLanguage { return tag }
        return nil
    }

    /// The server's own tags, or Rivulet's codes when it publishes none, plus
    /// an out-of-contract override so the current choice stays visible.
    private static var subtitleLanguageOptions: [String] {
        let published = schema?.subtitleLanguages ?? []
        var options = published.isEmpty ? TrackLanguage.choices : published
        if let current = selectedSubtitleLanguage,
           !options.contains(where: { sameLanguage($0, current) }) {
            options.append(current)
        }
        return options
    }

    private static func sameLanguage(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = TrackLanguage.normalize(lhs), right = TrackLanguage.normalize(rhs)
        return !left.isEmpty && left == right
    }

    private static func save(provider: SiloProvider, account: SiloSession.Account) {
        guard owner(provider, account), let authority else { return }
        let context = SiloPlaybackOverrideContext(authority: authority, libraryID: nil, seriesID: nil)
        let value = overrides
        Task { await SiloPlaybackPolicyStore.shared.setOverrides(value, for: context) }
    }

    private static func cycle<Value: Equatable & Codable & Sendable>(
        _ id: String, _ title: String, value: SiloLocalPolicyValue<Value>,
        options: [(SiloLocalPolicyValue<Value>, String)], provider: SiloProvider, account: SiloSession.Account,
        set: @escaping (SiloLocalPolicyValue<Value>) -> Void
    ) -> SettingsRowItem {
        var current = value
        return SettingsRowItem(id: id, title: title, kind: .cycle(value: {
            options.first { $0.0 == current }?.1 ?? "Inherit"
        }, next: {
            guard owner(provider, account) else { return }
            let index = options.firstIndex { $0.0 == current } ?? 0
            current = options[(index + 1) % options.count].0
            set(current)
            save(provider: provider, account: account)
        }))
    }

    private static func language(_ id: String, _ title: String, provider: SiloProvider, account: SiloSession.Account,
                                 get: @escaping () -> SiloLocalPolicyValue<String>,
                                 set: @escaping (SiloLocalPolicyValue<String>) -> Void) -> SettingsRowItem {
        text(id, title, value: {
            switch get() { case .inherit: ""; case .clear: "clear"; case .value(let language): language }
        }, save: { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            set(value.isEmpty ? .inherit : value == "clear" ? .clear : .value(value))
        }, provider: provider, account: account, hint: "Language code, Clear, or empty to inherit.")
    }

    private static func text(_ id: String, _ title: String, value: @escaping () -> String,
                             save change: @escaping (String) -> Void, provider: SiloProvider,
                             account: SiloSession.Account, hint: String) -> SettingsRowItem {
        SettingsRowItem(id: id, title: title, kind: .textEntry(
            value: value, placeholder: "Inherit", hint: hint, suggestions: [], keyboardType: .asciiCapable,
            set: { raw in
                guard owner(provider, account) else { return }
                change(raw)
                save(provider: provider, account: account)
            }
        ))
    }
}
