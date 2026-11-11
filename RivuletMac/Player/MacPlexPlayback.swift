// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AppKit
import Combine

/// A title on the Mac player (Plex or any provider): timeline reports, skip markers and Up Next.
/// Owned by `MacPlaybackController`, so it keeps reporting while in PiP. Derived from the iOS
/// session of the same job; the logic is the same line for line.
@MainActor
final class MacPlexPlayback: ObservableObject {
    let player = AetherPlayer()
    @Published private(set) var request: PlexPlaybackRequest
    @Published private(set) var nextEpisode: PlexMetadata?
    @Published private(set) var upNextCountdown: Int?
    @Published private(set) var upNextDismissed = false
    /// Server stream ids picked on a transcode.
    @Published private(set) var chosenAudioID: Int?
    @Published private(set) var chosenSubtitle: SubtitlePick?
    /// Set by the controller; called when `nowPlayingItem` changes (next episode).
    var onItemChange: (() -> Void)?
    /// A playlist plays through this instead of the show's next episode.
    @Published private(set) var queue: PlayQueue<PlexMetadata>?
    /// The server's reason when it ended this play session (dashboard Stop, paused too long; #403).
    @Published private(set) var serverStopReason: String?

    private let plex: any PlayerBackend
    private var skippedMarkerIDs: Set<String> = []
    private var reportedStopped: Bool { timeline.isStopped }
    private let playbackReports = PlaybackReportQueue()
    private var reportPosition = PlaybackReportPosition()
    /// Set by `end()`: a load or reload still in flight must not start playback afterwards.
    private var ended = false
    /// Titles played in a row by the countdown; the Autoplay Limit stops the chain.
    private var episodesInARow = 1
    private var countdownTask: Task<Void, Never>?
    private var nextLookupTask: Task<Void, Never>?
    private var nextTask: Task<Void, Never>?
    /// The outgoing item has reported stopped and the next one is being prepared: it must not reopen.
    private var switchingItem = false
    private var reloadTask: Task<Void, Never>?
    private var longStallTask: Task<Void, Never>?
    private lazy var timeline: PlaybackTimeline = {
        let timeline = PlaybackTimeline(reports: playbackReports, position: { [weak self] in self?.player.currentTime ?? 0 }) { [weak self] state, time in
            guard let self, !self.isPlayingCinemaExtra else { return { nil } }
            let request = request, plex = plex
            let position = reportPosition.resolve(time, isLoading: player.state == .loading,
                                                  isStarting: player.isStarting, hasStarted: playbackStart.streamHasPlayed)
            return { await plex.reportProgress(for: request, time: position, state: state.rawValue) }
        }
        timeline.onTerminated = { [weak self] in self?.endForServerTermination($0) }
        return timeline
    }()
    private var stallTracker = StallTracker()
    /// The player-menu pick; nil follows the Home or Away setting, item by item.
    private var sessionQuality: StreamingQuality?
    /// Server stream ids a fresh load still has to select on the engine.
    private var pendingEngineAudio: Int?
    private var pendingEngineSubtitle: SubtitlePick?
    private var playbackStart = PlaybackStartState()
    private var didFallBack = false
    /// Subtitles turned off in the player hold for this title, whatever the saved mode.
    private var subtitlesPickedOff = false
    /// A direct-play title still to pick its starting tracks once the engine lists them.
    private var needsStartingTracks = false
    private var cancellables = Set<AnyCancellable>()

    private let loadPlayer: (AetherPlayer, PlexPlaybackRequest, Bool) async throws -> Void

    init(request: PlexPlaybackRequest, plex: any PlayerBackend, queue: PlayQueue<PlexMetadata>? = nil,
         loadPlayer: @escaping (AetherPlayer, PlexPlaybackRequest, Bool) async throws -> Void = { player, request, keepingTransport in
             try await player.load(url: request.url, headers: request.headers, startTime: request.startTime,
                                   externalSubtitles: request.sidecarSubtitles, keepingTransport: keepingTransport,
                                   stackedParts: request.stackedParts)
         }) {
        self.request = request
        self.plex = plex
        self.queue = queue
        self.loadPlayer = loadPlayer
        observePlayer()
    }

    var nowPlayingItem: MacNowPlaying.Item {
        MacNowPlaying.Item(
            title: request.item.displayTitle,
            subtitle: request.item.subtitle,
            artworkURL: request.localArtworkURL ?? plex.artworkURL(for: request.item, kind: .poster, width: 600, height: 900),
            isLive: false
        )
    }

    /// Whether this title streams from one of the servers in `removed` (a sign-out).
    func plays(from removed: Set<String>) -> Bool {
        if let id = request.providerPlayback?.item.ref.providerID { return removed.contains(id) }
        return removed.contains { $0.hasPrefix("plex:") }
    }

    func begin() async {
        await beginCinemaExtras()
        lookUpNextEpisode()
        await load(startsItem: true)
    }

