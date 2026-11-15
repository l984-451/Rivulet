// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AetherEngine
import Combine
import Foundation

/// Plays a music track AVPlayer cannot decode (TrueHD, DTS, Opus...) through
/// AetherEngine's audio-only mode (#544). The only music file naming an engine type.
/// It publishes no Now Playing: `.software` sends every source to the engine's
/// FFmpeg host, which has none, so `MusicNowPlayingBridge` stays the one publisher.
@MainActor
final class MusicEngineTrack {
    var onState: ((MusicPlayerState) -> Void)?
    var onTime: ((TimeInterval) -> Void)?
    var onDuration: ((TimeInterval) -> Void)?

    private var engine: AetherEngine?
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?

    var currentTime: TimeInterval { engine?.clock.currentTime ?? 0 }

    var volume: Float {
        get { engine?.volume ?? 1 }
        set { engine?.volume = newValue }
    }

    /// Starts the track. `onFailure` runs when the engine cannot open it.
    func load(url: URL, headers: [String: String], onFailure: @escaping () -> Void) {
        stop()
        // The engine otherwise trusts the system alone, so a raw-IP Plex server would not play (#337).
        EngineTLS.serverTrustEvaluator = { PlexCertificateDelegate.trustsServer($0) }
        let engine: AetherEngine
        do {
            engine = try self.engine ?? AetherEngine()
        } catch {
            print("[MusicEngineTrack] engine init failed: \(error)")
            return onFailure()
        }
        self.engine = engine

        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .loading: self?.onState?(.loading)
                case .playing: self?.onState?(.playing)
                case .paused: self?.onState?(.paused)
                case .ended: self?.onState?(.ended)
                case .error(let message):
                    print("[MusicEngineTrack] \(message)")
                    self?.onState?(.idle)
                default: break  // idle is ours to report; a seek keeps the state under it
                }
            }
            .store(in: &cancellables)
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onTime?($0) }
            .store(in: &cancellables)
        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onDuration?($0) }
            .store(in: &cancellables)

        onState?(.loading)
        loadTask = Task { @MainActor in
            do {
                var options = LoadOptions(httpHeaders: headers, audioOnly: true)
                options.preferredDecodePath = .software
                _ = try await engine.load(url: url, options: options)
                guard !Task.isCancelled else { return }
                engine.play()
            } catch {
                guard !Task.isCancelled else { return }
                print("[MusicEngineTrack] load failed: \(error)")
                onFailure()
            }
        }
    }

    func play() { engine?.play() }
    func pause() { engine?.pause() }

    func seek(to time: TimeInterval) async { await engine?.seek(to: time) }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        cancellables.removeAll()
        engine?.stop()
    }
}
