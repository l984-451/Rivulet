// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveStreamProber.swift
//  Rivulet
//
//  Measures channels nobody has played yet, so a channel list can say what each
//  stream is ("1080p · Stereo"). One stream at a time, only the channels asked
//  for (the rows on screen), only while the asking page says nothing plays,
//  and only the first seconds of each: a provider counts every open stream
//  against the account's connections. A Plex tuner is never opened. Results
//  go to `LiveStreamQualityStore`, as the player's own do.
//

import Foundation

@MainActor
final class LiveStreamProber {
    static let shared = LiveStreamProber()

    /// Sources whose streams may be opened just to look: a playlist entry, not a tuner.
    static let probedSources: Set<LiveTVSourceType> = [.xtream, .genericM3U, .dispatcharr]

    private var queue: [UnifiedChannel] = []
    /// Channels that gave nothing this session; not asked again until relaunch.
    private var failed: Set<String> = []
    private var loop: Task<Void, Never>?
    /// Which loop is the current one.
    private var generation = 0
    private var canRun: () -> Bool = { false }
    private let store: LiveStreamQualityStore
    private let fetch: @Sendable (URL, [String: String]) async -> StreamHeaderProbe.Result?

    init(store: LiveStreamQualityStore? = nil,
         fetch: @escaping @Sendable (URL, [String: String]) async -> StreamHeaderProbe.Result? = LiveStreamProber.read) {
        self.store = store ?? .shared
        self.fetch = fetch
    }

    /// Measures these channels, in order, those with no picture size yet (the player could
    /// note the sound alone). Replaces what was
    /// waiting: the rows on screen are what matter. `canRun` is asked before each stream.
    func probe(_ channels: [UnifiedChannel], while canRun: @escaping () -> Bool) {
        self.canRun = canRun
        queue = channels.filter { channel in
            Self.probedSources.contains(channel.sourceType) && channel.streamURL != nil
                && store.quality(for: channel.id)?.height == nil && !failed.contains(channel.id)
        }
        guard loop == nil, !queue.isEmpty else { return }
        generation += 1
        let mine = generation
        loop = Task { [weak self] in
            await self?.run()
            // Only its own: a stopped loop finishing late must not forget a newer one,
            // or the next probe would start a second loop beside it.
            if self?.generation == mine { self?.loop = nil }
        }
    }

    /// Stops now, a stream in flight included: something is about to play.
    func stop() {
        queue = []
        generation += 1
        loop?.cancel()
        loop = nil
    }

    /// Whether a loop is running; for tests.
    var isRunning: Bool { loop != nil }

    private func run() async {
        while !Task.isCancelled, canRun(), !queue.isEmpty {
            let channel = queue.removeFirst()
            guard let url = channel.streamURL else { continue }
            let found = await fetch(url, LiveTVClientIdentity.streamHeaders(for: channel))
            guard !Task.isCancelled else { return }
            if let found, found.height != nil || found.audioChannels != nil {
                store.record(channelId: channel.id, height: found.height, audioChannels: found.audioChannels)
            } else {
                failed.insert(channel.id)
            }
            // A pause between streams, so a provider never sees a burst of connections.
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    // MARK: - Reading a stream

    /// The most of a stream read for one channel, and for how long.
    nonisolated static let byteLimit = 2_500_000
    nonisolated static let timeLimit: Duration = .seconds(6)

    /// The stream's header facts: an HLS playlist's attributes (following a master to its
    /// first media playlist and segment when they say too little), else the transport stream.
    nonisolated static func read(_ url: URL, headers: [String: String]) async -> StreamHeaderProbe.Result? {
        var target = url
        var result = StreamHeaderProbe.Result()
        for _ in 0..<3 {
            guard let (data, isPlaylist) = await download(target, headers: headers) else { return nil }
            guard isPlaylist, let text = String(data: data, encoding: .utf8) else {
                let stream = StreamHeaderProbe.transportStream(data)
                return StreamHeaderProbe.Result(height: result.height ?? stream.height,
                                                audioChannels: result.audioChannels ?? stream.audioChannels)
            }
            let listed = StreamHeaderProbe.playlist(text)
            result.height = result.height ?? listed.height
            result.audioChannels = result.audioChannels ?? listed.audioChannels
            guard !result.isComplete, let next = StreamHeaderProbe.firstURI(in: text, base: target) else { return result }
            target = next
        }
        return result
    }

    /// The first bytes at `url`, stopped at the byte or time limit, and whether they are a playlist.
    private nonisolated static func download(_ url: URL, headers: [String: String]) async -> (Data, Bool)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = LiveTVClientIdentity.streamHeaders
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now + timeLimit
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            var data = Data()
            data.reserveCapacity(256_000)
            var isPlaylist: Bool?
            for try await byte in bytes {
                data.append(byte)
                if isPlaylist == nil, data.count >= 7 {
                    isPlaylist = data.starts(with: Array("#EXTM3U".utf8))
                }
                if data.count % 65_536 == 0 {
                    if Task.isCancelled || ContinuousClock.now > deadline { break }
                    // A transport stream is read only until it says both things.
                    if isPlaylist == false, data.count % 262_144 == 0,
                       StreamHeaderProbe.transportStream(data).isComplete { break }
                }
                if data.count >= byteLimit { break }
            }
            return data.isEmpty ? nil : (data, isPlaylist ?? false)
        } catch {
            return nil
        }
    }
}
