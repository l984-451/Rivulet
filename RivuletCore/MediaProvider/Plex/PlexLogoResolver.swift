// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import os

/// Finds a title's clear logo for hub and episode items, whose responses carry no `Image` array.
/// Hits and misses are kept per server and key; concurrent asks for one key share a request.
/// A miss is Plex answering that the title has no clear logo: a failed or cancelled fetch is asked again.
nonisolated final class PlexLogoResolver: @unchecked Sendable {
    /// What one metadata fetch found.
    private enum Outcome { case found(URL), none, failed }

    private struct State {
        var urls: [String: URL] = [:]
        var misses: Set<String> = []
        var tasks: [String: Task<Outcome, Never>] = [:]
        /// Bumped by `reset()`, so a fetch started before it writes nothing into the state after it.
        var generation = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The logo if `logo(...)` already found it, so a view can draw it on its first frame.
    func cached(serverURL: String, sourceKey: String) -> URL? {
        state.withLock { $0.urls["\(serverURL)|\(sourceKey)"] }
    }

    /// `sourceKey` is the rating key of the movie, show (for an episode or season) that owns the logo.
    /// `direct` is the logo URL the item already holds, used as is with no request.
    func logo(serverURL: String, token: String, network: PlexNetworkManager, sourceKey: String, direct: URL?) async -> URL? {
        // Rating keys repeat across servers, so the cache is per server.
        let key = "\(serverURL)|\(sourceKey)"
        enum Step { case done(URL?), wait(Task<Outcome, Never>) }
        let step = state.withLock { state -> Step in
            if let url = state.urls[key] { return .done(url) }
            if state.misses.contains(key) { return .done(nil) }
            if let direct { state.urls[key] = direct; return .done(direct) }
            if let running = state.tasks[key] { return .wait(running) }
            let generation = state.generation
            let task = Task<Outcome, Never> { [weak self] in
                let outcome = await Self.fetch(serverURL: serverURL, token: token, network: network, sourceKey: sourceKey)
                self?.settle(key, outcome, generation: generation)
                return outcome
            }
            state.tasks[key] = task
            return .wait(task)
        }
        switch step {
        case .done(let url): return url
        case .wait(let task):
            if case .found(let url) = await task.value { return url }
            return nil
        }
    }

    private static func fetch(serverURL: String, token: String, network: PlexNetworkManager, sourceKey: String) async -> Outcome {
        guard let metadata = try? await network.getMetadata(serverURL: serverURL, authToken: token, ratingKey: sourceKey)
        else { return .failed }
        return directURL(serverURL: serverURL, token: token, path: metadata.clearLogoPath).map(Outcome.found) ?? .none
    }

    private func settle(_ key: String, _ outcome: Outcome, generation: Int) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.tasks[key] = nil
            switch outcome {
            case .found(let url): state.urls[key] = url
            case .none: state.misses.insert(key)
            case .failed: break
            }
        }
    }

    func reset() {
        let running = state.withLock { state -> [Task<Outcome, Never>] in
            let tasks = Array(state.tasks.values)
            let next = state.generation + 1
            state = State()
            state.generation = next
            return tasks
        }
        running.forEach { $0.cancel() }
    }

    /// Direct, authenticated URL for transparent assets such as clear logos.
    /// The photo transcoder can flatten their alpha channel, so these skip it.
    static func directURL(serverURL: String, token: String, path: String?) -> URL? {
        guard let path, !path.isEmpty,
              let base = URL(string: serverURL),
              let absolute = URL(string: path, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // An absolute path on another host (a metadata CDN) must not receive the token.
        guard absolute.host == base.host else { return absolute }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "X-Plex-Token" }) {
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = queryItems
        return components.url
    }
}