    // MARK: - Trailers before a movie

    /// The movie waiting behind the trailers playing now.
    private var cinemaFeature: PlexMetadata?
    private var cinemaQueue: [PlexMetadata] = []
    /// The version the viewer picked for the movie.
    private var cinemaFeatureVersion: VersionChoice = .best
    /// Set by the controller: a failed start of the movie after its trailers.
    var onFailure: ((String) -> Void)?
    /// Set by the controller: the title ended with nothing to play next.
    var onFinished: (() -> Void)?
    var isPlayingCinemaExtra: Bool { cinemaFeature != nil }

    /// Swaps the first server-picked clip in for the movie. Any failure plays the movie.
    private func beginCinemaExtras() async {
        let count = CinemaExtras.count
        let movie = request
        guard movie.providerPlayback == nil, !movie.isLocal, queue == nil,
              CinemaExtras.applies(type: movie.item.type, startOffset: movie.startTime, inPlaylist: false, count: count),
              let key = movie.item.ratingKey,
              let clips = try? await PlexNetworkManager.shared.cinemaExtras(
                  serverURL: movie.serverURL, authToken: movie.token, ratingKey: key, count: count),
              let first = clips.first,
              let clip = try? await plex.upNextPlayback(for: first, quality: nil, previous: movie),
              !ended else { return }
        await plex.stopTranscode(movie)
        cinemaFeature = movie.item
        cinemaFeatureVersion = movie.item.Media.flatMap { $0.indices.contains(movie.mediaIndex) ? .source("\($0[movie.mediaIndex].id)") : nil } ?? .best
        cinemaQueue = Array(clips.dropFirst())
        request = clip
    }

    /// The next clip, or the movie after the last one.
    func advanceCinemaExtras() {
        guard let feature = cinemaFeature else { return }
        if cinemaQueue.isEmpty {
            switchItem(to: feature, queueIndex: nil, featureVersion: cinemaFeatureVersion)
        } else {
            switchItem(to: cinemaQueue.removeFirst(), queueIndex: nil)
        }
    }

    func end() {
        ended = true
        cancellables.removeAll()
        countdownTask?.cancel()
        nextLookupTask?.cancel()
        nextTask?.cancel()
        reloadTask?.cancel()
        longStallTask?.cancel()
        timeline.transportChanged(.other)
        releaseThumbnails()
        let finish = finishItem(at: player.currentTime)
        let plex = plex
        let request = request
        // Repaint only after the stopped report and scrobble land.
        Task {
            await finish?.value
            await plex.watchStateDidChange()
        }
        // After the stopped report, so a provider's stop carries the real position.
        Task {
            await finish?.value
            await plex.stopTranscode(request)
        }
    }

    // MARK: - Loading

    private var canLoad: Bool { !ended && serverStopReason == nil && !Task.isCancelled }

    /// `startsItem` picks the title's starting tracks from Plex's per-item picks and the saved intents.
    private func load(keepingTransport: Bool = false, startsItem: Bool = false) async {
        guard canLoad else { return }
        let loadingRequest = request
        stallTracker.noteSeekOrLoad(at: .now)
        timeline.begin()
        let session = playbackReports.session
        playbackStart.beginLoad(startsItem: startsItem)
        if startsItem {
            reportPosition = PlaybackReportPosition(startTime: request.startTime ?? 0)
            subtitlesPickedOff = false
            needsStartingTracks = !isTranscoding
            // Plex reads the part's selection when a transcode session starts.
            if isTranscoding {
                let start = TrackIntentResolver.startingPlexSelection(streams: plexStreams)
                if start.audio != request.selectedPlexStreamID(streamType: 2)
                    || start.subtitle != SubtitlePick(request.selectedPlexStreamID(streamType: 3)) {
                    await plex.selectStream(start, in: loadingRequest)
                    guard canLoad, playbackReports.session === session else {
                        await plex.discardPreparedPlayback(loadingRequest, replacing: playbackReports.session === session ? nil : request)
                        return
                    }
                }
                chosenAudioID = start.audio
                chosenSubtitle = start.subtitle
            }
        }
        // A transcode's text subtitle arrives as a WebVTT rendition nothing selects; the file
        // opens on its default tracks, so picks made on a transcode carry back.
        pendingEngineAudio = isTranscoding ? nil : chosenAudioID
        pendingEngineSubtitle = isTranscoding ? selectedSubtitleID.map(SubtitlePick.track) : chosenSubtitle
        guard canLoad, playbackReports.session === session else {
            await plex.discardPreparedPlayback(loadingRequest, replacing: playbackReports.session === session ? nil : request)
            return
        }
        await plex.openPlaySession(loadingRequest)
        guard canLoad, playbackReports.session === session else {
            await plex.discardPreparedPlayback(loadingRequest, replacing: playbackReports.session === session ? nil : request)
            return
        }
        try? await loadPlayer(player, loadingRequest, keepingTransport)
        guard canLoad, playbackReports.session === session else {
            if playbackReports.session === session { player.stop() }
            await plex.discardPreparedPlayback(loadingRequest, replacing: playbackReports.session === session ? nil : request)
            return
        }
        if player.audioIsDropped { fallBackToTranscode() }
    }

