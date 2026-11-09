// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicPlayer.swift
//  Rivulet
//
//  Audio-only player for music: AVQueuePlayer, or the engine for codecs
//  AVPlayer cannot decode (#544). Handles sweet fades and audio session.
//

import Foundation
import AVFoundation
import Combine

/// Internal state for the music player
enum MusicPlayerState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case ended
}

/// Audio-only player backed by AVQueuePlayer, or by `MusicEngineTrack` for a track
/// whose codec AVPlayer cannot decode. Handles volume fading and audio session management.
@MainActor
final class MusicPlayer: ObservableObject {

    // MARK: - Published State

    @Published var state: MusicPlayerState = .idle
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    // MARK: - Private State

    private var player: AVQueuePlayer?
    private var currentItem: AVPlayerItem?
    private var nextItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var didPlayToEndObserver: NSObjectProtocol?
    private var fadeTimer: Timer?
    private var seekTarget: TimeInterval?
    private let engineTrack = MusicEngineTrack()
    private var usesEngine = false

    /// Sweet fade duration for pause/resume
    private let sweetFadeDuration: TimeInterval = 0.3

    // MARK: - Initialization

    init() {
        engineTrack.onState = { [weak self] in self?.state = $0 }
        engineTrack.onDuration = { [weak self] in self?.duration = $0 }
        engineTrack.onTime = { [weak self] time in
            // A seek in flight still reports the position it left.
            if let self, self.seekTarget == nil { self.currentTime = time }
        }
    }

    // MARK: - Playback Controls

    /// Load and play an audio URL. `useEngine` sends it to AetherEngine, for codecs AVPlayer cannot decode.
    func load(url: URL, headers: [String: String], useEngine: Bool = false) {
        cleanUp()

        // Configure audio session
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .default,
            owner: "MusicPlayer"
        )

        if useEngine { return loadEngine(url: url, headers: headers) }

        // Create asset with headers
        let assetOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        currentItem = item

        let queuePlayer = AVQueuePlayer(items: [item])
        queuePlayer.actionAtItemEnd = .advance
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        self.player = queuePlayer

        state = .loading

        // Observe item status
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.duration = item.duration.seconds.isNaN ? 0 : item.duration.seconds
                    self.state = .playing
                    self.player?.play()
                case .failed:
                    print("🎵 MusicPlayer: Item failed: \(item.error?.localizedDescription ?? "unknown")")
                    // A codec not on the engine list that AVPlayer still refused: the engine may play it.
                    self.cleanUp()
                    self.loadEngine(url: url, headers: headers)
                default:
                    break
                }
            }
        }

        // Observe playback end
        didPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only handle if it's our current item (not the queued next item becoming current)
                if item == self.currentItem {
                    self.state = .ended
                }
            }
        }

        // Time observer for progress tracking
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = queuePlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                // A seek in flight still reports the position it left.
                if self.seekTarget == nil, !seconds.isNaN && !seconds.isInfinite {
                    self.currentTime = seconds
                }
            }
        }
    }

    private func loadEngine(url: URL, headers: [String: String]) {
        usesEngine = true
        state = .loading
        engineTrack.load(url: url, headers: headers) { [weak self] in self?.state = .idle }
    }

    /// Prepare the next track for gapless playback
    func prepareNext(url: URL, headers: [String: String]) {
        let assetOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        nextItem = item

        // Insert into queue for gapless transition
        if let player, player.canInsert(item, after: nil) {
            player.insert(item, after: nil)
        }
    }

    func play() {
        guard usesEngine || player != nil else { return }
        // Sweet fade in
        outputVolume = 0
        if usesEngine { engineTrack.play() } else { player?.play() }
        state = .playing
        fadeVolume(to: 1.0)
    }

    func pause() {
        guard usesEngine || player != nil else { return }
        // Sweet fade out then pause
        fadeVolume(to: 0) { [weak self] in
            guard let self else { return }
            if self.usesEngine { self.engineTrack.pause() } else { self.player?.pause() }
            self.state = .paused
        }
    }

    func stop() {
        player?.pause()
        cleanUp()
        state = .idle
    }

    func seek(to time: TimeInterval) {
        if usesEngine {
            seekTarget = time
            Task {
                await engineTrack.seek(to: time)
                if seekTarget == time { seekTarget = nil }
            }
            return
        }
        guard let player else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        seekTarget = time
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                // A newer seek owns the target by now if it differs.
                if self?.seekTarget == time { self?.seekTarget = nil }
            }
        }
    }

    /// The player's own clock, read now: `currentTime` only ticks twice a second.
    var playbackTime: TimeInterval {
        // A seek in flight still reports the position it left.
        if let seekTarget { return seekTarget }
        if usesEngine { return engineTrack.currentTime }
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return currentTime }
        return seconds
    }

    // MARK: - Volume Fading

    private var outputVolume: Float {
        get { usesEngine ? engineTrack.volume : player?.volume ?? 1 }
        set { if usesEngine { engineTrack.volume = newValue } else { player?.volume = newValue } }
    }

    private func fadeVolume(to target: Float, completion: (() -> Void)? = nil) {
        fadeTimer?.invalidate()

        let startVolume = outputVolume
        let steps = 15
        let stepDuration = sweetFadeDuration / Double(steps)
        let volumeStep = (target - startVolume) / Float(steps)
        var currentStep = 0

        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                currentStep += 1
                if currentStep >= steps {
                    self.outputVolume = target
                    timer.invalidate()
                    completion?()
                } else {
                    self.outputVolume = startVolume + volumeStep * Float(currentStep)
                }
            }
        }
    }

    // MARK: - Cleanup

    private func cleanUp() {
        fadeTimer?.invalidate()
        fadeTimer = nil

        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        statusObserver?.invalidate()
        statusObserver = nil

        if let observer = didPlayToEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        didPlayToEndObserver = nil

        engineTrack.stop()
        usesEngine = false
        player?.removeAllItems()
        player = nil
        currentItem = nil
        nextItem = nil
        seekTarget = nil
        currentTime = 0
        duration = 0
    }
}
