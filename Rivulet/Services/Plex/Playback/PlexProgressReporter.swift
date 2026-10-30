// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProgressReporter.swift
//  Rivulet
//
//  Reports playback progress to Plex server for timeline tracking
//

import Foundation

/// Reports playback progress and watch status to Plex server
actor PlexProgressReporter {
    static let shared = PlexProgressReporter()

    private var lastReportedTimes: [String: TimeInterval] = [:]
    private var lastReportedStates: [String: String] = [:]
    /// Play session per server|ratingKey for a direct-play item; its timeline carries the id.
    private var directPlaySessions: [String: String] = [:]

    private init() {}

    /// Seconds of playback that must pass before the same state is re-reported.
    static let reportThrottle: TimeInterval = 5

    /// Whether a timeline report is worth sending.
    ///
    /// A changed `state` always gets through, whatever the position. The
    /// throttle is measured in PLAYBACK time, which stops advancing the moment
    /// the user pauses, so a paused report sits at the same position as the
    /// playing report before it: gating on position alone swallowed it and left
    /// the server believing the item was still playing. The "stopped" report at
    /// an episode transition was dropped the same way, landing within a few
    /// seconds of the last periodic one.
    static func shouldReport(state: String,
                             time: TimeInterval,
                             lastState: String?,
                             lastTime: TimeInterval?,
                             force: Bool) -> Bool {
        // A session must open with "playing": a "paused" first (the engine
        // holds paused while loading) makes Plex fire media.pause and never media.play (#433).
        if state == "paused" && (lastState == nil || lastState == "stopped") { return false }
        if force { return true }
        if lastState != state { return true }
        guard let lastTime else { return true }
        return abs(time - lastTime) >= reportThrottle
    }

    // MARK: - Progress Reporting

    /// Reports current playback position to Plex
    /// - Parameters:
    ///   - ratingKey: The Plex rating key for the media item
    ///   - time: Current playback time in seconds
    ///   - duration: Total duration in seconds
    ///   - state: Playback state ("playing", "paused", "stopped")
    ///   - forceReport: If true, bypasses throttle to report immediately (for state changes)
    /// - Returns: The server's reason when it has ended this play session (#403), else nil.
    @discardableResult
    func reportProgress(
        ratingKey: String,
        time: TimeInterval,
        duration: TimeInterval,
        state: String,
        forceReport: Bool = false,
        server explicit: PlexServerAddress? = nil
    ) async -> String? {
        guard !ratingKey.isEmpty else { return nil }
        guard let server = await server(explicit) else { return nil }
        // Keyed by server too: two servers can share a ratingKey.
        let key = server.address + "|" + ratingKey

        guard Self.shouldReport(state: state,
                                time: time,
                                lastState: lastReportedStates[key],
                                lastTime: lastReportedTimes[key],
                                force: forceReport) else { return nil }
        lastReportedTimes[key] = time
        lastReportedStates[key] = state

        let timeMs = Int(time * 1000)
        let durationMs = Int(duration * 1000)

        // Get Plex client identifiers on MainActor
        let clientInfo = await MainActor.run {
            (
                clientId: PlexAPI.clientIdentifier,
                platform: PlexAPI.platform,
                device: PlexAPI.deviceName,
                product: PlexAPI.productName
            )
        }

        // Build timeline URL with all required parameters
        var components = URLComponents(string: "\(server.address)/:/timeline")
        components?.queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "duration", value: String(durationMs)),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: clientInfo.clientId),
            URLQueryItem(name: "X-Plex-Platform", value: clientInfo.platform),
            URLQueryItem(name: "X-Plex-Device", value: clientInfo.device),
            URLQueryItem(name: "X-Plex-Product", value: clientInfo.product)
        ]
        if let session = directPlaySessions[key] {
            components?.queryItems?.append(URLQueryItem(name: "X-Plex-Session-Identifier", value: session))
            if state == "stopped" { directPlaySessions[key] = nil }
        }

        guard let url = components?.url else { return nil }

        do {
            let data = try await PlexNetworkManager.shared.requestData(
                url,
                method: "GET",
                headers: ["X-Plex-Token": server.token, "Accept": "application/json"]
            )
            return PlexNetworkManager.timelineTermination(in: data)
        } catch {
            playerDebugLog("📊 PlexProgress: Failed to report progress: \(error)")
            return nil
        }
    }

    /// Opens a Plex play session for a file the engine plays directly, so the
    /// server dashboard shows its bandwidth (#423). The item's next "stopped" report ends it.
    func beginDirectPlaySession(ratingKey: String, mediaIndex: Int, server explicit: PlexServerAddress? = nil) async {
        guard !ratingKey.isEmpty, let server = await server(explicit) else { return }
        let session = UUID().uuidString
        directPlaySessions[server.address + "|" + ratingKey] = session
        await PlexNetworkManager.shared.openDirectPlaySession(
            serverURL: server.address, authToken: server.token, ratingKey: ratingKey,
            mediaIndex: mediaIndex, sessionIdentifier: session)
    }

    /// Drops the direct-play session when the item moves onto a server transcode.
    func endDirectPlaySession(ratingKey: String, server explicit: PlexServerAddress? = nil) async {
        guard let server = await server(explicit) else { return }
        directPlaySessions[server.address + "|" + ratingKey] = nil
    }

    /// Marks an item as fully watched (scrobble)
    /// - Parameter ratingKey: The Plex rating key for the media item
    func markAsWatched(ratingKey: String, server explicit: PlexServerAddress? = nil) async {
        guard !ratingKey.isEmpty else { return }
        guard let server = await server(explicit) else { return }

        let urlString = "\(server.address)/:/scrobble?identifier=com.plexapp.plugins.library&key=\(ratingKey)"

        guard let url = URL(string: urlString) else { return }

        do {
            _ = try await PlexNetworkManager.shared.requestData(
                url,
                method: "GET",
                headers: ["X-Plex-Token": server.token]
            )
        } catch {
            playerDebugLog("📊 PlexProgress: Failed to mark as watched: \(error)")
        }
    }

    /// Marks an item as unwatched
    /// - Parameter ratingKey: The Plex rating key for the media item
    func markAsUnwatched(ratingKey: String, server explicit: PlexServerAddress? = nil) async {
        guard !ratingKey.isEmpty else { return }
        guard let server = await server(explicit) else { return }

        let urlString = "\(server.address)/:/unscrobble?identifier=com.plexapp.plugins.library&key=\(ratingKey)"

        guard let url = URL(string: urlString) else { return }

        do {
            _ = try await PlexNetworkManager.shared.requestData(
                url,
                method: "GET",
                headers: ["X-Plex-Token": server.token]
            )
        } catch {
            playerDebugLog("📊 PlexProgress: Failed to mark as unwatched: \(error)")
        }
    }

    // MARK: - Helpers

    /// The item's own server when the caller knows it (the player does), else the selected one.
    private func server(_ explicit: PlexServerAddress?) async -> PlexServerAddress? {
        if let explicit { return explicit }
        return await MainActor.run {
            let authManager = PlexAuthManager.shared
            guard let address = authManager.selectedServerURL,
                  let token = authManager.selectedServerToken else {
                return nil
            }
            return PlexServerAddress(address: address, token: token)
        }
    }
}

/// A Plex server's base URL and the token for it.
struct PlexServerAddress: Sendable {
    let address: String
    let token: String
}
