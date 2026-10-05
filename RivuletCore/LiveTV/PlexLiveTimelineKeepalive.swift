// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Keeps a tuned Plex Live TV session alive via `/:/timeline` pings.
///
/// PMS runs each live grab as a rolling subscription with a 300-second
/// stop-grab timer; a timeline report referencing the session resets it
/// (verified: an unreported session dies within minutes, a reported one
/// survives and `state=stopped` releases it immediately).
///
/// Cadence and parameters follow the working-client consensus:
///  - 10s heartbeat, with the FIRST ping delayed 3s — an immediate ping can
///    make the server spawn a duplicate transcode job that 404s.
///  - `ratingKey` is the NUMERIC live-session metadata id from the tune
///    response (EPG-style plex:// keys 404 on this endpoint). Carried on the
///    resolved URL as `rivuletLiveRatingKey` (PMS ignores unknown params).
///  - `time=0&duration=0&playbackTime=<elapsed ms>` — sidesteps the server's
///    "time may not exceed duration" rejection entirely.
///  - `state=stopped` on stop() releases the tuner without waiting for the
///    timeout, and a start.m3u8 session's transcode job is stopped after it.
///
/// Every teardown path (full-screen player, multiview slot, channel zap,
/// fallback re-tune, abandoned tune) ends here, so the release lives here once.
@MainActor
final class PlexLiveTimelineKeepalive {

    /// Sends one request and returns once the server has answered.
    typealias Transport = @MainActor (URLRequest) async -> Void

    static let transcodeStopPath = "/video/:/transcode/universal/stop"

    private struct Context {
        let serverURL: String
        let authToken: String
        let sessionPath: String
        let sessionIdentifier: String?
        let ratingKey: String?
        /// `session` of a universal-transcoder URL. nil on the raw session
        /// playlist a direct-play grant returns: no transcoder serves that.
        let transcodeSession: String?
        let startedAt: Date
    }

    private let transport: Transport
    private var context: Context?
    private var heartbeatTask: Task<Void, Never>?
    /// The last request handed to the transport. Each request waits for the
    /// one before it to be answered, so PMS sees them in order: a slow
    /// "playing" can never land after "stopped" and renew the grab.
    private var lastSend: Task<Void, Never>?
    /// Bumped by stop(). A ping still queued behind a slow request is
    /// dropped rather than sent after the stop.
    private var generation = 0

    init(transport: @escaping Transport = PlexLiveTimelineKeepalive.send) {
        self.transport = transport
    }

    /// Begin reporting for the session carried by `url`. No-op (and stops any
    /// previous reporting) when the URL doesn't reference a tuned session.
    /// Accepts both URL forms: the raw session playlist
    /// (/livetv/sessions/{uuid}/{consumer}/index.m3u8) and the universal
    /// transcoder (start.m3u8?path=/livetv/sessions/{uuid}).
    func start(url: URL) {
        stop()

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host,
              let token = components.queryItems?
                  .first(where: { $0.name == "X-Plex-Token" })?.value,
              let sessionPath = Self.sessionPath(from: url, components: components) else {
            return
        }

        let port = components.port.map { ":\($0)" } ?? ""
        let isTranscode = url.path.hasPrefix("/video/:/transcode/universal/")
        context = Context(
            serverURL: "\(scheme)://\(host)\(port)",
            authToken: token,
            sessionPath: sessionPath,
            sessionIdentifier: components.queryItems?
                .first(where: { $0.name == "X-Plex-Session-Identifier" })?.value,
            ratingKey: components.queryItems?
                .first(where: { $0.name == "rivuletLiveRatingKey" })?.value,
            transcodeSession: isTranscode
                ? components.queryItems?.first(where: { $0.name == "session" })?.value
                : nil,
            startedAt: Date()
        )

        heartbeatTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                // One ping in flight at a time: the next waits out a slow answer.
                guard let ping = self?.ping() else { return }
                await ping.value
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Releases a session nobody will play: a tune that finished after the
    /// player or tile that asked for it had gone. No-op for any other URL.
    static func release(_ url: URL) {
        let keepalive = PlexLiveTimelineKeepalive()
        keepalive.start(url: url)
        keepalive.stop()
    }

    /// Final "stopped" report + heartbeat teardown. Releases the tuner
    /// server-side without waiting for the 300s timeout, then stops the
    /// transcode job a start.m3u8 session runs.
    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        generation += 1
        guard let context else { return }
        self.context = nil
        enqueue(timelineRequest(context, state: "stopped"))
        if let session = context.transcodeSession {
            enqueue(request(context, path: Self.transcodeStopPath,
                            items: [URLQueryItem(name: "session", value: session)]))
        }
    }

    /// One "playing" report. The heartbeat is its only caller in the app;
    /// internal so tests can drive it without waiting on the clock.
    @discardableResult
    func ping() -> Task<Void, Never>? {
        guard let context else { return nil }
        return enqueue(timelineRequest(context, state: "playing"), unlessStoppedSince: generation)
    }

    @discardableResult
    private func enqueue(_ request: URLRequest?, unlessStoppedSince generation: Int? = nil) -> Task<Void, Never>? {
        guard let request else { return nil }
        let previous = lastSend
        let task = Task { [weak self, transport] in
            await previous?.value
            if let generation, self?.generation != generation { return }
            await transport(request)
        }
        lastSend = task
        return task
    }

    private func timelineRequest(_ context: Context, state: String) -> URLRequest? {
        let elapsedMs = max(0, Int(Date().timeIntervalSince(context.startedAt) * 1000))
        var items = [
            URLQueryItem(name: "key", value: context.sessionPath),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "time", value: "0"),
            URLQueryItem(name: "duration", value: "0"),
            URLQueryItem(name: "playbackTime", value: "\(elapsedMs)"),
        ]
        if let ratingKey = context.ratingKey {
            items.insert(URLQueryItem(name: "ratingKey", value: ratingKey), at: 0)
        }
        if let sessionIdentifier = context.sessionIdentifier {
            items.append(URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier))
        }
        return request(context, path: "/:/timeline", items: items)
    }

    private func request(_ context: Context, path: String, items: [URLQueryItem]) -> URLRequest? {
        guard var components = URLComponents(string: "\(context.serverURL)\(path)") else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        // Requests run one at a time, so a hung ping must not hold the
        // "stopped" behind it for URLSession's default 60 s.
        request.timeoutInterval = 10
        request.setValue(context.authToken, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")
        return request
    }

    static func send(_ request: URLRequest) async {
        let path = request.url?.path ?? ""
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status != 200 else { return }
            // A 404 on the stop means the job had already ended: done either way.
            if status == 404, path == transcodeStopPath { return }
            playerDebugLog("📺 Live \(path) returned HTTP \(status)")
        } catch {
            playerDebugLog("📺 Live \(path) failed: \(error.localizedDescription)")
        }
    }

    private static func sessionPath(from url: URL, components: URLComponents) -> String? {
        if url.path.hasPrefix("/livetv/sessions/") {
            let parts = url.path.split(separator: "/")  // [livetv, sessions, uuid, …]
            guard parts.count >= 3 else { return nil }
            return "/livetv/sessions/\(parts[2])"
        }
        if let queryPath = components.queryItems?.first(where: { $0.name == "path" })?.value,
           queryPath.hasPrefix("/livetv/sessions/") {
            return queryPath
        }
        return nil  // Not a tuned Plex session — nothing to keep alive.
    }
}
