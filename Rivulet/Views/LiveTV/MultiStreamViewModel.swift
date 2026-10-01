// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MultiStreamViewModel.swift
//  Rivulet
//
//  Central state management for multi-stream Live TV playback
//

import Combine
import UIKit
import Sentry

@MainActor
final class MultiStreamViewModel: ObservableObject {

    enum LayoutMode: Equatable {
        case grid
        case focus(mainId: UUID)
    }

    // MARK: - Stream Slot Model

    struct StreamSlot: Identifiable {
        let id = UUID()
        let channel: UnifiedChannel

        let aetherPlayer: AetherPlayer
        /// Timeline keepalive for tuned Plex sessions (no-op for other
        /// sources): each grid slot holds its own tuner grab, and PMS
        /// releases an unreported grab after its 300s rolling timer. A slot
        /// that adopted a running session keeps that session's keepalive.
        var liveKeepalive = PlexLiveTimelineKeepalive()

        var playbackState: UniversalPlaybackState
        var currentProgram: UnifiedProgram?
        var isMuted: Bool
        /// Recovery gave up on this channel; the tile says so. A failure
        /// that is still being retried is not this.
        var isUnavailable = false

        // MARK: - Convenience Accessors

        var isPlaying: Bool {
            aetherPlayer.isPlaying
        }

        var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
            aetherPlayer.playbackStatePublisher
        }

        func play() {
            aetherPlayer.play()
        }

        func pause() {
            aetherPlayer.pause()
        }

        func stop() {
            liveKeepalive.stop()
            aetherPlayer.stop()
        }

        func setMuted(_ muted: Bool) {
            aetherPlayer.setMuted(muted)
        }

