// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchTogetherSession.swift
//  Rivulet
//
//  One Open Watch Party room (#494): the relay holds the shared timeline, the SDK
//  keeps this device's player on it, and everyone streams their own copy. Hosts
//  plug in a resolver, a way to open a file, and a player adapter.
//

import Combine
import Foundation
import OpenWatchParty

/// The file this device plays for the room's title.
nonisolated struct WatchTogetherItem: Hashable, Sendable {
    let providerID: String
    let itemID: String
    var sourceID: String?
}

@MainActor
final class WatchTogetherSession: ObservableObject {
    static let shared = WatchTogetherSession()

    /// Open Watch Party's public relays, used with the operator's written permission.
    /// One instance for every party, so the list's refresh schedule carries over (SDK.md §3).
    private static let relays: Relays = {
        #if DEBUG
        if let debug = ProcessInfo.processInfo.environment["RIVULET_OWP_RELAY"], let relays = try? Relays.at(debug) {
            return relays
        }
        #endif
        return .public()
    }()

    struct Member: Equatable, Identifiable {
        enum Status: Equatable { case watching, loading, buffering, away, noCopy }
        let id: String
        let name: String
        let isHost: Bool
        let isMe: Bool
        let status: Status
    }

    enum Failure: Equatable {
        case unavailable, unreachable, roomNotFound, roomFull, invalidCode, other
    }

    /// The code as read aloud ("K7M-Q2X"); nil outside a room.
    @Published private(set) var code: String?
    @Published private(set) var members: [Member] = []
    @Published private(set) var isHost = false
    @Published private(set) var isReconnecting = false
    /// A sentence for the screen: who joined, who paused, why a press did nothing.
    let notices = PassthroughSubject<String, Never>()

    /// Finds this user's copies of the room's title, best first.
    var resolver: (@MainActor (Media) async throws -> [Candidate<WatchTogetherItem>])?
    /// Open this file: present a player and call `attach`. The second value is the room's position.
    var onOpen: ((WatchTogetherItem, TimeInterval?) -> Void)?
    /// The closest copy differs from the room's by this many seconds; answer with `answerMismatch`.
    var onMismatch: ((TimeInterval) -> Void)?
    /// This user has no copy of the room's title.
    var onNoCopy: ((String) -> Void)?
    /// The party is over, or this device became the host.
    var onRoleChange: (() -> Void)?

    private var party: WatchParty<WatchTogetherItem>?
    private var openedRef: WatchTogetherItem?
    private var promptedMismatch = false
    /// Pause once the relay confirms the media: until then the room refuses a pause.
    private var holdsNextMedia = false
    private var tasks: [Task<Void, Never>] = []

    var isActive: Bool { party != nil }
    /// The room's position now, in seconds of the host's file.
    /// This device's copy runs this far from the room's timeline (a different cut).
    var offsetMs: Int64 { party?.state.offsetMs ?? 0 }
    var roomPosition: TimeInterval? { party?.roomPositionMs().map { TimeInterval($0) / 1000 } }
    /// In a room without the host's rights: what plays next is the host's call.
    var isGuest: Bool { party != nil && !isHost }

    // MARK: - Entering

    func create(name: String, client: String) async throws {
        let party = try makeParty(name: name, client: client)
        do {
            _ = try await party.create()
            // Host-only control is the relay's default; a pause belongs to everyone (#494).
            try party.setControl(.everyone)
        } catch {
            finish(party)
            throw error
        }
    }

    func join(code: String, name: String, client: String) async throws {
        let party = try makeParty(name: name, client: client)
        do {
            try await party.join(code)
        } catch {
            finish(party)
            throw error
        }
    }

    private func makeParty(name: String, client: String) throws -> WatchParty<WatchTogetherItem> {
        let relays = Self.relays
        leave()
        let party = try WatchParty<WatchTogetherItem>(
            relays: relays, client: client, name: Self.cleanName(name),
            resolver: Resolver { [weak self] media in try await self?.resolver?(media) ?? [] })
        self.party = party
        let states = party.states()
        let events = party.events()
        tasks = [
            Task { [weak self] in for await state in states { self?.apply(state) } },
            Task { [weak self] in for await event in events { self?.handle(event) } },
        ]
        return party
    }