    func retry() {
        Task { await player.retry() }
    }

    // MARK: - Quality

    var qualityLabel: String {
        let playing = request.plan.step?.label ?? String(localized: "Original")
        return request.quality == .auto ? String(localized: "Auto · \(playing)") : playing
    }

    func switchQuality(_ quality: StreamingQuality) {
        guard quality != request.quality else { return }
        sessionQuality = quality
        reload(quality: quality)
    }

    /// Swaps the stream in place: no `onItemChange`, so PiP and Now Playing stay.
    /// `plan` skips the decision. A transcode starts on `streams`, else on the file's playing tracks.
    private func reload(
        quality: StreamingQuality,
        plan: StreamPlan? = nil,
        at time: TimeInterval? = nil,
        streams: TrackPicks? = nil
    ) {
        reloadTask?.cancel()
        longStallTask?.cancel()
        let previous = request
        let time = time ?? player.pendingSeekTarget ?? player.currentTime
        let plex = plex
        // A file that never listed its tracks (a failed start) has no picks to carry.
        let picks = streams ?? (previous.plan == .original && !player.audioTracks.isEmpty ? enginePicksAsPlexIDs() : nil)
        reloadTask = Task { [weak self] in
            guard let self else { return }
            guard let next = try? await plex.preparePlayback(replacing: previous, while: { self.canLoad }, operation: {
                try await plex.reloadedPlayback(of: previous, quality: quality, plan: plan, at: time, streams: picks)
            }) else { return }
            // Same plan from a menu change: only the choice moves.
            if plan == nil, streams == nil, next.plan == previous.plan {
                var kept = previous
                kept.quality = next.quality
                kept.measuredKbps = next.measuredKbps
                kept.measuredAt = next.measuredAt
                request = kept
                return
            }
            // Plex reads the part's selection when the session starts, which is the first fetch.
            if next.plan != .original, let picks {
                await plex.selectStream(picks, in: previous)
                guard canLoad else {
                    await plex.discardPreparedPlayback(next, replacing: previous)
                    return
                }
                if let audio = picks.audio { chosenAudioID = audio }
                if let subtitle = picks.subtitle { chosenSubtitle = subtitle }
            }
            let pendingReports = playbackReports.tail
            Task {
                await pendingReports?.value
                await plex.stopTranscode(previous)
            }
            request = next
            await load(keepingTransport: true)
        }
    }

