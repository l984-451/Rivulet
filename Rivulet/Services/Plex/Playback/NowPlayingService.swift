// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  NowPlayingService.swift
//  Rivulet
//
//  Service for integrating with system Now Playing center.
//  Updates MPNowPlayingInfoCenter and handles MPRemoteCommandCenter events.
//

import Foundation
import MediaPlayer
import AVFoundation
import AppIntents
import Combine
import UIKit

/// Service that manages system Now Playing integration.
/// Updates the Now Playing info center and handles remote command events.
@MainActor
final class NowPlayingService: ObservableObject {

    // MARK: - Singleton

    static let shared = NowPlayingService()

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: UniversalPlayerViewModel?
    private var artworkTask: Task<Void, Never>?
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkURL: String?
    private var loadingArtworkURL: String?
    private var interruptionObserver: NSObjectProtocol?
    private var inputCoordinator: PlaybackInputCoordinator?
    private var lastHandledPlaybackState: UniversalPlaybackState?
    /// Track if we've set Now Playing info with valid duration (> 0)
    /// This prevents the system from ignoring our Now Playing registration
    private var hasValidNowPlayingInfo: Bool = false
    /// The language option keys, kept so a full info rewrite carries them over.
    private var languageOptionInfo: [String: Any] = [:]
    private var publishedAudioTracks: [MediaTrack] = []
    private var publishedSubtitleTracks: [MediaTrack] = []
    /// Applies a remote's track pick; a nil id turns subtitles off.
    private var selectTrack: ((MPNowPlayingInfoLanguageOptionType, Int?) -> Void)?

    // MARK: - Initialization

    private init() {
        // Don't configure audio session here - do it when attaching to a player
        // Configuring at app launch causes OSStatus error -50
        setupInterruptionHandling()
        setupRemoteCommandCenter()
    }

    // MARK: - Audio Session Configuration

    /// Ensure audio session is active before setting Now Playing info.
    /// This is required for tvOS to register us as the Now Playing app.
    /// `.moviePlayback` is also the only public opt-in to the system's Enhance Dialogue (#330).
    private func ensureAudioSessionActive() {
        PlaybackAudioSessionConfigurator.activatePlaybackSession(
            mode: .moviePlayback,
            owner: "NowPlaying"
        )
    }