        func load(url: URL, headers: [String: String]?) async throws {
            // The same live load the fullscreen player uses, so a tile routes a
            // URL exactly as fullscreen does. The two used to differ: a Plex
            // direct-play grant is an HLS playlist that has to go through the
            // engine's ingest, and a tile handed it to the raw live path, which
            // fails closed on a playlist body (AE#140). Every channel granted
            // direct play then played fullscreen and not in multiview.
            let forceEngineDemux = url.path.hasPrefix("/livetv/sessions/")
            // The keepalive owns the tuned session from before the load, as in
            // the fullscreen player: started after it, a load that failed left
            // its fresh Plex grab unreported and unreleased for 300s, one per
            // retry.
            liveKeepalive.start(url: url)
            do {
                try await aetherPlayer.loadLive(url: url, headers: headers,
                                                forceEngineDemux: forceEngineDemux,
                                                role: .multiviewSlot)
            } catch {
                // A failed load releases its grab now rather than holding it
                // through the retry's backoff.
                liveKeepalive.stop()
                throw error
            }
        }
    }

    // MARK: - Published State

    @Published private(set) var streams: [StreamSlot] = [] {
        didSet {
            guard streams.count != oldValue.count else { return }
            let count = streams.count
            // Crashes and hangs carry how many tiles were running, so four
            // streams (open to everyone, no longer an opt-in) can be watched.
            SentryBridge.configureScope { scope in
                if count == 0 {
                    scope.removeTag(key: "multiview_streams")
                } else {
                    scope.setTag(value: String(count), key: "multiview_streams")
                }
            }
        }
    }
    @Published var focusedSlotIndex: Int = 0
    @Published var layoutMode: LayoutMode = .grid

    // MARK: - Private State

    private var cancellables: [UUID: Set<AnyCancellable>] = [:]
    private var autoRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    /// Each tile's pending For You credit (see `LiveTVDataStore.beganWatching`).
    private var watchCreditTasks: [UUID: Task<Void, Never>] = [:]
    private var stalledStateSince: [UUID: Date] = [:]
    private var recoveryAttempts: [UUID: Int] = [:]
    private var recoveringSlots: Set<UUID> = []
    private var intentionallyStoppedSlots: Set<UUID> = []
    private var healthMonitorTask: Task<Void, Never>?
    /// Retries before a tile gives up and says the channel is unavailable.
    /// Unbounded, a dead source was tuned every 15s for as long as it stayed
    /// on screen.
    private let maxRecoveryAttempts = 5
    private let loadingRecoveryThreshold: TimeInterval = 25
    private let bufferingRecoveryThreshold: TimeInterval = 20
    private let debugId = String(UUID().uuidString.prefix(8))
    // Track active Live TV sessions to manage screensaver correctly
    // Only re-enable screensaver when ALL sessions are closed
    private static var activeSessionCount = 0
    private var didDecrementSessionCount = false

    // MARK: - Computed Properties

    var focusedStream: StreamSlot? {
        guard focusedSlotIndex >= 0, focusedSlotIndex < streams.count else { return nil }
        return streams[focusedSlotIndex]
    }

    /// Up to four. The two-stream default and its opt-in setting came from the
    /// mpv player; AetherEngine 6.56.4 fixed what broke a third and fourth
    /// live tile (AE#450 parked a third reader to one origin, AE#451 swept a
    /// running tile's segment cache).
    var canAddStream: Bool {
        streams.count < 4
    }

    var activeChannelIds: Set<String> {
        Set(streams.map { $0.channel.id })
    }

    var streamCount: Int {
        streams.count
    }

    /// Returns true if currently in focus layout mode
    var isFocusLayout: Bool {
        if case .focus = layoutMode { return true }
        return false
    }

    // MARK: - Initialization

    /// Multiview that starts from a session already running elsewhere (the
    /// full-screen player, the guide's corner player) as its first tile, with
    /// no new tune, then optionally adds `channel` beside it.
    init(adopting session: LiveTVSessionHandoff?, adding channel: UnifiedChannel?) {
        Self.activeSessionCount += 1
        UIApplication.shared.isIdleTimerDisabled = true

        if let session { adoptStream(session) }
        if let channel, channel.id != session?.channel.id {
            Task { await addChannel(channel) }
        }
    }

    /// Take over a running session as a tile. Stops it instead when there is
    /// no room or the channel is already on screen.
    private func adoptStream(_ session: LiveTVSessionHandoff) {
        guard canAddStream, !activeChannelIds.contains(session.channel.id) else {
            session.stop()
            return
        }
        let isMuted = !streams.isEmpty
        var slot = StreamSlot(
            channel: session.channel,
            aetherPlayer: session.player,
            liveKeepalive: session.keepalive,
            playbackState: .playing,
            isMuted: isMuted
        )
        slot.currentProgram = LiveTVDataStore.shared.getCurrentProgram(for: session.channel)
        streams.append(slot)
        let index = streams.count - 1
        subscribeToSlot(at: index)
        ensureHealthMonitorRunning()
        slot.setMuted(isMuted)
        if !isMuted { focusedSlotIndex = index }
        if streams.count <= 1 { layoutMode = .grid }
    }

    // MARK: - Stream Management

    func addChannel(_ channel: UnifiedChannel) async {
        guard canAddStream else {
            return
        }
        guard !activeChannelIds.contains(channel.id) else {
            return
        }

        let isMuted = !streams.isEmpty  // First stream unmuted, others muted

        var slot = StreamSlot(
            channel: channel,
            aetherPlayer: AetherPlayer(),
            playbackState: .loading,
            isMuted: isMuted
        )

        // Load EPG data
        slot.currentProgram = LiveTVDataStore.shared.getCurrentProgram(for: channel)

        streams.append(slot)

        // Subscribe to playback state changes
        subscribeToSlot(at: streams.count - 1)
        ensureHealthMonitorRunning()
        recoveryAttempts[slot.id] = 0

        // Reset custom layout if only one stream
        if streams.count <= 1 {
            layoutMode = .grid
        }

        // Start playback (resolve = Plex tune step for cloud-EPG/DVB channels)
        let loadStartTime = Date()
        let resolved = try? await LiveTVDataStore.shared.resolveStreamURL(for: channel)
        // A slow tune can outlive its tile (closed, or multiview dismissed).
        // Release what it tuned instead of playing it where nobody sees it.
        guard !intentionallyStoppedSlots.contains(slot.id),
              let slotIndex = streams.firstIndex(where: { $0.id == slot.id }) else {
            if let resolved { PlexLiveTimelineKeepalive.release(resolved) }
            return
        }
        // The stall clock starts after the tune. Started before it, a tune
        // slower than the loading threshold drew a second, concurrent tune.
        stalledStateSince[slot.id] = Date()
        if let url = resolved {

            // Determine stream type for logging
            let streamType: String = {
                if url.path.contains("/transcode/") { return "plex_transcode" }
                if url.host?.contains("hdhomerun") == true { return "hdhr_direct" }
                if url.path.contains("/live/") || url.path.contains("/proxy/") { return "iptv" }
                return "other"
            }()

            // Log stream playback attempt for debugging (GitHub #64)
            let breadcrumb = Breadcrumb(level: .info, category: "livetv_playback")
            breadcrumb.message = "Starting Live TV stream playback"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "channel_number": channel.channelNumber ?? 0,
                "source_type": String(describing: channel.sourceType),
                "stream_type": streamType,
                "stream_url_scheme": url.scheme ?? "unknown",
                "stream_url_host": url.host ?? "unknown",
                "stream_url_path": url.path,
                "is_plex_transcode": url.path.contains("/transcode/"),
                "is_hls": url.pathExtension == "m3u8" || url.path.contains(".m3u8"),
                "slot_index": slotIndex,
                "slot_id": String(slot.id.uuidString.prefix(8)),
                "is_muted": isMuted
            ]
            SentryBridge.addBreadcrumb(breadcrumb)

            do {
                try await slot.load(url: url, headers: LiveTVClientIdentity.streamHeaders(for: channel))
                // Closing the tile during the load already stopped it.
                guard let loadedIndex = streams.firstIndex(where: { $0.id == slot.id }) else { return }
                slot.setMuted(isMuted)
                slot.play()
                watchCreditTasks[slot.id] = LiveTVDataStore.shared.beganWatching(channel)
                recoveryAttempts[slot.id] = 0
                stalledStateSince[slot.id] = nil

                let loadDuration = Date().timeIntervalSince(loadStartTime)

                // Focus the newly added stream
                setFocus(to: loadedIndex)

                // Log successful playback start with timing (GitHub #64 - DVB diagnostics)
                let successBreadcrumb = Breadcrumb(level: .info, category: "livetv_playback")
                successBreadcrumb.message = "Live TV stream loaded and play() called"
                successBreadcrumb.data = [
                    "channel_name": channel.name,
                    "channel_id": channel.id,
                    "stream_type": streamType,
                    "slot_id": String(slot.id.uuidString.prefix(8)),
                    "slot_index": slotIndex,
                    "load_duration_ms": Int(loadDuration * 1000)
                ]
                SentryBridge.addBreadcrumb(successBreadcrumb)
            } catch {
                print("MultiStream: Failed to load '\(channel.name)': \(error)")
                print("📺 [MultiStreamVM \(debugId)] addChannel FAILED id=\(channel.id), slotIndex=\(slotIndex), error=\(error)")

                // Capture playback failure with detailed context
                SentryBridge.capture(error: error) { scope in
                    scope.setTag(value: "livetv_playback", key: "component")
                    scope.setTag(value: "stream_load", key: "operation")
                    scope.setTag(value: String(describing: channel.sourceType), key: "source_type")
                    scope.setTag(value: url.path.contains("/transcode/") ? "plex_transcode" : "direct", key: "stream_type")
                    scope.setExtra(value: channel.name, key: "channel_name")
                    scope.setExtra(value: channel.id, key: "channel_id")
                    scope.setExtra(value: channel.channelNumber ?? 0, key: "channel_number")
                    // Plex transcode URLs carry X-Plex-Token in the query, and an
                    // IPTV stream URL can carry the provider username/password.
                    // Keep the query's key names (that's what diagnoses a bad
                    // client profile) and drop every value.
                    scope.setExtra(value: SensitiveDataRedactor.safeURLString(url), key: "stream_url")
                    scope.setExtra(value: url.host ?? "unknown", key: "stream_host")
                    scope.setExtra(value: url.path, key: "stream_path")
                    scope.setExtra(value: SensitiveDataRedactor.redact(url.query ?? ""), key: "stream_query_params")
                }

                scheduleAutoRecovery(for: slot.id, channel: channel, reason: "initial-load-failed")
            }
        } else {
            print("MultiStream: No stream URL available for channel '\(channel.name)' (id: \(channel.id))")

            // Capture missing stream URL as error
            let event = Event(level: .error)
            event.message = SentryMessage(formatted: "No stream URL available for Live TV channel")
            event.extra = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "channel_number": channel.channelNumber ?? 0,
                "source_type": String(describing: channel.sourceType),
                "source_id": channel.sourceId,
                "tvg_id": channel.tvgId ?? "none"
            ]
            event.tags = [
                "component": "livetv_playback",
                "operation": "get_stream_url",
                "source_type": String(describing: channel.sourceType)
            ]
            event.fingerprint = ["livetv", "no_stream_url", String(describing: channel.sourceType)]
            SentryBridge.capture(event: event)
        }
    }

    func removeStream(at index: Int) {
        guard index >= 0, index < streams.count else { return }

        let slot = streams[index]
        markSlotAsIntentionallyStopped(slot.id)

        // Stop and cleanup player
        slot.stop()
        dropSlot(at: index)
    }

    /// Take a tile's running session out of multiview without stopping it,
    /// for another surface (full screen) to adopt with no new tune. nil while
    /// the tile has nothing playing yet.
    func detachStream(at index: Int) -> LiveTVSessionHandoff? {
        guard index >= 0, index < streams.count else { return nil }
        let slot = streams[index]
        switch slot.playbackState {
        case .playing, .paused, .buffering: break
        default: return nil
        }
        markSlotAsIntentionallyStopped(slot.id)
        slot.setMuted(false)
        dropSlot(at: index)
        return LiveTVSessionHandoff(channel: slot.channel, player: slot.aetherPlayer,
                                    keepalive: slot.liveKeepalive,
                                    isNativeHLSRoute: slot.aetherPlayer.isOnNativeLiveRoute)
    }

    /// Forget the tile at `index` (already stopped or handed off) and settle
    /// layout and audio on what is left.
    private func dropSlot(at index: Int) {
        let slot = streams[index]

        // Remove subscriptions
        cancellables.removeValue(forKey: slot.id)
        cleanupTracking(for: slot.id)

        // Remove from array
        streams.remove(at: index)
        intentionallyStoppedSlots.remove(slot.id)

        // Reset layout if no streams or main stream removed
        if streams.count <= 1 {
            layoutMode = .grid
        } else if case .focus(let mainId) = layoutMode, !streams.contains(where: { $0.id == mainId }) {
            layoutMode = .grid
        }

        // Adjust focus if needed
        if streams.isEmpty {
            focusedSlotIndex = 0
        } else if index < focusedSlotIndex {
            // The audible tile moved down one place; follow it.
            focusedSlotIndex -= 1
        } else if focusedSlotIndex >= streams.count {
            setFocus(to: streams.count - 1)
        } else if index == focusedSlotIndex {
            // Removed the focused stream, make sure new focused has audio
            setFocus(to: focusedSlotIndex)
        }

        stopHealthMonitorIfNeeded()
    }

    func stopAllStreams() {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        for slot in streams {
            markSlotAsIntentionallyStopped(slot.id)
            slot.stop()
            cleanupTracking(for: slot.id)
        }
        cancellables.removeAll()
        streams.removeAll()
        layoutMode = .grid
        intentionallyStoppedSlots.removeAll()

        // Decrement session count and only re-enable screensaver when no sessions remain
        if !didDecrementSessionCount {
            didDecrementSessionCount = true
            Self.activeSessionCount = max(0, Self.activeSessionCount - 1)
            if Self.activeSessionCount == 0 {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    // MARK: - Focus Management

    func setFocus(to newIndex: Int) {
        guard newIndex >= 0, newIndex < streams.count else { return }
        guard newIndex != focusedSlotIndex || streams[newIndex].isMuted else { return }

        // Mute previously focused stream
        if focusedSlotIndex >= 0, focusedSlotIndex < streams.count {
            streams[focusedSlotIndex].setMuted(true)
            streams[focusedSlotIndex].isMuted = true
        }

        // Unmute newly focused stream
        streams[newIndex].setMuted(false)
        streams[newIndex].isMuted = false

        focusedSlotIndex = newIndex
    }

    // MARK: - Layout

    func setFocusedLayout(on slotId: UUID) {
        guard streams.count > 1 else { return }
        guard streams.first(where: { $0.id == slotId }) != nil else { return }
        layoutMode = .focus(mainId: slotId)
    }

    func resetLayout() {
        guard case .focus = layoutMode else { return }
        layoutMode = .grid
    }

    /// Replaces the stream at the given index with a new channel
    func replaceStream(at index: Int, with channel: UnifiedChannel) async {
        guard index >= 0, index < streams.count else {
            print("MultiStream: replaceStream failed - invalid index \(index), streams.count = \(streams.count)")

            // Log unexpected state for debugging
            let breadcrumb = Breadcrumb(level: .warning, category: "livetv_playback")
            breadcrumb.message = "replaceStream called with invalid index"
            breadcrumb.data = [
                "requested_index": index,
                "streams_count": streams.count,
                "channel_name": channel.name
            ]
            SentryBridge.addBreadcrumb(breadcrumb)
            return
        }

        // Allow replacing with the same channel (user might want to restart stream)
        // Only block if the channel is active in a DIFFERENT slot
        let currentChannelId = streams[index].channel.id
        if activeChannelIds.contains(channel.id) && channel.id != currentChannelId {

            let breadcrumb = Breadcrumb(level: .info, category: "livetv_playback")
            breadcrumb.message = "replaceStream blocked - channel already active in another slot"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "current_channel_id": currentChannelId
            ]
            SentryBridge.addBreadcrumb(breadcrumb)
            return
        }

        let oldSlot = streams[index]
        markSlotAsIntentionallyStopped(oldSlot.id)
        defer { intentionallyStoppedSlots.remove(oldSlot.id) }

        // Stop and cleanup old player
        oldSlot.stop()
        cancellables.removeValue(forKey: oldSlot.id)
        cleanupTracking(for: oldSlot.id)

        let isMuted = index != focusedSlotIndex  // Mute if not focused

        var newSlot = StreamSlot(
            channel: channel,
            aetherPlayer: AetherPlayer(),
            playbackState: .loading,
            isMuted: isMuted
        )
        newSlot.currentProgram = LiveTVDataStore.shared.getCurrentProgram(for: channel)

        // Replace in array
        streams[index] = newSlot

        // Subscribe to state changes
        subscribeToSlot(at: index)
        recoveryAttempts[newSlot.id] = 0

        // Update focus layout if the replaced stream was the main one
        if case .focus(let mainId) = layoutMode, mainId == oldSlot.id {
            layoutMode = .focus(mainId: newSlot.id)
        }

        // Start playback (resolve = Plex tune step for cloud-EPG/DVB channels)
        let resolved = try? await LiveTVDataStore.shared.resolveStreamURL(for: channel)
        // Same as addChannel: a tile gone during the tune releases its tune,
        // and the stall clock waits for the tune to finish.
        guard !intentionallyStoppedSlots.contains(newSlot.id),
              streams.contains(where: { $0.id == newSlot.id }) else {
            if let resolved { PlexLiveTimelineKeepalive.release(resolved) }
            return
        }
        stalledStateSince[newSlot.id] = Date()
        if let url = resolved {
            // Log stream replacement attempt for debugging
            let breadcrumb = Breadcrumb(level: .info, category: "livetv_playback")
            breadcrumb.message = "Replacing Live TV stream"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "stream_url_host": url.host ?? "unknown",
                "is_plex_transcode": url.path.contains("/transcode/"),
                "slot_index": index
            ]
            SentryBridge.addBreadcrumb(breadcrumb)

            do {
                try await newSlot.load(url: url, headers: LiveTVClientIdentity.streamHeaders(for: channel))
                guard streams.contains(where: { $0.id == newSlot.id }) else { return }
                newSlot.setMuted(isMuted)
                newSlot.play()
                watchCreditTasks[newSlot.id] = LiveTVDataStore.shared.beganWatching(channel)
            } catch {
                print("MultiStream: Failed to load replacement '\(channel.name)': \(error)")

                // Capture replacement failure with context
                SentryBridge.capture(error: error) { scope in
                    scope.setTag(value: "livetv_playback", key: "component")
                    scope.setTag(value: "stream_replace", key: "operation")
                    scope.setTag(value: String(describing: channel.sourceType), key: "source_type")
                    scope.setExtra(value: channel.name, key: "channel_name")
                    scope.setExtra(value: channel.id, key: "channel_id")
                    scope.setExtra(value: SensitiveDataRedactor.safeURLString(url), key: "stream_url")
                }

                scheduleAutoRecovery(for: newSlot.id, channel: channel, reason: "replace-load-failed")
            }
        } else {
            print("MultiStream: No stream URL available for replacement channel '\(channel.name)' (id: \(channel.id))")

            // Capture missing stream URL error
            let event = Event(level: .error)
            event.message = SentryMessage(formatted: "No stream URL for replacement Live TV channel")
            event.extra = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "source_type": String(describing: channel.sourceType)
            ]
            event.tags = [
                "component": "livetv_playback",
                "operation": "replace_stream_url"
            ]
            event.fingerprint = ["livetv", "no_stream_url", "replace"]
            SentryBridge.capture(event: event)
        }
    }

    // MARK: - Playback Controls

    func togglePlayPauseOnFocused() {
        guard let slot = focusedStream else { return }
        if slot.isPlaying {
            slot.pause()
        } else {
            slot.play()
        }
    }

    // MARK: - Subscriptions

    private func subscribeToSlot(at index: Int) {
        guard index >= 0, index < streams.count else { return }

        let slot = streams[index]
        var slotCancellables = Set<AnyCancellable>()

        slot.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if let idx = self.streams.firstIndex(where: { $0.id == slot.id }) {
                    let previousState = self.streams[idx].playbackState
                    self.streams[idx].playbackState = state
                    self.handlePlaybackStateChange(
                        slotId: slot.id,
                        channel: self.streams[idx].channel,
                        newState: state,
                        previousState: previousState
                    )
                }
            }
            .store(in: &slotCancellables)

        cancellables[slot.id] = slotCancellables
    }

    // MARK: - Auto Recovery

    private func handlePlaybackStateChange(
        slotId: UUID,
        channel: UnifiedChannel,
        newState: UniversalPlaybackState,
        previousState: UniversalPlaybackState
    ) {
        guard !intentionallyStoppedSlots.contains(slotId) else { return }

        switch newState {
        case .playing:
            stalledStateSince[slotId] = nil
            recoveryAttempts[slotId] = 0
            cancelAutoRecovery(for: slotId)

        case .ready:
            stalledStateSince[slotId] = nil

        case .loading, .buffering:
            if stalledStateSince[slotId] == nil {
                stalledStateSince[slotId] = Date()
            }

        case .failed:
            scheduleAutoRecovery(for: slotId, channel: channel, reason: "failed")

        case .ended:
            scheduleAutoRecovery(for: slotId, channel: channel, reason: "ended")

        case .idle:
            // Ignore initial idle emission from CurrentValueSubject before first load.
            if previousState == .loading {
                return
            }
            scheduleAutoRecovery(for: slotId, channel: channel, reason: "unexpected-idle")

        case .paused:
            stalledStateSince[slotId] = nil
            cancelAutoRecovery(for: slotId)
        }
    }

    private func ensureHealthMonitorRunning() {
        guard healthMonitorTask == nil else { return }

        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.checkForStalledStreams()
            }
        }
    }

    private func stopHealthMonitorIfNeeded() {
        guard streams.isEmpty else { return }
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    private func checkForStalledStreams() {
        let now = Date()

        for slot in streams {
            guard !intentionallyStoppedSlots.contains(slot.id) else { continue }
            guard let stalledSince = stalledStateSince[slot.id] else { continue }

            let elapsed = now.timeIntervalSince(stalledSince)
            let threshold: TimeInterval

            switch slot.playbackState {
            case .loading:
                threshold = loadingRecoveryThreshold
            case .buffering:
                threshold = bufferingRecoveryThreshold
            default:
                continue
            }

            if elapsed >= threshold {
                scheduleAutoRecovery(for: slot.id, channel: slot.channel, reason: "stalled-\(slot.playbackState)")
            }
        }
    }

    private func scheduleAutoRecovery(for slotId: UUID, channel: UnifiedChannel, reason: String) {
        guard streams.contains(where: { $0.id == slotId }) else { return }
        guard !intentionallyStoppedSlots.contains(slotId) else { return }
        guard autoRecoveryTasks[slotId] == nil else { return }
        guard !recoveringSlots.contains(slotId) else { return }

        let attempt = recoveryAttempts[slotId, default: 0]
        guard attempt < maxRecoveryAttempts else {
            giveUp(on: slotId)
            return
        }
        let delay = min(pow(2, Double(min(attempt, 4))), 15)  // 1s, 2s, 4s, 8s, 15s

        autoRecoveryTasks[slotId] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            let retry = await self.performAutoRecovery(for: slotId, channel: channel, reason: reason)
            // A cancelled task was already removed (and maybe replaced).
            guard !Task.isCancelled else { return }
            // Cleared BEFORE rescheduling: a retry scheduled from inside the
            // attempt found this task still registered and was dropped, so a
            // tile whose tune failed sat failed forever, never reaching the cap.
            self.autoRecoveryTasks[slotId] = nil
            if let retry {
                self.scheduleAutoRecovery(for: slotId, channel: channel, reason: retry)
            }
        }
    }

    /// One recovery attempt. Returns why to try again, or nil when done
    /// (playing, or the tile is gone).
    private func performAutoRecovery(for slotId: UUID, channel: UnifiedChannel, reason: String) async -> String? {
        guard !intentionallyStoppedSlots.contains(slotId),
              let startIndex = streams.firstIndex(where: { $0.id == slotId }),
              !recoveringSlots.contains(slotId) else { return nil }

        recoveringSlots.insert(slotId)
        defer { recoveringSlots.remove(slotId) }

        // Counted before the tune, so a tune that fails also moves toward the cap.
        recoveryAttempts[slotId, default: 0] += 1
        let attempt = recoveryAttempts[slotId] ?? 0
        // Let go of the old session before tuning a new one, or a small tuner
        // pool is still held by the attempt this one replaces.
        streams[startIndex].liveKeepalive.stop()

        let resolved = try? await LiveTVDataStore.shared.resolveStreamURL(for: channel)
        // Find the slot again: during the await multiview may have closed
        // (every slot gone) or dropped another tile (indices shifted), and an
        // index taken before it crashed or wrote to the wrong tile.
        guard !Task.isCancelled, !intentionallyStoppedSlots.contains(slotId),
              let slotIndex = streams.firstIndex(where: { $0.id == slotId }) else {
            if let resolved { PlexLiveTimelineKeepalive.release(resolved) }
            return nil
        }
        guard let url = resolved else { return "no-url" }

        stalledStateSince[slotId] = Date()
        streams[slotIndex].playbackState = .loading

        let breadcrumb = Breadcrumb(level: .info, category: "livetv_playback")
        breadcrumb.message = "Auto-recovering Live TV stream"
        breadcrumb.data = [
            "channel_name": channel.name,
            "channel_id": channel.id,
            "slot_id": slotId.uuidString,
            "reason": reason,
            "attempt": attempt,
            "stream_url_host": url.host ?? "unknown"
        ]
        SentryBridge.addBreadcrumb(breadcrumb)

        do {
            let slot = streams[slotIndex]
            let muted = slot.isMuted
            try await slot.load(url: url, headers: LiveTVClientIdentity.streamHeaders(for: channel))
            guard !Task.isCancelled,
                  !intentionallyStoppedSlots.contains(slotId),
                  streams.contains(where: { $0.id == slotId }) else { return nil }
            slot.setMuted(muted)
            slot.play()
            return nil
        } catch {
            if Task.isCancelled || intentionallyStoppedSlots.contains(slotId) {
                return nil
            }
            print("📺 [MultiStreamVM \(debugId)] auto-recovery failed channel=\(channel.name) slotId=\(slotId) error=\(error)")
            SentryBridge.capture(error: error) { scope in
                scope.setTag(value: "livetv_playback", key: "component")
                scope.setTag(value: "auto_recovery", key: "operation")
                scope.setExtra(value: channel.name, key: "channel_name")
                scope.setExtra(value: channel.id, key: "channel_id")
                scope.setExtra(value: slotId.uuidString, key: "slot_id")
                scope.setExtra(value: reason, key: "recovery_reason")
                scope.setExtra(value: attempt, key: "recovery_attempt")
            }

            return "load-error"
        }
    }

    /// Stop a tile whose channel will not play: release its player and tuner,
    /// stop listening to it (its player's idle would otherwise overwrite the
    /// state), and show it as failed. Replacing or removing it still works.
    private func giveUp(on slotId: UUID) {
        guard let index = streams.firstIndex(where: { $0.id == slotId }) else { return }
        markSlotAsIntentionallyStopped(slotId)
        cancellables.removeValue(forKey: slotId)
        streams[index].stop()
        streams[index].playbackState = .failed(.networkError("Channel unavailable"))
        streams[index].isUnavailable = true
    }

    private func cancelAutoRecovery(for slotId: UUID) {
        autoRecoveryTasks[slotId]?.cancel()
        autoRecoveryTasks.removeValue(forKey: slotId)
    }

    private func cleanupTracking(for slotId: UUID) {
        cancelAutoRecovery(for: slotId)
        watchCreditTasks.removeValue(forKey: slotId)?.cancel()
        stalledStateSince.removeValue(forKey: slotId)
        recoveryAttempts.removeValue(forKey: slotId)
        recoveringSlots.remove(slotId)
    }

    private func markSlotAsIntentionallyStopped(_ slotId: UUID) {
        intentionallyStoppedSlots.insert(slotId)
        cleanupTracking(for: slotId)
    }

    // MARK: - Cleanup

    deinit {
        healthMonitorTask?.cancel()

        // Only decrement if stopAllStreams wasn't called (safety net)
        let needsDecrement = !didDecrementSessionCount
        Task { @MainActor in
            if needsDecrement && Self.activeSessionCount > 0 {
                Self.activeSessionCount -= 1
                if Self.activeSessionCount == 0 {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
