// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What iCloud carries for a Live TV source: its settings and the secrets that live in the Keychain
/// (Dispatcharr key, Xtream and Tvheadend password, M3U and guide URLs).
nonisolated struct LiveTVSyncBody: Codable, Equatable {
    var type: String
    var name: String
    var baseURL: String?
    var username: String?
    var channelProfile: String?
    var canRecord: Bool?
    var secret: String?
    var m3uURL: String?
    var epgURL: String?
}

extension LiveTVDataStore {
    static func syncID(forSource id: String) -> String { "livetv:" + id }

    /// The saved IPTV sources with their secrets. A server's own Live TV is not saved, so not here.
    func syncExports() -> [AccountExport] {
        guard let data = userDefaults.data(forKey: sourcesKey),
              let configs = try? JSONDecoder().decode([SourceConfiguration].self, from: data) else { return [] }
        return configs.compactMap { config in
            guard ["dispatcharr", "m3u", "xtream", "tvheadend"].contains(config.type) else { return nil }
            let body = LiveTVSyncBody(
                type: config.type, name: config.name, baseURL: config.baseURL, username: config.username,
                channelProfile: config.channelProfile, canRecord: config.canRecord,
                secret: KeychainHelper.get(Self.apiTokenKey(sourceId: config.id)) ?? config.apiToken,
                m3uURL: KeychainHelper.get(Self.playlistURLKey(sourceId: config.id)) ?? config.m3uURL,
                epgURL: KeychainHelper.get(Self.guideURLKey(sourceId: config.id)) ?? config.epgURL)
            return AccountExport(id: Self.syncID(forSource: config.id), kind: "livetv", identity: nil, body: SyncBodies.encode(body))
        }
    }

    /// Adds (or replaces) a source from another device. True when it is in use afterwards.
    func adoptSyncedSource(id: String, _ body: LiveTVSyncBody) async -> AdoptOutcome {
        let url = body.baseURL.flatMap(URL.init(string:))
        switch body.type {
        case "dispatcharr":
            guard let url else { return .refused }
            await addDispatcharrSource(baseURL: url, name: body.name, apiToken: body.secret, channelProfile: body.channelProfile)
        case "m3u":
            guard let m3u = body.m3uURL.flatMap(URL.init(string:)) else { return .refused }
            await addM3USource(m3uURL: m3u, epgURL: body.epgURL.flatMap(URL.init(string:)), name: body.name)
        case "xtream":
            guard let url, let username = body.username, let password = body.secret else { return .refused }
            await addXtreamSource(account: XtreamAccount(server: url, username: username, password: password), name: body.name)
        case "tvheadend":
            guard let url else { return .refused }
            await addTvheadendSource(account: TvheadendAccount(server: url, username: body.username, password: body.secret),
                                     name: body.name, canRecord: body.canRecord)
        default:
            return .refused
        }
        return hasSource(id: id) ? .adopted : .refused
    }
}

extension SyncedAccountKind {
    static var liveTV: SyncedAccountKind {
        let prefix = LiveTVDataStore.syncID(forSource: "")
        return SyncedAccountKind(
            kind: "livetv", updatesInPlace: true,
            export: { LiveTVDataStore.shared.syncExports() },
            adopt: { entry in
                guard let body = SyncBodies.decode(LiveTVSyncBody.self, entry.body) else { return .refused }
                return await LiveTVDataStore.shared.adoptSyncedSource(id: String(entry.id.dropFirst(prefix.count)), body)
            },
            remove: { entry in await LiveTVDataStore.shared.removeSourceLocally(id: String(entry.id.dropFirst(prefix.count))) })
    }
}
