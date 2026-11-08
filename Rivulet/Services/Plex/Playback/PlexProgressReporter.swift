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

    enum ProgressResult: Sendable {
        case sent(termination: String?)
        case skipped
        case failed(TimelineReport?)
    }

    struct TimelineReport: Sendable {
        fileprivate let url: URL
        fileprivate let headers: [String: String]
        fileprivate let key: String
        fileprivate let session: String?
        fileprivate let time: TimeInterval
        fileprivate let state: String
    }

    private var lastReportedTimes: [String: TimeInterval] = [:]
    private var lastReportedStates: [String: String] = [:]
    /// Play session per server|ratingKey, shared by stream requests and timeline reports.
    private var playbackSessions: [String: String] = [:]

    private let request: @Sendable (URL, [String: String]) async throws -> Data

    init(request: @escaping @Sendable (URL, [String: String]) async throws -> Data = { url, headers in
        try await PlexNetworkManager.shared.requestData(url, method: "GET", headers: headers)
    }) {
        self.request = request
    }

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
    /// - Returns: Delivery status and the server's termination reason, if any (#403).
    @discardableResult
    func reportProgress(
        ratingKey: String,
        time: TimeInterval,
        duration: TimeInterval,
        state: String,
        forceReport: Bool = false,
        sessionIdentifier: String? = nil,
        server explicit: PlexServerAddress? = nil
    ) async -> ProgressResult {
        guard !ratingKey.isEmpty else { return .failed(nil) }
        guard let server = await server(explicit) else { return .failed(nil) }
        // Keyed by server too: two servers can share a ratingKey.
        let key = server.address + "|" + ratingKey
        let session = sessionIdentifier ?? playbackSessions[key]
        let isCurrentSession = session == playbackSessions[key]

        guard Self.shouldReport(state: state,
                                time: time,
                                lastState: isCurrentSession ? lastReportedStates[key] : nil,
                                lastTime: isCurrentSession ? lastReportedTimes[key] : nil,
                                force: forceReport) else { return .skipped }

        let durationMs = Self.milliseconds(duration)
        let positionMs = Self.milliseconds(time)
        let timeMs = durationMs > 0 ? min(positionMs, durationMs) : positionMs

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
        if let session {
            components?.queryItems?.append(URLQueryItem(name: "X-Plex-Session-Identifier", value: session))
        }

        guard let url = components?.url else { return .failed(nil) }

        return await send(TimelineReport(url: url, headers: ["X-Plex-Token": server.token, "Accept": "application/json"],
                                         key: key, session: session, time: time, state: state))
    }

    func send(_ report: TimelineReport) async -> ProgressResult {
        let attempts = report.state == "stopped" ? 2 : 1
        for attempt in 1...attempts {
            do {
                let data = try await request(report.url, report.headers)
                if playbackSessions[report.key] == report.session {
                    lastReportedTimes[report.key] = report.time
                    lastReportedStates[report.key] = report.state
                    if report.state == "stopped" { playbackSessions[report.key] = nil }
                }
                let termination = PlexNetworkManager.timelineTermination(in: data)
                return .sent(termination: termination)
            } catch {
                DiagLog.error(.playback, "Plex timeline failed state=\(report.state) attempt=\(attempt) error=\(DiagLog.describe(error))")
                guard attempt < attempts, Self.isTransient(error) else { return .failed(report) }
            }
        }
        return .failed(report)
    }

    func beginPlaybackSession(ratingKey: String, mediaIndex: Int? = nil,
                              sessionIdentifier: String = UUID().uuidString,
                              server explicit: PlexServerAddress? = nil) async {
        guard !ratingKey.isEmpty, let server = await server(explicit) else { return }
        let key = server.address + "|" + ratingKey
        if playbackSessions[key] != sessionIdentifier {
            playbackSessions[key] = sessionIdentifier
            lastReportedTimes[key] = nil
            lastReportedStates[key] = nil
        }
        if let mediaIndex {
            await PlexNetworkManager.shared.openDirectPlaySession(
                serverURL: server.address, authToken: server.token, ratingKey: ratingKey,
                mediaIndex: mediaIndex, sessionIdentifier: sessionIdentifier)
        }
    }

    /// Marks an item as fully watched (scrobble)
    /// - Parameter ratingKey: The Plex rating key for the media item
    @discardableResult
    func markAsWatched(ratingKey: String, server explicit: PlexServerAddress? = nil) async -> Bool {
        guard !ratingKey.isEmpty else { return false }
        guard let server = await server(explicit) else { return false }

        let urlString = "\(server.address)/:/scrobble?identifier=com.plexapp.plugins.library&key=\(ratingKey)"

        guard let url = URL(string: urlString) else { return false }

        do {
            _ = try await request(url, ["X-Plex-Token": server.token])
            return true
        } catch {
            DiagLog.error(.playback, "Plex watched failed item=\(ratingKey) error=\(DiagLog.describe(error))")
            return false
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

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds * 1000, Double(Int.max).nextDown))
    }

    private static func isTransient(_ error: Error) -> Bool {
        if case PlexAPIError.httpError(let status, _) = error {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }

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
