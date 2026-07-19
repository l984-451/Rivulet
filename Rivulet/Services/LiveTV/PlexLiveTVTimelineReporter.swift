// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Owns the Plex `/:/timeline` lifecycle for one tuned Live TV session.
/// The report both keeps the tuner grab alive and gives Plex Dashboard the
/// programme, client, playback state, and stream-session identity it displays
/// for VOD sessions.
@MainActor
final class PlexLiveTVTimelineReporter {
    private struct Context {
        let serverURL: String
        let authToken: String
        let sessionPath: String
        let sessionIdentifier: String
    }

    private let channel: UnifiedChannel
    private var context: Context?
    private var heartbeatTask: Task<Void, Never>?
    private var state = "playing"

    init(channel: UnifiedChannel) {
        self.channel = channel
    }

    func start(url: URL) {
        stop()
        guard channel.sourceType == .plex,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?
                .first(where: { $0.name == "X-Plex-Token" })?.value,
              let sessionIdentifier = components.queryItems?
                .first(where: { $0.name == "X-Plex-Session-Identifier" })?.value,
              let scheme = components.scheme,
              let host = components.host,
              let sessionPath = Self.sessionPath(from: url, components: components) else {
            return
        }

        let port = components.port.map { ":\($0)" } ?? ""
        context = Context(
            serverURL: "\(scheme)://\(host)\(port)",
            authToken: token,
            sessionPath: sessionPath,
            sessionIdentifier: sessionIdentifier
        )
        state = "playing"

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.report(state: self.state)
            }
        }
    }

    func setState(_ newState: String) {
        guard context != nil, state != newState || newState == "playing" else { return }
        state = newState
        report(state: newState)
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if context != nil {
            report(state: "stopped")
        }
        context = nil
    }

    private func report(state: String) {
        guard let context else { return }

        let program = LiveTVDataStore.shared.getCurrentProgram(for: channel)
        let now = Date()
        let positionMs: Int
        let durationMs: Int
        if let program {
            positionMs = max(0, Int(now.timeIntervalSince(program.startTime) * 1000))
            let scheduledDuration = max(0, Int(program.endTime.timeIntervalSince(program.startTime) * 1000))
            // PMS rejects Live TV reports where time exceeds duration.
            durationMs = max(scheduledDuration, positionMs)
        } else {
            positionMs = 0
            durationMs = 0
        }

        guard var components = URLComponents(string: "\(context.serverURL)/:/timeline") else {
            return
        }
        var items = [
            URLQueryItem(name: "key", value: context.sessionPath),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "time", value: "\(positionMs)"),
            URLQueryItem(name: "duration", value: "\(durationMs)"),
            URLQueryItem(name: "playbackTime", value: "\(positionMs)"),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: context.sessionIdentifier),
        ]
        if let ratingKey = program?.sourceProgramId, !ratingKey.isEmpty {
            items.insert(URLQueryItem(name: "ratingKey", value: ratingKey), at: 0)
        }
        components.queryItems = items
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(context.authToken, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(PlexAPI.deviceName, forHTTPHeaderField: "X-Plex-Device")
        request.setValue(context.sessionIdentifier, forHTTPHeaderField: "X-Plex-Session-Identifier")

        Task.detached(priority: .utility) {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    playerDebugLog("📺 Plex Live TV timeline returned HTTP \(http.statusCode)")
                }
            } catch {
                playerDebugLog("📺 Plex Live TV timeline failed: \(error.localizedDescription)")
            }
        }
    }

    private static func sessionPath(from url: URL, components: URLComponents) -> String? {
        if url.path.hasPrefix("/livetv/sessions/") {
            let parts = url.path.split(separator: "/")
            guard parts.count >= 3 else { return nil }
            return "/livetv/sessions/\(parts[2])"
        }
        return components.queryItems?
            .first(where: { $0.name == "path" })?.value
            .flatMap { $0.hasPrefix("/livetv/sessions/") ? $0 : nil }
    }
}