    /// The relay takes 1 to 32 characters, and everyone reads it.
    nonisolated static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        return trimmed.isEmpty ? "Rivulet" : String(trimmed.prefix(32))
    }

    // MARK: - Hosting

    /// Shares this file with the room, held paused until someone presses play.
    func share(_ media: Media, item: WatchTogetherItem, at position: TimeInterval, holdPaused: Bool) throws {
        guard let party else { throw PartyError(.notInRoom) }
        openedRef = item
        try party.setMedia(media, ref: item, positionMs: Int64(max(0, position) * 1000))
        holdsNextMedia = holdPaused
    }

    /// The title the room is on, for a host that moved to the next one.
    func attach(_ adapter: any PlayerAdapter, item: WatchTogetherItem) {
        party?.attachPlayer(adapter, ref: item)
    }

    /// Stop following the room for now. The room stops waiting for this device.
    func detach() {
        _ = party?.detachPlayer()
    }

    /// The adapter trims its own drift against this: how far the player is from the room, in ms.
    func drift(of adapter: WatchTogetherPlayerAdapter) -> Int64? {
        guard let room = roomPosition else { return nil }
        return adapter.positionMs - Int64(room * 1000) - offsetMs
    }

    // MARK: - Presses

    /// Sends a press to the room. True when the room took it, so the caller must
    /// not also touch the player: the SDK does when the relay answers.
    func requestPlay() -> Bool { send { try $0.play() } }
    func requestPause() -> Bool { send { try $0.pause() } }
    func requestSeek(to time: TimeInterval) -> Bool {
        send { try $0.seek(to: Int64(max(0, time) * 1000)) }
    }

    private func send(_ command: (WatchParty<WatchTogetherItem>) throws -> Void) -> Bool {
        guard let party, party.state.choice != nil else { return false }
        do {
            try command(party)
        } catch let error as PartyError where error.code == .forbidden {
            notices.send(String(localized: "Only the host can control playback."))
        } catch {
            notices.send(String(localized: "Reconnecting to Watch Together…"))
        }
        return true
    }

    /// Plays the offered copy, or sits this title out.
    func answerMismatch(accept: Bool) {
        if accept { party?.acceptMismatch() } else { party?.declineMismatch() }
    }

    // MARK: - Leaving

    func leave() {
        guard let party else { return }
        party.leave()
        finish(party)
    }

    private func finish(_ ended: WatchParty<WatchTogetherItem>) {
        guard party === ended else { return }
        _ = ended.close()
        tasks.forEach { $0.cancel() }
        tasks = []
        party = nil
        openedRef = nil
        promptedMismatch = false
        holdsNextMedia = false
        code = nil
        members = []
        isHost = false
        isReconnecting = false
        onRoleChange?()
    }

    // MARK: - Room state

    private func apply(_ state: PartyState<WatchTogetherItem>) {
        code = state.room.flatMap { try? formatCode($0.code) }
        isReconnecting = state.connection == .reconnecting
        members = (state.room?.participants ?? []).map { Self.member($0, me: state.peerId) }
        if state.isHost != isHost {
            isHost = state.isHost
            onRoleChange?()
        }

        if holdsNextMedia, state.media != nil, state.room != nil {
            holdsNextMedia = false
            try? party?.pause()
        }
        if let ref = state.choice?.ref, ref != openedRef {
            openedRef = ref
            promptedMismatch = false
            onOpen?(ref, roomPosition)
        }
        if let mismatch = state.mismatch, !promptedMismatch {
            promptedMismatch = true
            onMismatch?(TimeInterval(mismatch.deltaMs) / 1000)
        }
        if state.match?.state == .unavailable, !promptedMismatch, let media = state.media {
            promptedMismatch = true
            onNoCopy?(media.title)
        }
    }

    nonisolated static func member(_ participant: Participant, me: String?) -> Member {
        let status: Member.Status
        if !participant.connected {
            status = .away
        } else if participant.match?.state == .unavailable {
            status = .noCopy
        } else {
            switch participant.player {
            case .ready: status = .watching
            case .buffering: status = .buffering
            case .loading: status = .loading
            case .idle: status = .away
            }
        }
        return Member(id: participant.peerId, name: participant.name, isHost: participant.host,
                      isMe: participant.peerId == me, status: status)
    }

    private func handle(_ event: any PartyEvent) {
        switch event {
        case let joined as ParticipantJoinedEvent:
            notices.send(String(localized: "\(joined.participant.name) joined"))
        case let left as ParticipantLeftEvent:
            // Its own key: "%@ left" already means time remaining ("45 min left").
            notices.send(String(localized: "watchTogether.left", defaultValue: "\(left.participant.name) left"))
        case let action as ActionEvent where !action.byMe:
            guard let name = action.by?.name else { break }
            switch action.kind {
            case "play": notices.send(String(localized: "\(name) pressed play"))
            case "pause": notices.send(String(localized: "\(name) paused"))
            case "seek": notices.send(String(localized: "\(name) skipped"))
            default: break
            }
        case let ended as EndedEvent:
            if ended.reason != .left { notices.send(String(localized: "Watch Together ended")) }
            if let party { finish(party) }
        default:
            break
        }
    }

    nonisolated static func failure(for error: Error) -> Failure {
        guard let code = (error as? PartyError)?.code else { return .other }
        switch code {
        case .unreachable, .relayFull, .clientBlocked: return .unreachable
        case .roomNotFound: return .roomNotFound
        case .roomFull, .roomLocked: return .roomFull
        case .invalidCode: return .invalidCode
        default: return .other
        }
    }
}