    /// Auto only: two stalls in a minute, or one that lasts, drops a step.
    private func stallChanged(_ stalled: Bool) {
        longStallTask?.cancel()
        if playbackStart.itemHasPlayed, !reportedStopped, player.state == .playing {
            report(stalled ? "buffering" : "playing")
        }
        guard stalled, request.quality == .auto else { return }
        switch stallTracker.bufferingStarted(at: .now) {
        case .ignored:
            break
        case .stepDown:
            stepDown()
        case .counted:
            longStallTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(StallTracker.longStall))
                guard !Task.isCancelled else { return }
                self?.stepDown()
            }
        }
    }

    private func stepDown() {
        guard !request.isStacked, let step = QualityDecision.stepDown(from: request.plan, sourceKbps: request.sourceKbps) else { return }
        stallTracker.noteStepDown()
        print("[Quality] Stalling, stepping down to \(step.label)")
        reload(quality: .auto, plan: .transcode(step))
    }

    /// A direct-play file that never starts gets one retry as a transcode, as on tvOS.
    private func fallBackToTranscode() {
        guard !playbackStart.streamHasPlayed, !didFallBack, request.plan == .original, !request.isLocal, !request.isStacked else { return }
        didFallBack = true
        let kbps = request.quality == .auto
            ? QualityDecision.capKbps(setting: .auto, measuredKbps: request.measuredKbps, isRelay: false) ?? 8000
            : 8000
        reload(quality: request.quality, plan: .transcode(QualityDecision.highestStep(atMost: kbps)),
               at: request.startTime ?? 0)
    }

    // MARK: - Tracks

    private var isTranscoding: Bool { request.plan != .original }

    /// The Plex part whose BIF is held, released when the item changes or playback ends.
    private var thumbnailPartID: Int?
    /// Jellyfin trickplay for a provider item, tried before engine frames.
    private let providerPreviews = ScrubPreviewHolder()

    /// The still for a scrub position: the server's BIF, loaded on the first scrub, else
    /// a frame decoded from the file. A transcode has no file to decode from.
    func scrubStill(at time: Double) async -> NSImage? {
        if let still = await providerPreviews.image(at: time, for: request.providerPlayback) { return NSImage(cgImage: still, size: .zero) }
        let parts = request.item.Media.flatMap { $0.indices.contains(request.mediaIndex) ? $0[request.mediaIndex] : nil }?.Part
        if !request.isLocal, !request.serverURL.isEmpty, parts?.count == 1, let partID = parts?.first?.id,
           !PlexThumbnailService.shared.isUnavailable(partId: partID) {
            if partID != thumbnailPartID { releaseThumbnails() }
            thumbnailPartID = partID
            let still = await PlexThumbnailService.shared.getThumbnail(
                partId: partID, time: time, serverURL: request.serverURL, authToken: request.token)
            if let still { return NSImage(cgImage: still, size: .zero) }
        }
        guard !isTranscoding, let frame = await player.still(atSeconds: time, maxWidth: 320) else { return nil }
        return NSImage(cgImage: frame, size: .zero)
    }

    private func releaseThumbnails() {
        providerPreviews.clear()
        if let thumbnailPartID { PlexThumbnailService.shared.clearCache(partId: thumbnailPartID) }
        thumbnailPartID = nil
    }

    /// By language over `MediaTrack.audioMenuSubtitle`.
    var audioTracks: [AetherPlayer.Track] {
        let tracks = mediaAudio
        return tracks.map { track in
            AetherPlayer.Track(id: track.id, name: track.audioMenuTitle, codec: "", language: nil, channels: 0,
                               isDefault: track.isDefault, isForced: false, isHearingImpaired: false,
                               menuDetail: track.audioMenuSubtitle(among: tracks))
        }
    }

    /// The tracks the menu and the saved intents read: Plex's streams on a transcode,
    /// the engine's joined to them otherwise (ids are the engine's there).
    private var mediaAudio: [MediaTrack] {
        let plexAudio = plexStreams.filter(\.isAudio).map { MediaTrack(from: $0) }
        return isTranscoding ? plexAudio : TrackMerge.mergeAudio(engine: player.audioTracks.map(Self.mediaTrack), plex: plexAudio)
    }

    private var mediaSubtitles: [MediaTrack] {
        let plexSubtitles = plexStreams.filter(\.isSubtitle).map { MediaTrack(from: $0) }
        return isTranscoding
            ? plexSubtitles
            : TrackMerge.mergeSubtitles(engine: player.subtitleTracks.map(Self.mediaTrack), plex: plexSubtitles)
    }

    private static func mediaTrack(_ track: AetherPlayer.Track) -> MediaTrack {
        MediaTrack(id: track.id, name: track.name, language: track.language, languageCode: track.language,
                   codec: track.codec, isDefault: track.isDefault, isForced: track.isForced,
                   isHearingImpaired: track.isHearingImpaired, isCommentary: track.isCommentary,
                   isAudioDescription: track.isAudioDescription, channels: track.channels > 0 ? track.channels : nil,
                   streamIndex: track.isExternal ? nil : track.id, isExternal: track.isExternal)
    }

    var selectedAudioID: Int? {
        isTranscoding ? chosenAudioID ?? request.selectedPlexStreamID(streamType: 2) : player.currentAudioTrackId
    }

    var subtitleTracks: [AetherPlayer.Track] {
        isTranscoding ? request.plexTracks(streamType: 3) : player.subtitleTracks
    }

    var selectedSubtitleID: Int? {
        guard isTranscoding else { return player.currentSubtitleTrackId }
        guard let chosenSubtitle else { return request.selectedPlexStreamID(streamType: 3) }
        return chosenSubtitle.trackID
    }

    /// On a transcode the server renders the tracks, so a change restarts it at the playhead.
    /// A pick other than what the saved intent resolves to becomes the new intent.
    func selectAudio(_ id: Int) {
        let tracks = mediaAudio
        if let track = tracks.first(where: { $0.id == id }),
           TrackIntentResolver.resolveAudio(intent: TrackIntentStore.effectiveAudioIntent, in: tracks)?.id != id {
            TrackIntentStore.audioIntent = AudioIntent(from: track)
        }
        let subtitle = foreignAudioSubtitle(forAudio: tracks.first { $0.id == id })
        guard isTranscoding else {
            player.selectAudioTrack(id: id)
            if let subtitle { player.selectSubtitleTrack(id: subtitle.trackID) }
            return
        }
        chosenAudioID = id
        if let subtitle { chosenSubtitle = subtitle }
        reload(quality: request.quality, plan: request.plan, streams: TrackPicks(audio: id, subtitle: subtitle))
    }

    /// Foreign Audio follows a new audio language unless subtitles were turned off for this
    /// title: the subtitle to switch to, nil to leave them.
    private func foreignAudioSubtitle(forAudio audio: MediaTrack?) -> SubtitlePick? {
        let intent = TrackIntentStore.effectiveSubtitleIntent
        guard case .foreignAudio = intent, !subtitlesPickedOff, let audio else { return nil }
        return SubtitlePick(TrackIntentResolver.resolveSubtitle(intent: intent, in: mediaSubtitles,
                                                                audioLanguage: audio.languageCode ?? audio.language)?.id)
    }

    func selectSubtitle(_ id: Int?) {
        subtitlesPickedOff = id == nil
        let audio = mediaAudio.first { $0.id == selectedAudioID }
        TrackIntentStore.subtitleIntent = .afterPick(
            id.flatMap { id in mediaSubtitles.first { $0.id == id } },
            replacing: TrackIntentStore.effectiveSubtitleIntent,
            audioLanguage: audio?.languageCode ?? audio?.language)
        guard isTranscoding else { return player.selectSubtitleTrack(id: id) }
        chosenSubtitle = SubtitlePick(id)
        reload(quality: request.quality, plan: request.plan, streams: TrackPicks(audio: nil, subtitle: SubtitlePick(id)))
    }

    private var plexStreams: [PlexStream] { request.item.Media?.first?.Part?.first?.Stream ?? [] }

    // MARK: - Subtitle search

    /// Whether the Subtitles menu offers a search: the server's rights and providers decide.
    @Published private(set) var subtitleSearchAvailable = false

    func refreshSubtitleSearch() async {
        let id = request.id
        let available = await request.subtitleSearch?.isAvailable() ?? false
        if id == request.id { subtitleSearchAvailable = available }
    }

    func makeSubtitleSearch() -> SubtitleSearchModel {
        SubtitleSearchModel(
            search: { [weak self] in
                guard let search = self?.request.subtitleSearch else { return [] }
                let language = SubtitleSearchLanguage.alpha2(
                    preferred: TrackIntentStore.effectiveSubtitleIntent.language, device: TrackLanguage.device)
                return try await search.search(language: language)
            },
            install: { [weak self] in await self?.installSubtitle($0) ?? false })
    }

    /// Downloads a result, waits for the server to list it, then reloads at the playhead with it on.
    private func installSubtitle(_ result: SubtitleSearchResult) async -> Bool {
        let previous = request
        guard let search = previous.subtitleSearch else { return false }
        let known = Set(plexStreams.filter(\.isSubtitle).map(\.id))
        let time = player.pendingSeekTarget ?? player.currentTime
        let audio = isTranscoding ? chosenAudioID : enginePicksAsPlexIDs().audio
        do {
            try await search.download(result)
            guard canLoad else { return false }
            guard let (next, id) = try await plex.requestWithNewSubtitle(previous, known: known, at: time) else { return false }
            guard canLoad else {
                await plex.discardPreparedPlayback(next, replacing: previous)
                return false
            }
            let picks = TrackPicks(audio: audio, subtitle: .track(id))
            if next.plan != .original { await plex.selectStream(picks, in: next) }
            guard canLoad else {
                await plex.discardPreparedPlayback(next, replacing: previous)
                return false
            }
            if let stream = next.item.Media?.first?.Part?.first?.Stream?.first(where: { $0.id == id }) {
                TrackIntentStore.subtitleIntent = .afterPick(
                    MediaTrack(from: stream), replacing: TrackIntentStore.effectiveSubtitleIntent,
                    audioLanguage: mediaAudio.first { $0.id == selectedAudioID }.flatMap { $0.languageCode ?? $0.language })
            }
            reloadTask?.cancel()
            subtitlesPickedOff = false
            if let audio { chosenAudioID = audio }
            chosenSubtitle = .track(id)
            Task { await plex.stopTranscode(previous) }
            request = next
            await load(keepingTransport: true)
            return true
        } catch {
            return false
        }
    }

    /// The engine's playing tracks as server stream ids, joined as `TrackMerge` joins them.
    private func enginePicksAsPlexIDs() -> TrackPicks {
        let streams = plexStreams
        let audio = player.currentAudioTrackId.flatMap {
            TrackMerge.serverID(forEngine: $0, engine: player.audioTracks.map(Self.mediaTrack),
                                server: streams.filter(\.isAudio).map { MediaTrack(from: $0) })
        }
        guard let subtitleID = player.currentSubtitleTrackId else { return TrackPicks(audio: audio, subtitle: .off) }
        let subtitle = TrackMerge.serverID(forEngine: subtitleID, engine: player.subtitleTracks.map(Self.mediaTrack),
                                           server: streams.filter(\.isSubtitle).map { MediaTrack(from: $0) })
        return TrackPicks(audio: audio, subtitle: subtitle.map(SubtitlePick.track))
    }

    /// Selects the pending Plex picks once the engine lists tracks they can map to.
    private func applyPendingEngineTracks() {
        if needsStartingTracks, !player.audioTracks.isEmpty { pickStartingTracks() }
        let streams = plexStreams
        if let id = pendingEngineAudio, let index = streams.first(where: { $0.id == id })?.index,
           player.audioTracks.contains(where: { $0.id == index }) {
            pendingEngineAudio = nil
            player.selectAudioTrack(id: index)
        }
        guard let pick = pendingEngineSubtitle, !player.subtitleTracks.isEmpty else { return }
        guard let id = pick.trackID, let stream = streams.first(where: { $0.id == id }) else {
            pendingEngineSubtitle = nil
            if pick == .off { player.selectSubtitleTrack(id: nil) }
            return
        }
        let tracks = player.subtitleTracks
        // A transcode's renditions carry only a language; the file's tracks join as the merge does.
        let match: Int? = if isTranscoding {
            (tracks.first { Self.sameLanguage($0.language, stream.languageCode ?? stream.language) }
                ?? (tracks.count == 1 ? tracks.first : nil))?.id
        } else {
            TrackMerge.engineTrack(forServer: id, engine: tracks.map(Self.mediaTrack),
                                   server: streams.filter(\.isSubtitle).map { MediaTrack(from: $0) })?.id
        }
        guard let match else { return }
        pendingEngineSubtitle = nil
        player.selectSubtitleTrack(id: match)
    }

    /// Direct play: Plex's per-item picks, else the saved intents, resolved on the engine's
    /// tracks so its audio-description and commentary flags count.
    private func pickStartingTracks() {
        needsStartingTracks = false
        let streams = plexStreams
        let audio = mediaAudio
        let chosenIndex = TrackIntentResolver.plexChosenAudioStreamID(
            in: streams, hasAudioIntent: TrackIntentStore.audioIntent != nil
        ).flatMap { id in streams.first { $0.id == id }?.index }
        let audioTrack = audio.first { chosenIndex != nil && $0.streamIndex == chosenIndex }
            ?? TrackIntentResolver.resolveAudio(intent: TrackIntentStore.effectiveAudioIntent, in: audio)
        if let audioTrack, audioTrack.id != player.currentAudioTrackId { player.selectAudioTrack(id: audioTrack.id) }

        let intent = TrackIntentStore.effectiveSubtitleIntent
        if let chosen = TrackIntentResolver.plexChosenSubtitleStreamID(in: streams, intent: intent) {
            pendingEngineSubtitle = .track(chosen)
            return
        }
        let subtitle = TrackIntentResolver.resolveSubtitle(
            intent: intent, in: mediaSubtitles, audioLanguage: audioTrack?.languageCode ?? audioTrack?.language)
        if subtitle?.id != player.currentSubtitleTrackId { player.selectSubtitleTrack(id: subtitle?.id) }
    }

    /// "eng" and "en" are the same language.
    private static func sameLanguage(_ a: String?, _ b: String?) -> Bool {
        func key(_ code: String?) -> String? {
            guard let code, !code.isEmpty else { return nil }
            return Locale.Language(identifier: code).languageCode?.identifier(.alpha2) ?? code.lowercased()
        }
        guard let a = key(a), let b = key(b) else { return false }
        return a == b
    }

    // MARK: - Plex reporting

    /// Feeds the timeline every transport change and playhead tick; `.ended` reports stopped and scrobbles.
    private func observePlayer() {
        player.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)

        player.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in self?.tick(time) }
            .store(in: &cancellables)

        player.$audioTracks
            .combineLatest(player.$subtitleTracks)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPendingEngineTracks() }
            .store(in: &cancellables)

        player.$isStalled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.stallChanged($0) }
            .store(in: &cancellables)

        // A seek buffers by design; the grace runs from its start and from its landing.
        player.$pendingSeekTarget
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stallTracker.noteSeekOrLoad(at: .now) }
            .store(in: &cancellables)

        player.$isStarting.combineLatest(player.$pendingSeekTarget)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] starting, target in
                guard let self else { return }
                let sought = self.playbackStart.seekCompleted(isSeeking: target != nil, isStarting: starting)
                guard !starting, target == nil, self.playbackStart.itemHasPlayed else { return }
                if let state = self.heartbeatState {
                    self.report(state)
                } else if sought, self.player.state == .playing {
                    self.report("playing")
                }
            }
            .store(in: &cancellables)
    }

    private func stateChanged(_ state: AetherPlayer.State) {
        guard serverStopReason == nil, !ended else { return }
        switch state {
        case .playing:
            playbackStart.didPlay()
            report("playing")
        case .paused, .loading:
            guard !reportedStopped, let timelineState = heartbeatState else {
                timeline.transportChanged(.other)
                return
            }
            report(timelineState)
        case .ended:
            timeline.transportChanged(.other)
            finishItem(at: max(player.duration, player.currentTime))
            if isPlayingCinemaExtra {
                advanceCinemaExtras()
            } else {
                if upNextCountdown == nil { startUpNextCountdown() }
                // Nothing next: return to the page instead of the engine's cleared (black) frame.
                if nextEpisode == nil { onFinished?() }
            }
        case .failed:
            timeline.transportChanged(.other)
            if isPlayingCinemaExtra { advanceCinemaExtras() } else { fallBackToTranscode() }
        default:
            timeline.transportChanged(.other)
        }
    }

    private var heartbeatState: String? {
        playbackStart.heartbeatState(isPaused: player.state == .paused, isLoading: player.state == .loading,
                                     isStarting: player.isStarting, isSeeking: player.pendingSeekTarget != nil,
                                     isStalled: player.isStalled)
    }

    private func tick(_ time: TimeInterval) {
        guard playbackStart.streamHasPlayed else { return }
        // A load's clock reads 0 until it starts; an intro at 0 must not fire mid-reload.
        if !player.isStarting { evaluateAutoSkip(at: time) }
        guard player.state == .playing, !player.isStalled else { return }
        timeline.tick(time)
        updateCountdownBeforeEnd()
    }

    private func report(_ state: String) {
        guard serverStopReason == nil, !ended, !switchingItem, playbackStart.itemHasPlayed, !isPlayingCinemaExtra else { return }
        switch state {
        case "playing": timeline.transportChanged(.playing)
        case "paused": timeline.transportChanged(.paused, hasStarted: playbackStart.itemHasPlayed)
        case "buffering": timeline.transportChanged(.buffering, hasStarted: playbackStart.itemHasPlayed)
        default: timeline.transportChanged(.other)
        }
    }

    /// The server stopped this stream: stop and show its reason, with nothing to retry.
    private func endForServerTermination(_ reason: String) {
        timeline.close()
        countdownTask?.cancel()
        reloadTask?.cancel()
        nextTask?.cancel()
        nextLookupTask?.cancel()
        longStallTask?.cancel()
        upNextCountdown = nil
        serverStopReason = reason
        player.stop()
    }

    /// Stopped, then a scrobble when the viewer got past the watched ceiling.
    @discardableResult
    private func finishItem(at time: TimeInterval) -> Task<Void, Never>? {
        guard !isPlayingCinemaExtra else { return nil }
        guard !reportedStopped, playbackStart.itemHasPlayed else { return playbackReports.tail }
        let request = request
        let plex = plex
        let time = reportPosition.resolve(time, isLoading: player.state == .loading,
                                          isStarting: player.isStarting, hasStarted: playbackStart.streamHasPlayed)
        let runtime = player.duration > 0 ? player.duration : request.item.durationSeconds
        let watched = (WatchProgressPolicy.progress(offsetSeconds: time, runtimeSeconds: runtime) ?? 0)
            >= WatchProgressPolicy.completionThreshold
        guard timeline.stop(at: time) != nil else { return playbackReports.tail }
        return playbackReports.enqueue {
            if watched { await plex.markWatched(request) }
        }
    }

    // MARK: - Markers

    var activeMarker: PlexMarker? {
        let time = player.currentTime
        return request.markers.first {
            !skippedMarkerIDs.contains($0.stableID) && time >= $0.start && time < $0.end
        }
    }

    private func evaluateAutoSkip(at time: TimeInterval) {
        guard let marker = activeMarker,
              MarkerSkipMode.current(for: marker.type ?? "") == .automatic else { return }
        skip(marker)
    }

    func skip(_ marker: PlexMarker) {
        skippedMarkerIDs.insert(marker.stableID)
        objectWillChange.send()
        Task { await player.seek(to: marker.end, exact: true) }
    }

    // MARK: - Chapters

    var chapters: [PlexChapter] { (request.item.Chapter ?? []).filter { $0.startTimeOffset != nil } }

    /// The server's chapter image, sized for a `width`-point row.
    func chapterImageURL(_ chapter: PlexChapter, width: Int) -> URL? {
        guard !request.isLocal else { return nil }
        return plex.imageURL(path: chapter.thumb, width: width, height: width * 9 / 16, serverID: request.item.serverID)
    }

    /// A frame from the file for a chapter the server has no image for. Not on a transcode,
    /// where a second reader would open another server session.
    func chapterStill(at seconds: TimeInterval) async -> NSImage? {
        guard !isTranscoding, let frame = await player.still(atSeconds: seconds) else { return nil }
        return NSImage(cgImage: frame, size: .zero)
    }

    func seekToChapter(_ chapter: PlexChapter) {
        guard let start = chapter.startTimeOffset else { return }
        Task { await player.seek(to: TimeInterval(start) / 1000, exact: true) }
    }

    /// A playlist entry's still, sized for a `width`-point row on a 2x screen.
    func queueArtworkURL(_ item: PlexMetadata, width: Int) -> URL? {
        plex.artworkURL(for: item, kind: item.type == "episode" ? .thumb : .backdrop,
                        width: width * 2, height: width * 2 * 9 / 16)
    }

    // MARK: - Up Next

    /// Near the end: inside the credits marker, or the last 30 s. The other choices play the
    /// credits out and open it one countdown before the end, so autoplay lands at the end (#592).
    var isNearEnd: Bool {
        if player.state == .ended { return true }
        let duration = player.duration
        guard CreditsBehavior.current().showsUpNextAtCredits else {
            return opensUpNextBeforeEnd
        }
        if activeMarker?.type == "credits" { return true }
        return duration > 60 && player.currentTime >= duration - 30
    }

    /// Credits play out and the countdown is on: Up Next and its countdown start before the end.
    private var opensUpNextBeforeEnd: Bool {
        let countdown = TimeInterval(AutoplayCountdown.current.rawValue), duration = player.duration
        return countdown > 0 && duration > 60 && player.currentTime >= duration - countdown
    }

    private func lookUpNextEpisode() {
        nextLookupTask?.cancel()
        if let queue {
            nextEpisode = queue.next
            return
        }
        let episode = request.item
        let request = request
        let plex = plex
        nextLookupTask = Task { [weak self] in
            let next = await plex.nextEpisode(after: episode, in: request)
            guard !Task.isCancelled else { return }
            self?.nextEpisode = next
        }
    }

    /// Starts the countdown one countdown before the end; a rewind out of that window stops it.
    private func updateCountdownBeforeEnd() {
        guard player.state != .ended, !CreditsBehavior.current().showsUpNextAtCredits else { return }
        if opensUpNextBeforeEnd {
            if upNextCountdown == nil { startUpNextCountdown() }
        } else if upNextCountdown != nil {
            countdownTask?.cancel()
            upNextCountdown = nil
        }
    }

    private func startUpNextCountdown() {
        let seconds = AutoplayCountdown.current.rawValue
        guard nextEpisode != nil, !upNextDismissed, seconds > 0,
              AutoplayLimit.current.allowsAutoplay(afterEpisodesInARow: episodesInARow) else { return }
        countdownTask?.cancel()
        upNextCountdown = seconds
        countdownTask = Task { [weak self] in
            while let remaining = self?.upNextCountdown, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.upNextCountdown = remaining - 1
            }
            guard !Task.isCancelled, let self, let next = self.nextEpisode else { return }
            self.switchItem(to: next, queueIndex: self.queue.map { $0.index + 1 }, autoplayed: true)
        }
    }

    func cancelUpNext() {
        countdownTask?.cancel()
        upNextCountdown = nil
        upNextDismissed = true
    }

    func playNext() {
        guard let next = nextEpisode else { return }
        switchItem(to: next, queueIndex: queue.map { $0.index + 1 })
    }

    /// The Playlist pane's pick, by position: a title can be in the list twice.
    func playEntry(at index: Int) {
        guard let queue, queue.entries.indices.contains(index), index != queue.index else { return }
        switchItem(to: queue.entries[index], queueIndex: index)
    }

    /// `featureVersion` marks the movie's turn after its trailers: from the start, on that version.
    private func switchItem(to next: PlexMetadata, queueIndex: Int?, autoplayed: Bool = false,
                            featureVersion: VersionChoice? = nil) {
        episodesInARow = autoplayed ? episodesInARow + 1 : 1
        countdownTask?.cancel()
        upNextCountdown = nil
        timeline.transportChanged(.other)
        finishItem(at: player.currentTime)
        nextTask?.cancel()
        reloadTask?.cancel()
        longStallTask?.cancel()
        let previous = request
        switchingItem = true
        nextTask = Task { [weak self] in
            // Up Next keeps the player-menu pick, else decides Home or Away again; a fresh reading is reused.
            guard let self else { return }
            // A cancelled switch leaves the flag to whatever replaced it.
            defer { if !Task.isCancelled { self.switchingItem = false } }
            let nextRequest: PlexPlaybackRequest
            do {
                guard let prepared = try await self.plex.preparePlayback(replacing: previous, while: { self.canLoad }, operation: {
                    if let featureVersion {
                        return try await self.plex.featurePlayback(for: next, version: featureVersion, previous: previous)
                    }
                    return try await self.plex.upNextPlayback(for: next, quality: self.sessionQuality, previous: previous)
                }) else { return }
                nextRequest = prepared
            } catch {
                guard featureVersion != nil, !Task.isCancelled, !ended else { return }
                cinemaFeature = nil
                onFailure?(PlaybackFailure.message(for: error))
                return
            }
            guard !Task.isCancelled else { return }
            if featureVersion != nil { cinemaFeature = nil }
            let plex = plex
            let pendingReports = playbackReports.tail
            Task {
                await pendingReports?.value
                await plex.stopTranscode(previous)
            }
            guard !ended else { return }
            request = nextRequest
            if let queueIndex { queue?.jump(to: queueIndex) }
            chosenAudioID = nil
            chosenSubtitle = nil
            didFallBack = false
            stallTracker = StallTracker()
            nextEpisode = nil
            upNextDismissed = false
            skippedMarkerIDs = []
            serverStopReason = nil
            onItemChange?()
            lookUpNextEpisode()
            switchingItem = false
            await load(startsItem: true)
        }
    }
}
