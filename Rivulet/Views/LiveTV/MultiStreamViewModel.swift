//
//  MultiStreamViewModel.swift
//  Rivulet
//
//  Central state management for multi-stream Live TV playback
//

import SwiftUI
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

        var playbackState: UniversalPlaybackState
        var currentProgram: UnifiedProgram?
        var isMuted: Bool

        // MARK: - Convenience Accessors

        var isPlaying: Bool {
            aetherPlayer.isPlaying
        }

        var playbackStatePublisher: AnyPublisher<UniversalPlaybackState, Never> {
            aetherPlayer.playbackStatePublisher
        }

        var currentTime: TimeInterval {
            aetherPlayer.currentTime
        }

        var duration: TimeInterval {
            aetherPlayer.duration
        }

        func play() {
            aetherPlayer.play()
        }

        func pause() {
            aetherPlayer.pause()
        }

        func stop() {
            aetherPlayer.stop()
        }

        func setMuted(_ muted: Bool) {
            aetherPlayer.setMuted(muted)
        }

        func load(url: URL, headers: [String: String]?) async throws {
            // isLive: engine auto-detection is off upstream; declaring it
            // enables the live clock (live-edge tracking) and the engine's
            // LiveReloadPolicy reconnect path for this slot.
            try await aetherPlayer.load(url: url, headers: headers, startTime: nil, isLive: true)
        }
    }

    // MARK: - Published State

    @Published private(set) var streams: [StreamSlot] = []
    @Published var focusedSlotIndex: Int = 0
    @Published var showControls = true
    @Published var showChannelPicker = false {
        didSet {
            if showChannelPicker {
                // Picker opened - cancel timer so controls don't hide while browsing
                controlsTimer?.invalidate()
                controlsTimer = nil
            } else if oldValue && !showChannelPicker {
                // Picker closed - restart timer to hide controls
                startControlsHideTimer()
            }
        }
    }
    @Published var layoutMode: LayoutMode = .grid
    @Published var replaceSlotIndex: Int? = nil  // Set when replacing a stream
    @Published private(set) var isScrubbing = false
    @Published private(set) var scrubSpeed: Int = 0
    @Published private(set) var scrubTime: TimeInterval = 0

    // MARK: - Private State

    private var cancellables: [UUID: Set<AnyCancellable>] = [:]
    private var controlsTimer: Timer?
    private let controlsHideDelay: TimeInterval = 5
    private var autoRecoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var stalledStateSince: [UUID: Date] = [:]
    private var recoveryAttempts: [UUID: Int] = [:]
    private var recoveringSlots: Set<UUID> = []
    private var intentionallyStoppedSlots: Set<UUID> = []
    private var healthMonitorTask: Task<Void, Never>?
    private let loadingRecoveryThreshold: TimeInterval = 25
    private let bufferingRecoveryThreshold: TimeInterval = 20
    private let debugId = String(UUID().uuidString.prefix(8))
    private var scrubTimer: Timer?
    private var scrubSlotID: UUID?
    private let scrubUpdateInterval: TimeInterval = 0.1

    /// Speed multipliers for each level (seconds per 100ms tick)
    private static let scrubSpeeds: [Int: TimeInterval] = [
        1: 1.0,
        2: 2.0,
        3: 4.0,
        4: 8.0,
        5: 15.0,
        6: 30.0,
        7: 45.0,
        8: 60.0
    ]

    // Track active Live TV sessions to manage screensaver correctly
    // Only re-enable screensaver when ALL sessions are closed
    private static var activeSessionCount = 0
    private var didDecrementSessionCount = false

    // MARK: - Computed Properties

    var focusedStream: StreamSlot? {
        guard focusedSlotIndex >= 0, focusedSlotIndex < streams.count else { return nil }
        return streams[focusedSlotIndex]
    }

    var canAddStream: Bool {
        // Default to 2 streams, allow 4 with user opt-in (may cause crashes)
        let allowFourStreams = UserDefaults.standard.bool(forKey: "allowFourStreams")
        let maxStreams = allowFourStreams ? 4 : 2
        return streams.count < maxStreams
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

    /// Returns true if focused stream is NOT the main/expanded stream (i.e., it's in the sidebar)
    var isFocusedStreamInSidebar: Bool {
        guard case .focus(let mainId) = layoutMode,
              let focusedId = focusedStream?.id else { return false }
        return focusedId != mainId
    }

    // MARK: - Initialization

    init(initialChannel: UnifiedChannel) {

        // Track active sessions and prevent screensaver
        Self.activeSessionCount += 1
        UIApplication.shared.isIdleTimerDisabled = true

        // Add the initial channel (unmuted since it's first)
        Task {
            await addChannel(initialChannel)
        }
    }

    // MARK: - Stream Management

    func addChannel(_ channel: UnifiedChannel) async {
        guard canAddStream else {
            return
        }
        guard !activeChannelIds.contains(channel.id) else {
            return
        }

        // Close the picker immediately for responsiveness
        showChannelPicker = false

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
        let slotIndex = streams.count - 1

        // Subscribe to playback state changes
        subscribeToSlot(at: slotIndex)
        ensureHealthMonitorRunning()
        stalledStateSince[slot.id] = Date()
        recoveryAttempts[slot.id] = 0

        // Reset custom layout if only one stream
        if streams.count <= 1 {
            layoutMode = .grid
        }

        // Start playback (resolve = Plex tune step for cloud-EPG/DVB channels)
        let loadStartTime = Date()
        if let url = await LiveTVDataStore.shared.resolveStreamURL(for: channel) {

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
                try await slot.load(url: url, headers: [:])
                slot.setMuted(isMuted)
                slot.play()
                recoveryAttempts[slot.id] = 0
                stalledStateSince[slot.id] = nil

                let loadDuration = Date().timeIntervalSince(loadStartTime)

                // Focus the newly added stream
                setFocus(to: slotIndex)

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

        if isScrubbing, streams[index].id == scrubSlotID {
            cancelScrubFocused()
        }

        let slot = streams[index]
        markSlotAsIntentionallyStopped(slot.id)

        // Stop and cleanup player
        slot.stop()

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
        } else if focusedSlotIndex >= streams.count {
            setFocus(to: streams.count - 1)
        } else if index == focusedSlotIndex {
            // Removed the focused stream, make sure new focused has audio
            setFocus(to: focusedSlotIndex)
        }

        stopHealthMonitorIfNeeded()
    }

    func stopAllStreams() {
        cancelScrubFocused()
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
        } else {
        }
    }

    // MARK: - Focus Management

    func setFocus(to newIndex: Int) {
        guard newIndex >= 0, newIndex < streams.count else { return }
        guard newIndex != focusedSlotIndex || streams[newIndex].isMuted else { return }

        if isScrubbing, let scrubSlotID, scrubSlotID != streams[newIndex].id {
            cancelScrubFocused()
        }

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

    /// Expands the currently focused sidebar stream to be the main stream
    func expandFocusedStream() {
        guard let focusedStream = focusedStream else { return }
        layoutMode = .focus(mainId: focusedStream.id)
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

            // Still close picker even on failure
            showChannelPicker = false
            replaceSlotIndex = nil
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

            showChannelPicker = false
            replaceSlotIndex = nil
            return
        }

        // Close the picker immediately for responsiveness
        showChannelPicker = false

        if isScrubbing, streams[index].id == scrubSlotID {
            cancelScrubFocused()
        }

        let oldSlot = streams[index]
        markSlotAsIntentionallyStopped(oldSlot.id)

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
        stalledStateSince[newSlot.id] = Date()
        recoveryAttempts[newSlot.id] = 0

        // Update focus layout if the replaced stream was the main one
        if case .focus(let mainId) = layoutMode, mainId == oldSlot.id {
            layoutMode = .focus(mainId: newSlot.id)
        }

        // Start playback (resolve = Plex tune step for cloud-EPG/DVB channels)
        if let url = await LiveTVDataStore.shared.resolveStreamURL(for: channel) {
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
                try await newSlot.load(url: url, headers: [:])
                newSlot.setMuted(isMuted)
                newSlot.play()
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

        intentionallyStoppedSlots.remove(oldSlot.id)
        replaceSlotIndex = nil
    }

    // MARK: - Playback Controls

    func togglePlayPauseOnFocused() {
        guard let slot = focusedStream else { return }

        if slot.isPlaying {
            slot.pause()
        } else {
            slot.play()
        }

        showControlsTemporarily()
    }

    func playFocused() {
        focusedStream?.play()
        showControlsTemporarily()
    }

    func pauseFocused() {
        focusedStream?.pause()
        showControlsTemporarily()
    }

    func playAll() {
        for slot in streams {
            slot.play()
        }
    }

    func pauseAll() {
        for slot in streams {
            slot.pause()
        }
    }

    func seekFocused(by seconds: TimeInterval) {
        if isScrubbing {
            updateScrubFocusedPosition(by: seconds)
            return
        }

        guard let focusedSlotId = focusedStream?.id else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  let index = self.streams.firstIndex(where: { $0.id == focusedSlotId }) else { return }

            await self.streams[index].aetherPlayer.seekRelative(by: seconds)
            // Ensure stream is playing after seek attempt.
            self.streams[index].play()
        }

        showControlsTemporarily()
    }

    func scrubFocusedInDirection(forward: Bool) {
        guard let slot = focusedStream else { return }

        let direction = forward ? 1 : -1
        let slotCurrentTime = slot.currentTime
        let slotDuration = slot.duration

        if !isScrubbing || scrubSlotID != slot.id {
            isScrubbing = true
            scrubSlotID = slot.id
            scrubTime = slotCurrentTime
            scrubSpeed = direction
            startScrubTimer()
        } else if (scrubSpeed > 0) == forward {
            scrubSpeed = min(8, abs(scrubSpeed) + 1) * direction
        } else {
            if abs(scrubSpeed) > 1 {
                let currentDirection = scrubSpeed > 0 ? 1 : -1
                scrubSpeed = (abs(scrubSpeed) - 1) * currentDirection
            } else {
                scrubSpeed = direction
            }
        }

        let jumpAmount = forward ? InputConfig.tapSeekSeconds : -InputConfig.tapSeekSeconds
        scrubTime = clampedScrubTime(scrubTime + jumpAmount, duration: slotDuration)
        showControlsTemporarily()
    }

    func updateScrubFocusedPosition(by seconds: TimeInterval) {
        if !isScrubbing {
            guard let slot = focusedStream else { return }
            isScrubbing = true
            scrubSlotID = slot.id
            scrubSpeed = 0
            scrubTime = slot.currentTime
        }

        if let duration = focusedStreamDurationForScrub() {
            scrubTime = clampedScrubTime(scrubTime + seconds, duration: duration)
        } else {
            // Fall back to non-negative scrub time when duration is unavailable.
            scrubTime = max(0, scrubTime + seconds)
        }
        showControlsTemporarily()
    }

    func commitScrubFocused() {
        guard isScrubbing, let scrubSlotID else { return }

        let targetTime = scrubTime
        stopScrubTimer()
        isScrubbing = false
        scrubSpeed = 0
        self.scrubSlotID = nil

        Task { @MainActor [weak self] in
            guard let self,
                  let index = self.streams.firstIndex(where: { $0.id == scrubSlotID }) else { return }

            await self.streams[index].aetherPlayer.seek(to: targetTime)
            self.streams[index].play()
        }

        showControlsTemporarily()
    }

    func cancelScrubFocused() {
        guard isScrubbing else { return }
        stopScrubTimer()
        isScrubbing = false
        scrubSpeed = 0
        scrubSlotID = nil
        scrubTime = 0
        showControlsTemporarily()
    }

    private func startScrubTimer() {
        scrubTimer?.invalidate()
        scrubTimer = Timer.scheduledTimer(withTimeInterval: scrubUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateScrubFromTimer()
            }
        }
    }

    private func stopScrubTimer() {
        scrubTimer?.invalidate()
        scrubTimer = nil
    }

    private func updateScrubFromTimer() {
        guard isScrubbing, scrubSpeed != 0 else { return }
        guard let duration = focusedStreamDurationForScrub() else { return }

        let speedMagnitude = abs(scrubSpeed)
        let direction: TimeInterval = scrubSpeed > 0 ? 1 : -1
        let secondsPerTick = Self.scrubSpeeds[speedMagnitude] ?? 1.0

        scrubTime = clampedScrubTime(scrubTime + (secondsPerTick * direction), duration: duration)

        if duration > 0, (scrubTime <= 0 || scrubTime >= duration) {
            scrubSpeed = 0
            stopScrubTimer()
        }
    }

    private func focusedStreamDurationForScrub() -> TimeInterval? {
        guard let scrubSlotID,
              let index = streams.firstIndex(where: { $0.id == scrubSlotID }) else { return nil }
        return streams[index].duration
    }

    private func clampedScrubTime(_ time: TimeInterval, duration: TimeInterval) -> TimeInterval {
        if duration > 0 {
            return max(0, min(duration, time))
        }
        return max(0, time)
    }

    // MARK: - Controls Visibility

    func showControlsTemporarily() {
        showControls = true
        startControlsHideTimer()
    }

    /// Reset the controls hide timer (call when user navigates between buttons)
    func resetControlsTimer() {
        guard showControls && !showChannelPicker else { return }
        startControlsHideTimer()
    }

    private func startControlsHideTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: controlsHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Hide controls after timeout - user can press Select to show again
                // Note: Timer is cancelled when picker opens, so this won't fire during picker
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showControls = false
                }
            }
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
        let delay = min(pow(2, Double(min(attempt, 4))), 15)  // 1s, 2s, 4s, 8s, 15s...

        autoRecoveryTasks[slotId] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.performAutoRecovery(for: slotId, channel: channel, reason: reason)
        }
    }

    private func performAutoRecovery(for slotId: UUID, channel: UnifiedChannel, reason: String) async {
        defer {
            autoRecoveryTasks[slotId] = nil
        }

        guard !Task.isCancelled else { return }
        guard !intentionallyStoppedSlots.contains(slotId) else { return }
        guard let slotIndex = streams.firstIndex(where: { $0.id == slotId }) else { return }
        guard !recoveringSlots.contains(slotId) else { return }

        recoveringSlots.insert(slotId)
        defer { recoveringSlots.remove(slotId) }

        guard let url = await LiveTVDataStore.shared.resolveStreamURL(for: channel) else {
            scheduleAutoRecovery(for: slotId, channel: channel, reason: "no-url")
            return
        }

        recoveryAttempts[slotId, default: 0] += 1
        let attempt = recoveryAttempts[slotId] ?? 0
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
            try await slot.load(url: url, headers: [:])
            guard !Task.isCancelled,
                  !intentionallyStoppedSlots.contains(slotId),
                  streams.contains(where: { $0.id == slotId }) else { return }
            slot.setMuted(muted)
            slot.play()
        } catch {
            if Task.isCancelled || intentionallyStoppedSlots.contains(slotId) {
                return
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

            // Keep retrying until stream is healthy again.
            scheduleAutoRecovery(for: slotId, channel: channel, reason: "load-error")
        }
    }

    private func cancelAutoRecovery(for slotId: UUID) {
        autoRecoveryTasks[slotId]?.cancel()
        autoRecoveryTasks.removeValue(forKey: slotId)
    }

    private func cleanupTracking(for slotId: UUID) {
        cancelAutoRecovery(for: slotId)
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
        controlsTimer?.invalidate()
        scrubTimer?.invalidate()
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