// MARK: - Describing a Plex item

extension WatchTogetherSession {
    /// The reverse-DNS key of Rivulet's own shortcut in a media descriptor: the same
    /// server and item, for titles with no catalogue id (home videos).
    nonisolated static let extKey = "com.gstudios.rivulet"

    nonisolated static func ext(server: String, item: String) -> [String: JSONValue] {
        [extKey: .object(["server": .string(server), "item": .string(item)])]
    }

    /// The server and item a descriptor's shortcut names.
    nonisolated static func shortcut(in media: Media) -> (server: String, item: String)? {
        guard case .object(let fields)? = media.ext?[extKey],
              case .string(let server)? = fields["server"],
              case .string(let item)? = fields["item"] else { return nil }
        return (server, item)
    }

    /// Catalogue ids from Plex's `Guid` strings ("imdb://tt123" → ["imdb": "tt123"]).
    nonisolated static func ids(fromPlexGuid guid: String?, guids: [String]) -> [String: String] {
        var ids: [String: String] = [:]
        if let guid, guid.hasPrefix("plex://") { ids["plex"] = guid }
        for raw in guids {
            let parts = raw.components(separatedBy: "://")
            guard parts.count == 2, ["imdb", "tmdb", "tvdb"].contains(parts[0]), !parts[1].isEmpty else { continue }
            ids[parts[0]] = parts[1]
        }
        return ids
    }

    /// The room's descriptor for a Plex item, from full metadata (and its show's, for an episode).
    nonisolated static func media(plex meta: PlexMetadata, show: PlexMetadata?, durationMs: Int64,
                                  server: String?) -> Media {
        let kind: OpenWatchParty.MediaKind = switch meta.type {
        case "movie": .movie
        case "episode": .episode
        default: .video
        }
        let index = meta.index.map(Int64.init)
        let fallback = index.map { String(localized: "Episode \($0)") } ?? String(localized: "Untitled")
        let title = (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var series: Series?
        if kind == .episode {
            series = Series(
                title: show?.title ?? meta.grandparentTitle ?? fallback,
                year: show?.year.map(Int64.init),
                ids: ids(fromPlexGuid: show?.guid ?? meta.grandparentGuid, guids: (show?.Guid ?? []).compactMap(\.id)))
        }
        return Media(
            kind: kind,
            title: title.isEmpty ? fallback : title,
            durationMs: durationMs,
            year: meta.year.map(Int64.init),
            ids: ids(fromPlexGuid: meta.guid, guids: (meta.Guid ?? []).compactMap(\.id)),
            series: series,
            season: kind == .episode ? meta.parentIndex.map(Int64.init) : nil,
            episode: kind == .episode ? index : nil,
            ext: server.flatMap { server in meta.ratingKey.map { ext(server: server, item: $0) } })
    }

    /// What `work` finds before `limit`, or nil. The SDK gives a resolver 30 s in
    /// total, and a server that is off must not use all of it.
    nonisolated static func within<T: Sendable>(_ limit: Duration,
                                                _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Lower case, with runs of anything but letters and digits as one space.
    nonisolated static func foldedTitle(_ title: String) -> String {
        title.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// Some catalogue both sides are in names a different title.
    nonisolated static func idsConflict(_ a: [String: String], _ b: [String: String]) -> Bool {
        a.contains { key, value in b[key].map { $0 != value } ?? false }
    }

    /// A title match: same words, years at most one apart, no id saying otherwise.
    nonisolated static func sameTitle(_ title: String, year: Int?, ids: [String: String],
                                      as otherTitle: String, year otherYear: Int?, ids otherIDs: [String: String]) -> Bool {
        guard foldedTitle(title) == foldedTitle(otherTitle), !idsConflict(ids, otherIDs) else { return false }
        guard let year, let otherYear else { return true }
        return abs(year - otherYear) <= 1
    }
}