    private func setNowPlayingInfoOnAllCenters(_ nowPlayingInfo: [String: Any]?) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo?.merging(languageOptionInfo) { _, new in new }
    }

    private func withNowPlayingInfoOnAllCenters(_ update: (inout [String: Any]) -> Void) {
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        update(&nowPlayingInfo)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func firstAvailableNowPlayingInfo() -> [String: Any]? {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo, !info.isEmpty else {
            return nil
        }
        return info
    }

    // MARK: - Audio Session Interruption Handling

    /// Set up observer for audio session interruptions (e.g., phone calls, other apps)
    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }
    }

    /// Handle audio session interruptions
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            // Interruption began - system is pausing our audio
            // Don't explicitly pause the player - let the system handle it
            // This prevents the "video pauses when opening Control Center" issue
            break

        case .ended:
            // Interruption ended - check if we should resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    viewModel?.resume()
                }
            }

        @unknown default:
            break
        }
    }

    // MARK: - Public API

    /// Initialize the Now Playing service early at app launch.
    /// This ensures the singleton is created and audio session category is configured.
    func initialize() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        // Audio session is configured when attach() is called
    }

    /// Attach to a player view model to sync Now Playing state
    func attach(to viewModel: UniversalPlayerViewModel, inputCoordinator: PlaybackInputCoordinator? = nil) {
        // Detach from previous if any
        detach()

        self.viewModel = viewModel
        self.inputCoordinator = inputCoordinator

        // Pick up any Skip Length change for this session's Control Center glyphs.
        // Settings can't change mid-playback, so refreshing per attach suffices.
        refreshSkipIntervals()
        claimRemoteCommands()

        // CRITICAL: Ensure audio session is active BEFORE setting Now Playing info
        // This is required for tvOS to register us as the Now Playing app
        ensureAudioSessionActive()
        // CRITICAL: Set preliminary Now Playing info BEFORE playback starts
        // tvOS only registers apps as "Now Playing" if info is set before play() is called
        setPreliminaryNowPlayingInfo(
            metadata: viewModel.metadata,
            artworkURL: viewModel.nowPlayingArtworkURL
        )

        // Track whether we've updated with actual duration from player
        hasValidNowPlayingInfo = false

        // Subscribe to playback state changes
        viewModel.$playbackState
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] state in
                guard let self, let viewModel else { return }
                if self.lastHandledPlaybackState == state {
                    return
                }
                self.lastHandledPlaybackState = state

                switch state {
                case .playing:
                    // Reassert the audio session when active playback starts.
                    // Custom playback pipelines can invalidate this state while initializing.
                    self.ensureAudioSessionActive()

                    // ALWAYS update rate and state immediately when playing starts
                    // This is critical for Control Center to show the correct state
                    self.updatePlaybackRateAndState(isPlaying: true)

                    // If we have valid duration, update full info with actual duration
                    if viewModel.duration > 0 {
                        self.updateNowPlayingInfo(
                            metadata: viewModel.metadata,
                            currentTime: viewModel.currentTime,
                            duration: viewModel.duration,
                            isPlaying: true,
                            artworkURL: viewModel.nowPlayingArtworkURL
                        )
                        self.hasValidNowPlayingInfo = true
                    }

                case .paused:
                    // Ensure audio session stays active during pause - required for Now Playing visibility
                    self.ensureAudioSessionActive()
                    // Update rate and state for paused (also re-asserts session)
                    self.updatePlaybackRateAndState(isPlaying: false)

                case .loading, .buffering:
                    // Don't update rate for loading/buffering - keep previous state
                    break

                default:
                    break
                }
            }
            .store(in: &cancellables)

        // Subscribe to time updates
        viewModel.$currentTime
            .receive(on: RunLoop.main)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak viewModel] time in
                guard let self, let viewModel else { return }
                self.updateElapsedTime(time, duration: viewModel.duration)
            }
            .store(in: &cancellables)

        // Subscribe to duration updates
        viewModel.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] duration in
                guard let self, let viewModel else { return }

                // If we haven't set valid Now Playing info yet and now have valid duration while playing,
                // set the full Now Playing info now
                if !self.hasValidNowPlayingInfo && duration > 0 && viewModel.playbackState == .playing {
                    self.updateNowPlayingInfo(
                        metadata: viewModel.metadata,
                        currentTime: viewModel.currentTime,
                        duration: duration,
                        isPlaying: true,
                        artworkURL: viewModel.nowPlayingArtworkURL
                    )
                    self.hasValidNowPlayingInfo = true
                } else {
                    self.updateDuration(duration, currentTime: viewModel.currentTime)
                }
            }
            .store(in: &cancellables)

        // Generated subtitles are listed only once the model is on disk: a remote pick never starts its download.
        Publishers.CombineLatest4(viewModel.$audioTracks, viewModel.$subtitleTracks,
                                  viewModel.$currentAudioTrackId, viewModel.$currentSubtitleTrackId)
            .combineLatest(viewModel.$aetherPlayer.map { $0 != nil }.removeDuplicates(),
                           SpeechModelStore.shared.$state.map { $0 == .ready }.removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] _ in
                guard let self, let viewModel else { return }
                let subtitles = SpeechModelStore.shared.state == .ready
                    ? viewModel.subtitleMenuTracks : viewModel.subtitleTracks
                self.publishTracks(audio: viewModel.audioTracks, subtitles: subtitles,
                                   audioId: viewModel.currentAudioTrackId,
                                   subtitleId: viewModel.currentSubtitleTrackId)
            }
            .store(in: &cancellables)
        selectTrack = { [weak viewModel] type, id in
            if type == .audible {
                if let id { viewModel?.selectAudioTrack(id: id) }
            } else {
                viewModel?.selectSubtitleTrack(id: id)
            }
        }
    }

    /// Detach from the current view model and clear Now Playing
    /// Note: We intentionally do NOT deactivate the audio session here.
    /// Per WWDC17 guidance, the session should remain active while the app could receive remote commands.
    func detach() {
        cancellables.removeAll()
        viewModel = nil
        inputCoordinator = nil
        artworkTask?.cancel()
        artworkTask = nil
        loadingArtworkURL = nil
        hasValidNowPlayingInfo = false
        lastHandledPlaybackState = nil
        selectTrack = nil
        publishedAudioTracks = []
        publishedSubtitleTracks = []
        languageOptionInfo = [:]
        clearNowPlayingInfo()
    }

    // MARK: - Language Options

    /// Lists the tracks for the system's remotes and marks the selected ones.
    private func publishTracks(audio: [MediaTrack], subtitles: [MediaTrack], audioId: Int?, subtitleId: Int?) {
        publishedAudioTracks = audio
        publishedSubtitleTracks = subtitles
        languageOptionInfo = [
            MPNowPlayingInfoPropertyAvailableLanguageOptions:
                NowPlayingLanguageOptions.groups(audio: audio, subtitles: subtitles),
            MPNowPlayingInfoPropertyCurrentLanguageOptions:
                NowPlayingLanguageOptions.current(audio: audio, subtitles: subtitles,
                                                  audioId: audioId, subtitleId: subtitleId),
        ]
        // Before the first info write there is nothing to add to; that write merges these in.
        guard firstAvailableNowPlayingInfo() != nil else { return }
        withNowPlayingInfoOnAllCenters { $0.merge(languageOptionInfo) { _, new in new } }
    }

    private func handleLanguageOption(_ event: MPRemoteCommandEvent, enable: Bool) -> MPRemoteCommandHandlerStatus {
        guard let selectTrack else { return .noActionableNowPlayingItem }
        guard let option = (event as? MPChangeLanguageOptionCommandEvent)?.languageOption else { return .commandFailed }
        let type = option.languageOptionType
        guard enable else {
            // Only subtitles can be turned off.
            guard type == .legible else { return .commandFailed }
            selectTrack(.legible, nil)
            return .success
        }
        let tracks = type == .audible ? publishedAudioTracks : publishedSubtitleTracks
        guard let id = NowPlayingLanguageOptions.trackId(for: option, in: tracks) else { return .commandFailed }
        selectTrack(type, id)
        return .success
    }

    // MARK: - Live TV

    /// Attach a Live TV session. There is no VOD view model here: remote
    /// commands (a Siri Remote Play/Pause the system delivers as a command,
    /// Control Center, an IR remote's transport keys) reach the live player
    /// through the same deduping coordinator its own button presses use, so a
    /// press that arrives both ways still toggles once.
    func attachLive(inputCoordinator: PlaybackInputCoordinator) {
        detach()
        self.inputCoordinator = inputCoordinator
        refreshSkipIntervals()
        MPRemoteCommandCenter.shared().enableLanguageOptionCommand.isEnabled = true
        MPRemoteCommandCenter.shared().disableLanguageOptionCommand.isEnabled = true
        ensureAudioSessionActive()
    }

    /// Detach a Live TV session, but only the one that is attached: a VOD
    /// player that took over in the meantime keeps its registration.
    func detachLive(inputCoordinator: PlaybackInputCoordinator) {
        guard viewModel == nil, self.inputCoordinator === inputCoordinator else { return }
        detach()
    }

    /// Now Playing text for the live channel. A live stream publishes no
    /// duration or elapsed time: `IsLiveStream` has the system draw a live
    /// indicator instead of a scrubber. `onScreenAt` is the wall-clock time of the picture, behind
    /// now while timeshifted.
    func updateLive(title: String, channelName: String?, isPlaying: Bool, artworkURL: URL?, onScreenAt: Date) {
        guard viewModel == nil, inputCoordinator != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyCurrentPlaybackDate: onScreenAt,
        ]
        if let channelName, channelName != title {
            info[MPMediaItemPropertyArtist] = channelName
        }
        // Carried across rewrites; a new URL loads and adds itself.
        if let artworkURL, artworkURL.absoluteString == cachedArtworkURL, let cachedArtwork {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        }
        setNowPlayingInfoOnAllCenters(info)
        if artworkURL?.absoluteString != cachedArtworkURL { loadArtwork(from: artworkURL) }
    }

    /// The live channel's tracks for the system's remotes. `select` applies a pick; a nil id is subtitles off.
    func updateLiveTracks(audio: [MediaTrack], subtitles: [MediaTrack], audioId: Int?, subtitleId: Int?,
                          select: @escaping (MPNowPlayingInfoLanguageOptionType, Int?) -> Void) {
        guard viewModel == nil, inputCoordinator != nil else { return }
        selectTrack = select
        publishTracks(audio: audio, subtitles: subtitles, audioId: audioId, subtitleId: subtitleId)
    }

    // MARK: - Remote Command Center Setup

    /// Configure remote commands on the shared command center.
    private func configureRemoteCommands(on commandCenter: MPRemoteCommandCenter) {
        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.play)
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.pause)
            return .success
        }

        // Toggle play/pause
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.dispatchInputAction(.playPause)
            return .success
        }

        // Skip forward by the live setting (see skipSeconds).
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            let seconds = Self.skipSeconds(event, setting: InputConfig.tapSeekSeconds)
            self?.dispatchInputAction(.seekRelative(seconds: seconds))
            return .success
        }

        // Skip backward (see note above).
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            let seconds = Self.skipSeconds(event, setting: InputConfig.tapSeekBackSeconds)
            self?.dispatchInputAction(.seekRelative(seconds: -seconds))
            return .success
        }

        refreshSkipIntervals()

        // Change playback position (scrubbing/seeking)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.dispatchInputAction(.seekAbsolute(positionEvent.positionTime))
            return .success
        }

        // Seek forward (IR remote FF button)
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekForwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else {
                return .commandFailed
            }
            switch seekEvent.type {
            case .beginSeeking:
                self?.dispatchInputAction(.scrubNudge(forward: true))
            case .endSeeking:
                break
            @unknown default:
                break
            }
            return .success
        }

        // Seek backward (IR remote RW button)
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.addTarget { [weak self] event in
            guard let seekEvent = event as? MPSeekCommandEvent else {
                return .commandFailed
            }
            switch seekEvent.type {
            case .beginSeeking:
                self?.dispatchInputAction(.scrubNudge(forward: false))
            case .endSeeking:
                break
            @unknown default:
                break
            }
            return .success
        }

        // Audio and subtitle picks from Control Center and the TV Remote app.
        commandCenter.enableLanguageOptionCommand.addTarget { [weak self] event in
            self?.handleLanguageOption(event, enable: true) ?? .noActionableNowPlayingItem
        }
        commandCenter.disableLanguageOptionCommand.addTarget { [weak self] event in
            self?.handleLanguageOption(event, enable: false) ?? .noActionableNowPlayingItem
        }

        // Which commands are ENABLED is set per attach (`claimRemoteCommands`),
        // not here: Music shares this center and flips them for its own layout.
    }

    /// The video's half of the one shared command center: skip and seek on,
    /// Music's next/previous, shuffle and repeat off. Asserted on every attach
    /// because `MusicNowPlayingBridge.claimRemoteCommands` flips them back
    /// whenever a song starts; set only once at init, a song played between
    /// two films left the second film with no skip buttons.
    private func claimRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.seekForwardCommand.isEnabled = true
        commandCenter.seekBackwardCommand.isEnabled = true
        commandCenter.enableLanguageOptionCommand.isEnabled = true
        commandCenter.disableLanguageOptionCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false
    }

    private func setupRemoteCommandCenter() {
        configureRemoteCommands(on: MPRemoteCommandCenter.shared())
    }

    /// Sync the number shown inside the Control Center skip glyphs with the
    /// user's Skip Length setting. The handlers already seek by the live
    /// `InputConfig.tapSeekSeconds`; this only drives the displayed interval.
    private func refreshSkipIntervals() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: InputConfig.tapSeekSeconds)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: InputConfig.tapSeekBackSeconds)]
    }

    /// The Skip Length setting, unless the command names another span (Siri's "skip ahead two
    /// minutes"). The skip buttons echo `preferredIntervals`, which is only the glyph's number and
    /// is refreshed per session (see refreshSkipIntervals), so an echo of it means the setting.
    private static func skipSeconds(_ event: MPRemoteCommandEvent, setting: TimeInterval) -> TimeInterval {
        guard let skip = event as? MPSkipIntervalCommandEvent, skip.interval > 0,
              let glyph = (skip.command as? MPSkipIntervalCommand)?.preferredIntervals.first?.doubleValue,
              skip.interval != glyph else { return setting }
        return skip.interval
    }

    private func dispatchInputAction(_ action: PlaybackInputAction) {
        switch action {
        case .seekAbsolute(let time):
            playerDebugLog("🎵 NowPlaying: remote seek absolute → \(String(format: "%.3f", time))s")
        case .seekRelative(let seconds):
            playerDebugLog("🎵 NowPlaying: remote seek relative → \(String(format: "%.3f", seconds))s")
        case .play, .pause, .playPause:
            break
        default:
            break
        }

        if let inputCoordinator {
            inputCoordinator.handle(action: action, source: .mpRemoteCommand)
            return
        }

        guard let viewModel else { return }

        switch action {
        case .play:
            viewModel.resume()
        case .pause:
            viewModel.pause()
        case .playPause:
            if viewModel.isScrubbing {
                Task { await viewModel.commitScrub() }
            } else {
                viewModel.togglePlayPause()
            }
        case .seekRelative(let seconds):
            Task { await viewModel.seekRelative(by: seconds) }
        case .seekAbsolute(let time):
            Task { await viewModel.seek(to: time) }
        case .scrubNudge(let forward):
            viewModel.scrubInDirection(forward: forward)
        case .scrubCommit:
            Task { await viewModel.commitScrub() }
        case .scrubCancel:
            viewModel.cancelScrub()
        default:
            break
        }
    }

    // MARK: - Now Playing Info Updates

    private func updateNowPlayingInfo(
        metadata: PlexMetadata,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        artworkURL: URL?
    ) {
        var nowPlayingInfo = [String: Any]()

        // Title
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title ?? "Unknown"

        // For episodes, set artist as show name and album as season
        if metadata.type == "episode" {
            if let showName = metadata.grandparentTitle {
                nowPlayingInfo[MPMediaItemPropertyArtist] = showName
            }
            if let seasonNum = metadata.parentIndex {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Season \(seasonNum)"
            }
        } else if metadata.type == "movie" {
            // For movies, use year as artist if available
            if let year = metadata.year {
                nowPlayingInfo[MPMediaItemPropertyArtist] = String(year)
            }
        }

        // Duration and elapsed time
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // Media type
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        nowPlayingInfo.merge(itemInfo(metadata: metadata, duration: duration)) { _, new in new }

        setNowPlayingInfoOnAllCenters(nowPlayingInfo)

        // Load artwork asynchronously
        loadArtwork(from: artworkURL)

    }

    /// Where the credits start, and the Siri entity for the item.
    private func itemInfo(metadata: PlexMetadata, duration: TimeInterval) -> [String: Any] {
        var info: [String: Any] = [:]
        // The credits the player's Up Next honors: late in the title, or near its end.
        if duration > 0, let start = metadata.creditsMarkers
            .filter({ $0.endTimeSeconds > $0.startTimeSeconds })
            .map(\.startTimeSeconds)
            .filter({ $0 / duration >= 0.5 || duration - $0 < 300 })
            .min() {
            info[MPNowPlayingInfoPropertyCreditsStartTime] = start
        }
        // `MediaItemQuery` resolves ratingKeys on the selected Plex server only.
        if #available(tvOS 27.0, *), case .plex = viewModel?.source, let key = metadata.ratingKey,
           let entity = MPAppEntityIdentifier(
               entityIdentifier: EntityIdentifier(for: MediaItemEntity.self, identifier: key)) {
            info[MPNowPlayingInfoPropertyAppEntityIdentifiers] = [entity]
        }
        return info
    }

    private func updateElapsedTime(_ time: TimeInterval, duration: TimeInterval) {
        withNowPlayingInfoOnAllCenters { nowPlayingInfo in
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
    }

    private func updateDuration(_ duration: TimeInterval, currentTime: TimeInterval) {
        withNowPlayingInfoOnAllCenters { nowPlayingInfo in
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
    }

    private func clearNowPlayingInfo() {
        setNowPlayingInfoOnAllCenters(nil)
    }

    /// Set Now Playing info BEFORE playback starts - critical for tvOS.
    /// This registers us as the "Now Playing app" before play() is called.
    /// Uses estimated duration from Plex metadata; will be updated when actual duration is available.
    private func setPreliminaryNowPlayingInfo(
        metadata: PlexMetadata,
        artworkURL: URL?
    ) {
        var nowPlayingInfo = [String: Any]()

        // Title
        nowPlayingInfo[MPMediaItemPropertyTitle] = metadata.title ?? "Unknown"

        // For episodes, set artist as show name and album as season
        if metadata.type == "episode" {
            if let showName = metadata.grandparentTitle {
                nowPlayingInfo[MPMediaItemPropertyArtist] = showName
            }
            if let seasonNum = metadata.parentIndex {
                nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Season \(seasonNum)"
            }
        } else if metadata.type == "movie" {
            // For movies, use year as artist if available
            if let year = metadata.year {
                nowPlayingInfo[MPMediaItemPropertyArtist] = String(year)
            }
        }

        // Use Plex metadata duration (milliseconds -> seconds) as estimate
        // Will be updated with actual duration when player reports it
        let estimatedDuration = Double(metadata.duration ?? 0) / 1000.0
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = estimatedDuration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        // Media type
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        nowPlayingInfo.merge(itemInfo(metadata: metadata, duration: estimatedDuration)) { _, new in new }

        setNowPlayingInfoOnAllCenters(nowPlayingInfo)

        // Load artwork asynchronously
        loadArtwork(from: artworkURL)
    }

    /// Update playback rate in Now Playing info AND set explicit playback state.
    /// This should be called whenever play/pause state changes.
    /// Also updates elapsed time to "anchor" the position when rate changes.
    private func updatePlaybackRateAndState(isPlaying: Bool) {
        guard var nowPlayingInfo = firstAvailableNowPlayingInfo() else {
            playerDebugLog("🎵 NowPlaying: Cannot update rate/state - no info set")
            return
        }

        // Update rate
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // CRITICAL: When rate changes, also update elapsed time to "anchor" the position.
        // This tells the system the exact position at the moment playback state changed.
        // Without this, the system may lose track of position or clear the Now Playing info.
        if let viewModel = viewModel {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = viewModel.currentTime
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = viewModel.duration
        }

        setNowPlayingInfoOnAllCenters(nowPlayingInfo)

    }

    // MARK: - Artwork Loading

    /// The URL is the view model's `nowPlayingArtworkURL`: an episode's season
    /// or show poster, else the item's own art.
    private func loadArtwork(from url: URL?) {
        guard let url else { return }

        // Check if we already have this artwork cached
        let fullURL = url.absoluteString
        if fullURL == cachedArtworkURL, let cachedArtwork {
            withNowPlayingInfoOnAllCenters { nowPlayingInfo in
                nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
            }
            return
        }

        // Live TV asks again on every rail update; let the load in flight finish.
        guard fullURL != loadingArtworkURL else { return }
        loadingArtworkURL = fullURL
        artworkTask?.cancel()

        // Through the image cache: its session trusts Plex servers reached by raw IP.
        artworkTask = Task {
            defer { if self.loadingArtworkURL == fullURL { self.loadingArtworkURL = nil } }
            guard let image = await ImageCacheManager.shared.image(for: url), !Task.isCancelled else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.cachedArtwork = artwork
            self.cachedArtworkURL = fullURL
            guard self.firstAvailableNowPlayingInfo() != nil else { return }
            self.withNowPlayingInfoOnAllCenters { nowPlayingInfo in
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            }
        }
    }
}
