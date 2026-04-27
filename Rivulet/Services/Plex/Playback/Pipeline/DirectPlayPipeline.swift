//
//  DirectPlayPipeline.swift
//  Rivulet
//
//  Direct play pipeline using FFmpeg libavformat for container demuxing.
//  Opens raw media files (MKV, MP4, etc.) and feeds compressed packets
//  to SampleBufferRenderer via CMSampleBuffers.
//
//  Supports HEVC, H.264, Dolby Vision (with RPU conversion for P7/P8.6),
//  HDR10, HLG, and SDR content.
//

/// Pipeline state for tracking lifecycle (shared with HLSPipeline)
enum PipelineState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case running
    case paused
    case seeking
    case ended
    case failed(String) // Error message (Equatable-friendly)

    static func == (lhs: PipelineState, rhs: PipelineState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.ready, .ready),
             (.running, .running), (.paused, .paused), (.seeking, .seeking),
             (.ended, .ended):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

#if RIVULET_FFMPEG

import Foundation
import AVFoundation
import CoreMedia
import Combine
import Sentry

/// Backpressure gate for queued audio sample buffers.
/// Read loop increments pending count when yielding a buffer;
/// audio enqueue task decrements after renderer enqueue completes.
private final class AudioBufferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0
    private var maxPending = 0
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// Attempts to reserve one queue slot and updates queue diagnostics.
    func reserveSlot() -> (accepted: Bool, depth: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }

        let depth = pending
        if depth > maxPending {
            maxPending = depth
        }

        if depth >= limit {
            dropped += 1
            return (accepted: false, depth: depth, dropped: dropped)
        }

        pending += 1
        return (accepted: true, depth: depth, dropped: dropped)
    }

    func completeOne() {
        lock.lock()
        defer { lock.unlock() }
        if pending > 0 {
            pending -= 1
        }
    }

    func snapshot() -> (pending: Int, dropped: Int, maxPending: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pending: pending, dropped: dropped, maxPending: maxPending)
    }
}

/// Backpressure gate for queued raw video packets headed to the video processing
/// task. The read loop reserves a slot when yielding a packet; the video task
/// decrements after processing (DV conversion → sample buffer → enqueueVideo →
/// post-enqueue MainActor block). When pending exceeds 90% of `limit` we treat
/// the gate as "approaching limit" and the read loop pre-emptively sheds
/// non-keyframes — this avoids ever filling the gate enough to require dropping
/// a keyframe (which would cause cascading decode artifacts until the next IDR).
private final class VideoBufferGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var dropped = 0
    private var keyframesDropped = 0
    private var maxPending = 0
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// Attempts to reserve one queue slot and updates queue diagnostics.
    func reserveSlot() -> (accepted: Bool, depth: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }

        let depth = pending
        if depth > maxPending {
            maxPending = depth
        }

        if depth >= limit {
            dropped += 1
            return (accepted: false, depth: depth, dropped: dropped)
        }

        pending += 1
        return (accepted: true, depth: depth, dropped: dropped)
    }

    func completeOne() {
        lock.lock()
        defer { lock.unlock() }
        if pending > 0 {
            pending -= 1
        }
    }

    /// Returns true when the gate is at or above 90% capacity. The read loop
    /// uses this to shed non-keyframes pre-emptively before the hard limit.
    func isApproachingLimit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending * 10 >= limit * 9
    }

    /// Records that a keyframe was dropped after the brief blocking wait
    /// failed to free a slot. Should be very rare; if not, the gate is undersized.
    func recordKeyframeDrop() {
        lock.lock()
        defer { lock.unlock() }
        keyframesDropped += 1
    }

    func snapshot() -> (pending: Int, dropped: Int, maxPending: Int, keyframesDropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (
            pending: pending,
            dropped: dropped,
            maxPending: maxPending,
            keyframesDropped: keyframesDropped
        )
    }
}

/// Payload yielded from the read loop to the video processing task. Wraps a
/// raw `DemuxedPacket` plus the read-time metadata needed for ordering and
/// timing diagnostics.
private struct VideoTaskPayload: @unchecked Sendable {
    let packet: DemuxedPacket
    let videoPacketIndex: Int      // counter assigned by the read loop
    let frameWallStart: CFAbsoluteTime  // wall-clock when read loop saw the packet
}

/// Direct play pipeline: FFmpegDemuxer → CMSampleBuffer → SampleBufferRenderer
@MainActor
final class DirectPlayPipeline {

    // MARK: - Dependencies

    private let renderer: SampleBufferRenderer
    let demuxer = FFmpegDemuxer()

    // MARK: - DV Processing

    private var profileConverter: DoviProfileConverter?
    private var requiresProfileConversion = false

    // MARK: - Client-Side Audio Decoding

    private var audioDecoder: FFmpegAudioDecoder?

    /// When true, all audio codecs (including AAC) are decoded client-side via FFmpeg.
    /// Required for AirPlay routes — compressed passthrough to AVSampleBufferAudioRenderer
    /// is silently accepted but produces no audible output over AirPlay. Decoded PCM S16
    /// goes through the sample-buffer renderer's pull-mode path with larger AirPlay buffers.
    var forceClientDecodeAllAudio = false
    var forceClientDecodeCodecs: Set<String> = []

    /// Output signed 16-bit integer PCM instead of 32-bit float for client-decoded audio.
    /// AirPlay 2 natively supports S16/S24 but not float32 — avoids system-side conversion artifacts.
    /// Skips propagation when encoder is active — decoder must output native F32 for the encoder.
    var useSignedInt16Audio = false {
        didSet {
            if audioEncoder == nil { audioDecoder?.useSignedInt16Output = useSignedInt16Audio }
        }
    }

    /// When true, downmix multichannel audio to stereo for basic AirPlay speakers.
    /// Skips propagation when encoder is active — decoder must preserve full channel layout.
    var forceDownmixToStereo = false {
        didSet {
            if audioEncoder == nil { audioDecoder?.forceDownmixToStereo = forceDownmixToStereo }
        }
    }

    /// Target output sample rate for client-decoded audio.
    /// When set, swresample resamples to this rate to match the audio hardware.
    /// Critical for AirPlay (44100Hz) where source audio is typically 48000Hz.
    /// Skips propagation when encoder is active — decoder must output native rate for the encoder.
    var targetOutputSampleRate: Int = 0 {
        didSet {
            if audioEncoder == nil { audioDecoder?.targetOutputSampleRate = targetOutputSampleRate }
        }
    }

    /// When true, decoded PCM audio is routed through AVAudioEngine instead of
    /// AVSampleBufferAudioRenderer. Used for stereo AirPlay/HomePod routes where
    /// the engine has proven more tolerant than sample-buffer PCM delivery.
    var preferAudioEngineForPCM = false {
        didSet {
            guard audioDecoder != nil, audioEncoder == nil else { return }
            if preferAudioEngineForPCM {
                renderer.enableAudioEngine()
            } else {
                renderer.disableAudioEngine()
            }
        }
    }

    /// When true, re-encode client-decoded audio to EAC3 for surround over AirPlay.
    /// DTS/TrueHD -> PCM (F32, multichannel) -> EAC3 -> HomePods (5.1/7.1 surround).
    var enableSurroundReEncoding = false

    private var audioEncoder: FFmpegAudioEncoder?

    // MARK: - Client-Side Subtitle Decoding (PGS, DVB-SUB)

    private var subtitleDecoder: FFmpegSubtitleDecoder?
    private var bitmapCueCounter = 0

    // MARK: - State

    private(set) var state: PipelineState = .idle
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0

    private var readTask: Task<Void, Never>?
    private var audioEnqueueTask: Task<Void, Never>?
    /// Detached consumer task that drains raw video packets from the read loop,
    /// performs DV conversion + sample-buffer creation + late-frame detection +
    /// `renderer.enqueueVideo`, and runs the post-enqueue MainActor state hop.
    /// Decoupled from the read loop so display-layer backpressure / lookahead
    /// pacing / DV conversion CPU spikes never block the FFmpeg packet reads
    /// (which would also stop audio packet reads and starve the audio renderer).
    private var videoEnqueueTask: Task<Void, Never>?
    private var isPlaying = false
    private var playbackRate: Float = 1.0

    /// Set to true by `pause()` and cleared by `start()`/`resume()`/`stop()`/
    /// `shutdown()`/`seek()`/`selectAudioTrack()`. The read loop reads this
    /// at the top of each iteration and suspends on `pauseGateContinuation`
    /// while true — this is what prevents the demuxer from drifting forward
    /// and shedding reference frames from later GOPs during a pause.
    ///
    /// Non-isolated so the read loop can cheap-check it without a MainActor
    /// hop on every packet. Torn reads are harmless because `waitForResume()`
    /// re-validates the state under MainActor isolation before stashing a
    /// continuation.
    private nonisolated(unsafe) var isPausedFlag = false

    /// Single-slot continuation the read loop suspends on while paused.
    /// Fired by `fireResumeGate()` on resume or teardown. Only mutated on
    /// the MainActor.
    private var pauseGateContinuation: CheckedContinuation<Void, Never>?

    private var needsInitialSync = false
    private var needsRateRestoreAfterSeek = false
    /// When true, the most recent fresh start() deferred its onStateChange?(.running)
    /// emission until preroll completes. Cleared once the running state is published.
    private var deferRunningStateChange = false
    private var streamURL: URL?
    private var lastRequestedSeekTime: TimeInterval = -1
    private var lastSeekWallTime: CFAbsoluteTime = 0
    private var previousMaxVideoLookahead: TimeInterval?
    private var isAudioRecoveryInProgress = false
    private var lastAudioRecoveryWallTime: CFAbsoluteTime = 0

    // MARK: - Callbacks

    /// Called when playback state changes
    var onStateChange: ((PipelineState) -> Void)?
    /// Called when an error occurs
    var onError: ((Error) -> Void)?
    /// Called when end of stream is reached
    var onEndOfStream: (() -> Void)?
    /// Called with subtitle text, start time, and end time from embedded subtitle packets
    var onSubtitleCue: ((String, TimeInterval, TimeInterval) -> Void)?
    /// Called with bitmap subtitle cues (PGS, DVB-SUB) from embedded subtitle packets
    var onBitmapSubtitleCue: ((BitmapSubtitleCue) -> Void)?

    // MARK: - Track Info

    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []

    // MARK: - Init

    init(renderer: SampleBufferRenderer) {
        self.renderer = renderer
    }

    // MARK: - Load

    /// Open a media file for direct playback.
    /// - Parameters:
    ///   - url: Direct play URL (raw file URL from Plex server)
    ///   - headers: HTTP headers including Plex auth token
    ///   - startTime: Optional resume position in seconds
    ///   - isDolbyVision: Whether Plex metadata indicates this is DV content.
    ///     Forces dvh1 format description even if FFmpeg doesn't detect DOVI config.
    ///   - enableDVConversion: Enable DV P7/P8.6 → P8.1 conversion
    func load(url: URL, headers: [String: String]?, startTime: TimeInterval?, isDolbyVision: Bool = false, enableDVConversion: Bool = false) async throws {
        state = .loading
        onStateChange?(.loading)
        self.streamURL = url

        if previousMaxVideoLookahead == nil {
            previousMaxVideoLookahead = renderer.maxVideoLookahead
        }

        playerDebugLog("[DirectPlay] Loading: \(url.lastPathComponent) (DV=\(isDolbyVision), conversion=\(enableDVConversion))")

        // Open the container with FFmpeg off the main thread. `avformat_open_input`
        // + `avformat_find_stream_info` do blocking HTTP I/O to fetch the moov box
        // and probe packets — on slow networks this can hang the main thread for
        // multiple seconds (see RIVULET-1Y, RIVULET-M). Detach so the main actor
        // stays responsive while the demuxer does its network work.
        try await Task.detached(priority: .userInitiated) { [demuxer] in
            try demuxer.open(url: url, headers: headers, forceDolbyVision: isDolbyVision)
        }.value

        self.duration = demuxer.duration

        let audioTracksSummary = demuxer.audioTracks.map { t in
            "\(t.codecName) \(t.channels)ch [stream \(t.streamIndex)]"
        }.joined(separator: ", ")
        let selectedAudioDesc = demuxer.audioTracks
            .first(where: { $0.streamIndex == demuxer.selectedAudioStream })
            .map { "\($0.codecName) \($0.channelLayout ?? "\($0.channels)ch")" } ?? "none"

        playerDebugLog("[DirectPlay] Opened: duration=\(String(format: "%.1f", duration))s, " +
              "video=\(demuxer.videoTracks.first?.codecName ?? "none") " +
              "\(demuxer.videoTracks.first.map { "\($0.width)x\($0.height)" } ?? ""), " +
              "audio=\(selectedAudioDesc) (selected=\(demuxer.selectedAudioStream)), " +
              "audioTracks=[\(audioTracksSummary)], " +
              "DV=\(demuxer.hasDolbyVision) profile=\(demuxer.dvProfile.map(String.init) ?? "none") " +
              "level=\(demuxer.dvLevel.map(String.init) ?? "none") blCompat=\(demuxer.dvBLCompatID.map(String.init) ?? "none"), " +
              "videoFD=\(demuxer.videoFormatDescription != nil), " +
              "audioFD=\(demuxer.audioFormatDescription != nil)")

        // Lookahead controls how far the video processing task is allowed to get
        // ahead of the playback clock before `renderer.enqueueVideo` blocks on
        // its internal pacing loop. Since per-frame video work is now on a
        // dedicated consumer task (see `videoEnqueueTask`), backpressure from
        // this lookahead OR from `displayLayer.isReadyForMoreMediaData` only
        // blocks the consumer task — the FFmpeg read loop continues pulling
        // packets and audio reads stay flowing.
        //
        // 10s gives the consumer task room to absorb ~5–7s of network stalls
        // before the lookahead pacing kicks in. The display layer's own
        // internal queue caps end-to-end buffering at ~3–5s of 4K HEVC anyway,
        // so the consumer always blocks on the display layer first; this is
        // primarily a safety net.
        renderer.maxVideoLookahead = 10.0
        playerDebugLog("[DirectPlay] Renderer lookahead set to \(String(format: "%.1f", renderer.maxVideoLookahead))s")

        // Set up DV format description and conversion
        if demuxer.hasDolbyVision && enableDVConversion {
            // P7→P8.1 conversion: strip EL, convert RPUs, tag as dvh1
            requiresProfileConversion = true
            profileConverter = DoviProfileConverter()
            playerDebugLog("[DirectPlay] DV profile conversion enabled (P7/P8.6 → P8.1)")
            demuxer.rebuildFormatDescriptionForConversion(dvProfile: 8, blCompatId: 1)
        } else if demuxer.hasDolbyVision {
            // P8 native DV: tag as dvh1 so VideoToolbox activates DV decoder.
            // No RPU conversion needed — VT handles P8 RPUs natively.
            // EL stripping and VPS fix are no-ops for single-layer P8.
            let profile = demuxer.dvProfile ?? 8
            let blCompat = demuxer.dvBLCompatID ?? 1
            demuxer.rebuildFormatDescriptionForConversion(dvProfile: profile, blCompatId: blCompat)
            playerDebugLog("[DirectPlay] DV P\(profile) direct: tagged as dvh1 (no conversion)")
        }

        // Set up audio path.
        // For DV content, prefer a lightweight audio codec (AC3/EAC3/AAC) over heavy ones
        // (TrueHD/DTS-HD) to keep read-loop throughput high. TrueHD 8ch decode is a major
        // bottleneck — it can halve video throughput on 4K DV content.
        var selectedAudioTrack = demuxer.audioTracks.first(where: {
            $0.streamIndex == demuxer.selectedAudioStream
        })

        var dvAudioFallbackToPassthrough = false
        if demuxer.hasDolbyVision,
           let current = selectedAudioTrack,
           codecIsHeavyDecode(current.codecName),
           let lighterTrack = preferredLighterAudioTrack(than: current) {
            do {
                try demuxer.selectAudioStream(index: lighterTrack.streamIndex)
                selectedAudioTrack = lighterTrack
                audioDecoder?.close()
                audioDecoder = nil
                let reason = enableDVConversion ? "DV conversion mode" : "DV direct play mode"
                // If the lighter track has a native format description, use passthrough
                // (zero CPU) instead of FFmpeg decode. AC3/EAC3 are natively supported.
                if demuxer.audioFormatDescription != nil {
                    dvAudioFallbackToPassthrough = true
                    playerDebugLog("[DirectPlay] \(reason): switched audio stream \(current.streamIndex) " +
                          "(\(current.codecName) \(current.channels)ch) → \(lighterTrack.streamIndex) " +
                          "(\(lighterTrack.codecName) \(lighterTrack.channels)ch) passthrough (native FD)")
                } else {
                    playerDebugLog("[DirectPlay] \(reason): switched audio stream \(current.streamIndex) " +
                          "(\(current.codecName) \(current.channels)ch) → \(lighterTrack.streamIndex) " +
                          "(\(lighterTrack.codecName) \(lighterTrack.channels)ch) to preserve throughput")
                }
            } catch {
                playerDebugLog("[DirectPlay] Failed to switch to lighter DV audio: \(error)")
            }
        }

        if !dvAudioFallbackToPassthrough, let selectedAudioTrack, codecNeedsClientDecode(selectedAudioTrack.codecName) {
            do {
                // TrueHD/DTS has no CoreAudio format id in demuxer path.
                try demuxer.selectAudioStreamForClientDecode(index: selectedAudioTrack.streamIndex)
            } catch {
                playerDebugLog("[DirectPlay] Failed to select client-decode stream \(selectedAudioTrack.streamIndex): \(error)")
            }

            if let codecpar = demuxer.codecParameters(forStream: selectedAudioTrack.streamIndex) {
                do {
                    let decoder = try FFmpegAudioDecoder(
                        codecpar: codecpar,
                        codecNameHint: selectedAudioTrack.codecName
                    )
                    if enableSurroundReEncoding && selectedAudioTrack.channels > 2 {
                        // Re-encoding path: decoder outputs native F32 multichannel PCM,
                        // encoder converts to EAC3 for surround passthrough over AirPlay.
                        decoder.useSignedInt16Output = false
                        decoder.forceDownmixToStereo = false
                        decoder.targetOutputSampleRate = 0

                        do {
                            let encoder = try FFmpegAudioEncoder(
                                channels: Int(selectedAudioTrack.channels),
                                sampleRate: Int(selectedAudioTrack.sampleRate),
                                bitsPerSample: 32  // F32 from decoder
                            )
                            audioEncoder = encoder
                            playerDebugLog("[DirectPlay] EAC3 re-encoder enabled for " +
                                  "\(selectedAudioTrack.codecName) \(selectedAudioTrack.channels)ch " +
                                  "-> EAC3 surround")
                        } catch {
                            // Encoder failed — fall back to stereo S16
                            playerDebugLog("[DirectPlay] EAC3 encoder init failed: \(error) — falling back to stereo PCM")
                            audioEncoder = nil
                            decoder.useSignedInt16Output = useSignedInt16Audio
                            decoder.forceDownmixToStereo = forceDownmixToStereo
                            decoder.targetOutputSampleRate = targetOutputSampleRate
                        }
                    } else {
                        decoder.useSignedInt16Output = useSignedInt16Audio
                        decoder.forceDownmixToStereo = forceDownmixToStereo
                        decoder.targetOutputSampleRate = targetOutputSampleRate
                    }
                    audioDecoder = decoder
                    playerDebugLog("[DirectPlay] Client-side audio decoding enabled for " +
                          "\(selectedAudioTrack.codecName) \(selectedAudioTrack.channels)ch" +
                          (audioEncoder != nil ? " (EAC3 re-encode)" : "") +
                          (useSignedInt16Audio && audioEncoder == nil ? " (S16 output)" : "") +
                          (forceDownmixToStereo && audioEncoder == nil ? " (stereo downmix)" : "") +
                          (targetOutputSampleRate > 0 && audioEncoder == nil ? " (resample->\(targetOutputSampleRate)Hz)" : ""))
                } catch {
                    playerDebugLog("[DirectPlay] Failed to init audio decoder for " +
                          "\(selectedAudioTrack.codecName): \(error) — falling back to passthrough")
                    audioDecoder = nil
                    audioEncoder = nil
                }
            }
        } else if let selectedAudioTrack,
                  let clientDecodeTrack = demuxer.audioTracks.first(where: { codecNeedsClientDecode($0.codecName) }) {
            playerDebugLog("[DirectPlay] Keeping native audio stream \(selectedAudioTrack.streamIndex) " +
                  "(\(selectedAudioTrack.codecName) \(selectedAudioTrack.channels)ch); " +
                  "not auto-switching to software-decoded \(clientDecodeTrack.codecName)")
        }

        if audioDecoder != nil && audioEncoder == nil && preferAudioEngineForPCM {
            renderer.enableAudioEngine()
        } else {
            renderer.disableAudioEngine()
        }

        let routeSnapshot = PlaybackAudioSessionConfigurator.currentRouteAudioSnapshot(
            owner: "DirectPlayPipeline",
            reason: "load"
        )
        let routeDecision = PlaybackAudioSessionConfigurator.policyDecisionReason(for: routeSnapshot)
        let startupCodec = selectedAudioTrack?.codecName ?? "unknown"
        let startupChannels = selectedAudioTrack.map { Int($0.channels) } ?? 0
        let startupDecodePath = audioDecoder != nil ? "client_decode" : "passthrough"
        playerDebugLog(
            "[DirectPlayAudioStartup] codec=\(startupCodec) decodePath=\(startupDecodePath) " +
            "streamChannels=\(startupChannels) routeAirPlay=\(routeSnapshot.isAirPlay) " +
            "maxOutCh=\(routeSnapshot.maximumOutputChannels) " +
            "supportsMultichannel=\(routeSnapshot.supportsMultichannelContent) " +
            "routeDecision=\(routeDecision) " +
            "routeRate=\(String(format: "%.0f", routeSnapshot.sampleRate))Hz " +
            "pipelineRate=\(targetOutputSampleRate > 0 ? "\(targetOutputSampleRate)" : "native") " +
            "audioEngine=\(audioDecoder != nil && audioEncoder == nil && preferAudioEngineForPCM) " +
            "reencode=\(audioEncoder != nil) audioFD=\(demuxer.audioFormatDescription != nil) tsValidity=runtime_pending"
        )

        // Populate track info
        populateTrackInfo()

        // Handle start time
        if let startTime = startTime, startTime > 0 {
            try demuxer.seek(to: startTime)
            needsInitialSync = true
            playerDebugLog("[DirectPlay] Seeking to start time: \(String(format: "%.1f", startTime))s")
        }

        state = .ready
        onStateChange?(.ready)
        playerDebugLog("[DirectPlay] Ready")

        // Log session info
        let breadcrumb = Breadcrumb(level: .info, category: "direct_play")
        breadcrumb.message = "DirectPlay Load"
        breadcrumb.data = [
            "stream_url": url.absoluteString,
            "stream_host": url.host ?? "unknown",
            "duration": duration,
            "has_dv": demuxer.hasDolbyVision,
            "dv_profile": demuxer.dvProfile as Any,
            "video_tracks": demuxer.videoTracks.count,
            "audio_tracks": demuxer.audioTracks.count,
            "subtitle_tracks": demuxer.subtitleTracks.count,
            "dv_conversion": enableDVConversion,
            "audio_decode_path": audioDecoder != nil ? "client_decode" : "passthrough",
            "audio_route_airplay": routeSnapshot.isAirPlay,
            "audio_route_max_out_ch": routeSnapshot.maximumOutputChannels,
            "audio_selected_codec": startupCodec,
            "audio_selected_channels": startupChannels
        ]
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    // MARK: - Playback Control

    func start(rate: Float = 1.0) {
        guard state == .ready || state == .paused else {
            playerDebugLog("[DirectPlay] start() ignored — state is \(state)")
            return
        }

        let isResume = (state == .paused && readTask != nil)
        isPlaying = true
        playbackRate = rate
        state = .running

        if isResume {
            // Resume: the read loop is suspended at the pause gate (see
            // `waitForResume()`) and the video task is blocked in its
            // lookahead loop. Clear the pause flag and fire the gate to
            // wake the read loop; restoring the synchronizer rate unblocks
            // the video task naturally.
            //
            // The synchronizer manages both the display layer and audio
            // renderer (both added via addRenderer), so it coordinates
            // AirPlay latency compensation automatically on resume.
            isPausedFlag = false
            renderer.resumeAudio()
            renderer.setRate(rate)
            fireResumeGate()
            onStateChange?(.running)
            playerDebugLog("[DirectPlay] resume (rate=\(rate))")
        } else {
            // Fresh start: sync to first video frame's PTS. Defer the .running
            // emission until preroll actually completes so the player UI keeps
            // showing the loading view (which covers the player layer) instead
            // of revealing the first frame several seconds before audio begins.
            needsInitialSync = true
            deferRunningStateChange = true
            playerDebugLog("[DirectPlay] start(rate=\(rate))")
            playerDebugLog("[StartupTrace] start(): deferring .running emission until preroll completes")
            startReadLoop()
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        // Arm the pause gate before pausing the renderer so the read loop
        // suspends on its next iteration instead of pumping the demuxer
        // forward while the synchronizer is frozen.
        isPausedFlag = true
        renderer.pauseAudio()
        renderer.setRate(0)
        state = .paused
        onStateChange?(.paused)
        playerDebugLog("[DirectPlay] paused")
        playerDebugLog("[PlaybackHealth] EVENT=pause")
    }

    func resume() {
        guard !isPlaying, state == .paused else { return }
        isPlaying = true
        isPausedFlag = false
        playerDebugLog("[PlaybackHealth] EVENT=resume")
        state = .running
        onStateChange?(.running)
        // resume() emits .running synchronously above; clear any leftover
        // deferred flag from a paused-during-preroll fresh start so the
        // preroll completion handler doesn't emit a duplicate .running.
        deferRunningStateChange = false

        if readTask == nil {
            // Read loop exited after a paused seek (only a preview frame was shown).
            // Restart it with preroll so buffers refill before the clock starts.
            playerDebugLog("[DirectPlay] resume: read loop was dead, restarting with preroll")
            needsRateRestoreAfterSeek = true
            startReadLoop()
        } else {
            playerDebugLog("[DirectPlay] resume (rate=\(playbackRate))")
            renderer.resumeAudio()
            renderer.setRate(playbackRate)
            fireResumeGate()
        }
    }

    // MARK: - Pause Gate

    /// Called by the read loop when it observes `isPausedFlag == true`.
    /// Suspends on `pauseGateContinuation` until `fireResumeGate()` is called
    /// by a resume, stop, shutdown, seek, or track-switch path.
    ///
    /// Re-validates the paused state under MainActor isolation to close the
    /// race where the flag flips back to false between the read loop's
    /// cheap check and this suspension.
    private func waitForResume() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if !isPausedFlag {
                cont.resume()
                return
            }
            precondition(
                pauseGateContinuation == nil,
                "pauseGateContinuation already has a waiter — only the read loop should wait on this gate"
            )
            pauseGateContinuation = cont
        }
    }

    /// Resume the read loop's pause-gate continuation, if any. Safe to call
    /// when nothing is waiting (no-op). Callers that also need to tear the
    /// read loop down (stop/shutdown/seek/selectAudioTrack) must call
    /// `readTask?.cancel()` **before** this so the loop observes
    /// `Task.isCancelled` after waking.
    private func fireResumeGate() {
        guard let cont = pauseGateContinuation else { return }
        pauseGateContinuation = nil
        cont.resume()
    }

    func stop() {
        isPlaying = false
        deferRunningStateChange = false
        audioEnqueueTask?.cancel()
        audioEnqueueTask = nil
        videoEnqueueTask?.cancel()
        videoEnqueueTask = nil
        readTask?.cancel()
        // Wake a suspended read loop so it can observe cancellation and
        // exit — otherwise a paused-then-stopped task would leak forever.
        isPausedFlag = false
        fireResumeGate()
        readTask = nil
        audioEncoder?.close()
        audioEncoder = nil
        audioDecoder?.close()
        audioDecoder = nil
        subtitleDecoder?.close()
        subtitleDecoder = nil
        demuxer.close()
        if let previousMaxVideoLookahead {
            renderer.maxVideoLookahead = previousMaxVideoLookahead
            self.previousMaxVideoLookahead = nil
        }
        state = .idle
        onStateChange?(.idle)
    }

    /// Deterministic shutdown that waits for background tasks before tearing down decoders/demuxer.
    func shutdown() async {
        isPlaying = false

        audioEnqueueTask?.cancel()
        videoEnqueueTask?.cancel()
        readTask?.cancel()

        // Wake a suspended read loop so it can observe cancellation. Must
        // happen before the `await oldReadTask?.value` below, otherwise a
        // paused-then-shutdown pipeline would deadlock here.
        isPausedFlag = false
        fireResumeGate()

        let oldAudioTask = audioEnqueueTask
        let oldVideoTask = videoEnqueueTask
        let oldReadTask = readTask
        audioEnqueueTask = nil
        videoEnqueueTask = nil
        readTask = nil

        // The read loop is responsible for finishing the video stream's
        // continuation before exiting; awaiting the read task here ensures
        // the video task has been signalled to drain. We then await the
        // video task itself for full deterministic shutdown.
        await oldReadTask?.value
        await oldAudioTask?.value
        await oldVideoTask?.value

        audioEncoder?.close()
        audioEncoder = nil
        audioDecoder?.close()
        audioDecoder = nil
        subtitleDecoder?.close()
        subtitleDecoder = nil
        demuxer.close()

        if let previousMaxVideoLookahead {
            renderer.maxVideoLookahead = previousMaxVideoLookahead
            self.previousMaxVideoLookahead = nil
        }

        state = .idle
        onStateChange?(.idle)
    }

    /// Enable embedded subtitle extraction for a specific FFmpeg stream index.
    /// Subtitle packets will be delivered via the `onSubtitleCue` or `onBitmapSubtitleCue` callback.
    func selectSubtitleStream(ffmpegStreamIndex: Int32) {
        // Close any previous bitmap decoder
        subtitleDecoder?.close()
        subtitleDecoder = nil

        // Check if this stream is a bitmap subtitle codec (PGS, DVB-SUB, etc.)
        if let trackInfo = demuxer.subtitleTracks.first(where: { $0.streamIndex == ffmpegStreamIndex }) {
            let codec = trackInfo.codecName.lowercased()
            if FFmpegSubtitleDecoder.supportedCodecs.contains(codec) {
                // Open bitmap subtitle decoder
                if let codecpar = demuxer.codecParameters(forStream: ffmpegStreamIndex) {
                    do {
                        subtitleDecoder = try FFmpegSubtitleDecoder(codecpar: codecpar)
                        bitmapCueCounter = 0
                        playerDebugLog("[DirectPlay] Bitmap subtitle decoder opened for stream \(ffmpegStreamIndex) (\(codec))")
                    } catch {
                        playerDebugLog("[DirectPlay] Failed to open bitmap subtitle decoder: \(error)")
                    }
                }
            }
        }

        demuxer.selectSubtitleStream(index: ffmpegStreamIndex)
        playerDebugLog("[DirectPlay] Subtitle stream selected: FFmpeg index \(ffmpegStreamIndex)")
    }

    /// Disable subtitle stream reading.
    func deselectSubtitleStream() {
        subtitleDecoder?.close()
        subtitleDecoder = nil
        demuxer.selectSubtitleStream(index: -1)
    }

    // MARK: - Seek

    func seek(to time: TimeInterval, isPlaying: Bool, force: Bool = false) async throws {
        let now = CFAbsoluteTimeGetCurrent()
        let currentTime = renderer.currentTime
        let deltaFromCurrent = abs(time - currentTime)
        let deltaFromLastRequest = lastRequestedSeekTime >= 0 ? abs(time - lastRequestedSeekTime) : .infinity

        // Drop noisy duplicate seek requests that arrive back-to-back with nearly identical targets.
        if !force, now - lastSeekWallTime < 0.2 && deltaFromLastRequest < 0.25 {
            playerDebugLog("[DirectPlay] seek deduped: Δ=\(String(format: "%.0f", deltaFromLastRequest * 1000))ms from last request")
            return
        }
        // Ignore tiny seeks near current position to avoid unnecessary read-loop churn.
        if !force, deltaFromCurrent < 0.20 {
            playerDebugLog("[DirectPlay] seek ignored: Δ=\(String(format: "%.0f", deltaFromCurrent * 1000))ms from current (too small)")
            return
        }

        lastSeekWallTime = now
        lastRequestedSeekTime = time
        playerDebugLog(
            "[DirectPlay] seek request: from=\(String(format: "%.3f", currentTime))s " +
            "to=\(String(format: "%.3f", time))s playing=\(isPlaying)"
        )
        playerDebugLog("[PlaybackHealth] EVENT=seek from=\(String(format: "%.1f", currentTime))s to=\(String(format: "%.1f", time))s")

        state = .seeking
        renderer.jitterStats.reset()

        // Cancel current read loop. The read loop is responsible for
        // finishing the video stream's continuation before exiting, so
        // awaiting the read task ensures the video task can drain.
        audioEnqueueTask?.cancel()
        videoEnqueueTask?.cancel()
        let oldAudioTask = audioEnqueueTask
        let oldVideoTask = videoEnqueueTask
        audioEnqueueTask = nil
        videoEnqueueTask = nil
        readTask?.cancel()
        // Wake the read loop if it's suspended at the pause gate so it
        // observes cancellation. Must happen before the await below or
        // a seek-while-paused would deadlock.
        isPausedFlag = false
        fireResumeGate()
        let oldTask = readTask
        readTask = nil
        await oldTask?.value
        await oldAudioTask?.value
        await oldVideoTask?.value

        // Flush renderer buffers and discard any batched/encoded audio
        renderer.flush()
        _ = audioDecoder?.flushBatch()
        audioDecoder?.resetTimestampTracking(reason: "seek")
        _ = audioEncoder?.flush()

        // Seek in demuxer
        try demuxer.seek(to: time)

        // Set synchronizer time, paused
        let targetCMTime = CMTime(seconds: time, preferredTimescale: 90000)
        renderer.setRate(0, time: targetCMTime)

        self.isPlaying = isPlaying
        needsInitialSync = false
        needsRateRestoreAfterSeek = isPlaying
        // Seek has its own state machine (.seeking → .running) handled in the
        // read loop; clear any deferred fresh-start emission to avoid duplicates.
        deferRunningStateChange = false

        // Restart reading
        startReadLoop()
    }

    func recoverAudio(afterFlushTime flushTime: CMTime, reason: String) async throws {
        guard state != .idle, state != .loading else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if isAudioRecoveryInProgress {
            playerDebugLog("[DirectPlay] recoverAudio skipped (\(reason)) — recovery already in progress")
            return
        }
        if now - lastAudioRecoveryWallTime < 0.2 {
            playerDebugLog("[DirectPlay] recoverAudio debounced (\(reason))")
            return
        }

        lastAudioRecoveryWallTime = now
        isAudioRecoveryInProgress = true
        defer { isAudioRecoveryInProgress = false }

        let flushSeconds = CMTimeGetSeconds(flushTime)
        let syncTime = renderer.currentTime
        let targetTime = max(
            0,
            (flushSeconds.isFinite && flushSeconds >= 0) ? flushSeconds : syncTime
        )
        let wasPlaying = isPlaying

        playerDebugLog(
            "[DirectPlay] recoverAudio reason=\(reason) target=\(String(format: "%.3f", targetTime))s " +
            "flush=\(String(format: "%.3f", flushSeconds))s sync=\(String(format: "%.3f", syncTime))s " +
            "wasPlaying=\(wasPlaying)"
        )

        try await seek(to: targetTime, isPlaying: wasPlaying, force: true)
    }

    // MARK: - Audio Track Selection

    func selectAudioTrack(streamIndex: Int32) async throws {
        guard let track = demuxer.audioTracks.first(where: { $0.streamIndex == streamIndex }) else {
            throw FFmpegError.invalidStream
        }

        playerDebugLog("[DirectPlay] Switching audio to stream \(streamIndex) (\(track.codecName) \(track.channels)ch)")

        // Pause the sync clock so it doesn't advance while the read loop is stopped.
        // Without this, the clock drifts ahead during the restart gap, causing a
        // cascade of "late video" frames when the new loop starts.
        renderer.setRate(0)

        // Stop the read loop — it captures audioDecoder/audioFD at startup,
        // so we must restart it to pick up the new decoder configuration.
        audioEnqueueTask?.cancel()
        videoEnqueueTask?.cancel()
        let oldAudioTask = audioEnqueueTask
        let oldVideoTask = videoEnqueueTask
        audioEnqueueTask = nil
        videoEnqueueTask = nil
        readTask?.cancel()
        // Wake the read loop if it's suspended at the pause gate so the
        // await below can observe its exit. If the user had paused before
        // the track switch, the new read loop will hit the paused-seek
        // inline exit path on its first video frame.
        isPausedFlag = false
        fireResumeGate()
        let oldTask = readTask
        readTask = nil
        await oldTask?.value
        await oldAudioTask?.value
        await oldVideoTask?.value

        // Flush audio, decoder, and encoder
        renderer.flush()
        _ = audioDecoder?.flushBatch()
        audioDecoder?.resetTimestampTracking(reason: "audio_track_switch")
        _ = audioEncoder?.flush()

        if codecNeedsClientDecode(track.codecName) {
            playerDebugLog("[DirectPlay] Audio switch: \(track.codecName) -> client decode path")
            try demuxer.selectAudioStreamForClientDecode(index: streamIndex)
            guard let codecpar = demuxer.codecParameters(forStream: streamIndex) else {
                throw FFmpegError.noCodecParameters
            }
            audioDecoder?.close()
            let decoder = try FFmpegAudioDecoder(
                codecpar: codecpar,
                codecNameHint: track.codecName
            )

            // Close old encoder before potentially creating new one
            audioEncoder?.close()
            audioEncoder = nil

            if enableSurroundReEncoding && track.channels > 2 {
                decoder.useSignedInt16Output = false
                decoder.forceDownmixToStereo = false
                decoder.targetOutputSampleRate = 0
                do {
                    audioEncoder = try FFmpegAudioEncoder(
                        channels: Int(track.channels),
                        sampleRate: Int(track.sampleRate),
                        bitsPerSample: 32
                    )
                    playerDebugLog("[DirectPlay] EAC3 re-encoder enabled for \(track.codecName) \(track.channels)ch")
                } catch {
                    playerDebugLog("[DirectPlay] EAC3 encoder init failed on track switch: \(error)")
                    decoder.useSignedInt16Output = useSignedInt16Audio
                    decoder.forceDownmixToStereo = forceDownmixToStereo
                    decoder.targetOutputSampleRate = targetOutputSampleRate
                }
            } else {
                decoder.useSignedInt16Output = useSignedInt16Audio
                decoder.forceDownmixToStereo = forceDownmixToStereo
                decoder.targetOutputSampleRate = targetOutputSampleRate
            }
            audioDecoder = decoder
            if audioEncoder == nil && preferAudioEngineForPCM {
                renderer.enableAudioEngine()
            } else {
                renderer.disableAudioEngine()
            }
        } else {
            playerDebugLog("[DirectPlay] Audio switch: \(track.codecName) -> passthrough path")
            audioEncoder?.close()
            audioEncoder = nil
            audioDecoder?.close()
            audioDecoder = nil
            renderer.disableAudioEngine()
            try demuxer.selectAudioStream(index: streamIndex)
        }

        // Restart read loop with preroll — the display layer's lookahead was
        // partially drained during the restart gap, so we must rebuild video
        // lead before resuming the clock. Without preroll, the clock runs ahead
        // of the empty buffer and every frame arrives "late".
        playerDebugLog("[DirectPlay] Audio switch complete, restarting read loop")
        needsRateRestoreAfterSeek = isPlaying
        startReadLoop()
    }

    // MARK: - Private: Read Loop

    private func startReadLoop() {
        audioEnqueueTask?.cancel()
        audioEnqueueTask = nil
        videoEnqueueTask?.cancel()
        videoEnqueueTask = nil
        readTask?.cancel()
        renderer.onAudioPrimedForPlayback = nil

        // Capture everything the detached task needs — avoid referencing self directly
        // since self is @MainActor and the task must run off MainActor for FFmpeg I/O.
        let demuxer = self.demuxer
        let renderer = self.renderer
        let profileConverter = self.profileConverter
        let requiresConversion = self.requiresProfileConversion
        let audioDecoder = self.audioDecoder
        let audioEncoder = self.audioEncoder

        guard let videoFD = demuxer.videoFormatDescription else {
            playerDebugLog("[DirectPlay] No video format description — cannot start read loop")
            onError?(FFmpegError.noCodecParameters)
            return
        }
        let audioFD = demuxer.audioFormatDescription
        let hasDV = demuxer.hasDolbyVision
        let activeAudioTrack = demuxer.audioTracks.first(where: { $0.streamIndex == demuxer.selectedAudioStream })
        let activeAudioSampleRate = activeAudioTrack.map { Int($0.sampleRate) } ?? 0
        let activeAudioChannels = activeAudioTrack.map { Int($0.channels) } ?? 0
        let activeTargetOutputSampleRate = self.targetOutputSampleRate

        var audioContinuation: AsyncStream<CMSampleBuffer>.Continuation?
        var audioGate: AudioBufferGate?
        var audioDecodeStream: AsyncStream<DemuxedPacket>?
        var audioDecodeContinuation: AsyncStream<DemuxedPacket>.Continuation?
        var audioDecodeGate: AudioBufferGate?

        if audioDecoder != nil || audioFD != nil {
            // AC3 packets are typically 32ms; keep queue under ~0.8s so audio
            // cannot run multiple seconds ahead of video on slow-start bursts.
            let gate = AudioBufferGate(limit: 24)
            audioGate = gate
            playerDebugLog("[DirectPlay] Audio enqueue queue enabled (limit=\(gate.limit))")

            let (stream, continuation) = AsyncStream<CMSampleBuffer>.makeStream(
                bufferingPolicy: .unbounded
            )
            audioContinuation = continuation

            audioEnqueueTask = Task.detached {
                // Throughput tracking so we can distinguish "audio task isn't
                // being scheduled" from "audio task is scheduled but has no
                // samples to consume" (network bottleneck).
                var iterationsSinceLastLog = 0
                var pullDirectHits = 0
                var fallbackHits = 0
                var lastLogWall = CFAbsoluteTimeGetCurrent()

                for await sampleBuffer in stream {
                    guard !Task.isCancelled else { break }
                    // Try the nonisolated pull-mode fast path first. This
                    // bypasses the @MainActor hop entirely so the audio
                    // task can deliver samples even when the video task is
                    // hogging MainActor on enqueueVideo backpressure waits.
                    if renderer.enqueueAudioPullDirect(sampleBuffer) {
                        pullDirectHits += 1
                    } else {
                        fallbackHits += 1
                        await renderer.enqueueAudio(sampleBuffer)
                    }
                    gate.completeOne()
                    iterationsSinceLastLog += 1

                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastLogWall >= 2.0 {
                        let elapsed = now - lastLogWall
                        let rate = Double(iterationsSinceLastLog) / elapsed
                        playerDebugLog("[AudioTaskThroughput] iter=\(iterationsSinceLastLog) " +
                              "elapsed=\(String(format: "%.2f", elapsed))s " +
                              "rate=\(String(format: "%.1f", rate))/s " +
                              "direct=\(pullDirectHits) fallback=\(fallbackHits)")
                        iterationsSinceLastLog = 0
                        pullDirectHits = 0
                        fallbackHits = 0
                        lastLogWall = now
                    }
                }
            }
        }

        if audioDecoder != nil {
            // Keep compressed audio decode off the packet-read path so video can
            // continue progressing even when TrueHD/DTS decoding is expensive.
            let gate = AudioBufferGate(limit: 512)
            audioDecodeGate = gate
            let (stream, continuation) = AsyncStream<DemuxedPacket>.makeStream(
                bufferingPolicy: .unbounded
            )
            audioDecodeStream = stream
            audioDecodeContinuation = continuation
            playerDebugLog("[DirectPlay] Audio decode queue enabled (limit=\(gate.limit))")
        }

        // Video processing decoupling. Mirror of the audio gate/stream pattern,
        // but the consumer task does the entire per-frame video pipeline (DV
        // conversion, sample buffer creation, late-frame check, enqueueVideo,
        // post-enqueue MainActor hop, timing diagnostics) instead of just the
        // enqueue. The read loop becomes a thin packet shuttler so nothing
        // per-frame on the video side can stall audio packet reads.
        //
        // 144 frames ≈ 6 s at 24 fps ≈ ~38 MB of compressed 4K HEVC. The
        // display layer's own internal queue caps end-to-end buffering well
        // before this in normal operation; the gate is only here as a safety
        // net for pathological backpressure.
        let videoGateLocal = VideoBufferGate(limit: 144)
        let (vStream, vContinuation) = AsyncStream<VideoTaskPayload>.makeStream(
            bufferingPolicy: .unbounded
        )
        playerDebugLog("[DirectPlay] Video processing queue enabled (limit=\(videoGateLocal.limit))")

        let localAudioEnqueueTask = audioEnqueueTask
        let localAudioContinuation = audioContinuation
        let localAudioGate = audioGate
        let localAudioDecodeStream = audioDecodeStream
        let localAudioDecodeContinuation = audioDecodeContinuation
        let localAudioDecodeGate = audioDecodeGate
        let localVideoGate = videoGateLocal
        let localVideoContinuation = vContinuation

        playerDebugLog("[DirectPlay] Starting read loop (audioFD=\(audioFD != nil), hasDV=\(hasDV), conversion=\(requiresConversion))")

        let capturedLookahead = renderer.maxVideoLookahead
        let capturedContainer = streamURL?.pathExtension ?? "?"

        // Late-frame detection thresholds — used by the video task. DV content
        // needs more headroom because VT's DV decoder has higher variability.
        let lateVideoDropThreshold: TimeInterval = hasDV ? 3.0 : 1.5
        let forceLateResyncThreshold: TimeInterval = hasDV ? 8.0 : 4.0
        let maxConsecutiveLateFramesBeforeResync = hasDV ? 120 : 48
        let lateResyncCooldown: TimeInterval = hasDV ? 2.0 : 1.0
        let softLateDropThreshold: TimeInterval = hasDV ? 3.0 : 2.0
        let maxSoftLateDropsPerBurst = hasDV ? 24 : 12
        let startupGracePeriod: TimeInterval = hasDV ? 60.0 : 15.0
        let healthReportInterval: TimeInterval = 5.0

        // ── Video processing task ──
        // Drains raw video packets from the read loop and runs the entire
        // per-frame pipeline (late-frame check → DV conversion → sample buffer →
        // enqueueVideo → post-enqueue MainActor hop → timing/health diagnostics).
        // All per-frame video state is task-local; nothing crosses the boundary
        // back to the read loop except `videoGate.completeOne()`.
        videoEnqueueTask = Task.detached { [weak self] in
            // Task-local state (mirrors what used to live inside the read loop's
            // video case)
            var taskFirstFrame = true
            var taskFramesProcessed = 0
            var conversionDisabled = false
            // True once the post-enqueue state has been transitioned through
            // .seeking → .running at least once. After that the per-frame state
            // transition branch is skipped to save a MainActor hop per frame.
            var hasObservedRunning = false

            // Late-frame detection state
            var lateVideoObservationCount = 0
            var lateVideoDropCount = 0
            var lateVideoSoftDropCount = 0
            var consecutiveLateVideoFrames = 0
            var lateVideoResyncCount = 0
            var lastLateVideoResyncWall: CFAbsoluteTime = 0

            // Timing accumulators (reset every 120 frames)
            var timingReadGapMs: Double = 0
            var timingConversionMs: Double = 0
            var timingSampleMs: Double = 0
            var timingSyncMs: Double = 0
            var timingEnqueueMs: Double = 0
            var timingTotalMs: Double = 0
            var timingFrameCount: Int = 0
            var lastVideoEnqueueEnd: CFAbsoluteTime = 0

            // Wall-clock cadence tracking
            var lastVideoWallTime: CFAbsoluteTime?
            var maxVideoWallGapMs: Double = 0
            var longVideoWallGaps = 0
            var slowVideoPipelineCount = 0

            // Health report state
            var lastHealthReportWall: CFAbsoluteTime = 0
            var healthLateFramesSinceReport = 0
            var healthDropsSinceReport = 0
            var healthResyncsSinceReport = 0
            var healthSlowFramesSinceReport = 0
            var healthDisplayErrorsSinceReport = 0
            var healthLastPullDeliveries = 0
            var healthLastPeriodPTS: TimeInterval = 0
            var healthLastPeriodWall: CFAbsoluteTime = 0

            var firstVideoPTSForDiag: TimeInterval?
            let videoTaskStartWall = CFAbsoluteTimeGetCurrent()

            for await payload in vStream {
                if Task.isCancelled { break }

                let packet = payload.packet
                let frameWallStart = payload.frameWallStart
                let videoPacketIndex = payload.videoPacketIndex
                let ptsSeconds = packet.ptsSeconds

                if firstVideoPTSForDiag == nil {
                    firstVideoPTSForDiag = ptsSeconds
                    healthLastPeriodPTS = ptsSeconds
                    healthLastPeriodWall = frameWallStart
                    lastHealthReportWall = frameWallStart
                }

                // 1. Late-frame check.
                // Uses the CURRENT renderer.currentTime (after any time spent
                // in the gate / earlier task work), so it reflects what's
                // actually about to be enqueued — more accurate than checking
                // at read time.
                let elapsedSinceTaskStart = CFAbsoluteTimeGetCurrent() - videoTaskStartWall
                let inGracePeriod = elapsedSinceTaskStart < startupGracePeriod

                var droppedThisIteration = false

                if !taskFirstFrame && !inGracePeriod {
                    // renderer.currentTime is nonisolated — no MainActor hop needed.
                    let syncTime = renderer.currentTime
                    let lateness = syncTime - ptsSeconds
                    if lateness > lateVideoDropThreshold {
                        lateVideoObservationCount += 1
                        healthLateFramesSinceReport += 1
                        consecutiveLateVideoFrames += 1

                        let nowWall = CFAbsoluteTimeGetCurrent()
                        let keyframeResyncThreshold = hasDV ? 48 : 4
                        let wantsKeyframeResync = packet.isKeyframe && consecutiveLateVideoFrames >= keyframeResyncThreshold
                        let wantsForcedResync = lateness > forceLateResyncThreshold ||
                            consecutiveLateVideoFrames >= maxConsecutiveLateFramesBeforeResync
                        let canResync = nowWall - lastLateVideoResyncWall >= lateResyncCooldown
                        var didResync = false

                        if (wantsKeyframeResync || wantsForcedResync) && canResync {
                            let resyncRate = await MainActor.run { [weak self] in
                                guard let self else { return Float?.none }
                                let rate = self.isPlaying ? self.playbackRate : Float(0)
                                renderer.setRate(rate, time: packet.cmPTS)
                                return rate
                            }

                            if let resyncRate {
                                lateVideoResyncCount += 1
                                healthResyncsSinceReport += 1
                                lastLateVideoResyncWall = nowWall

                                if lateVideoResyncCount <= 10 || lateVideoResyncCount % 60 == 0 {
                                    playerDebugLog("[DirectPlayDiag] Late-video resync #\(lateVideoResyncCount): " +
                                          "rate=\(String(format: "%.2f", resyncRate)) " +
                                          "pts=\(String(format: "%.3f", ptsSeconds))s " +
                                          "sync=\(String(format: "%.3f", syncTime))s " +
                                          "lateness=\(String(format: "%.0f", lateness * 1000))ms " +
                                          "lateBurst=\(consecutiveLateVideoFrames) keyframe=\(packet.isKeyframe)")
                                }
                                consecutiveLateVideoFrames = 0
                                didResync = true
                            }
                        }

                        if !didResync {
                            let shouldSoftDrop = !packet.isKeyframe &&
                                lateness >= softLateDropThreshold &&
                                consecutiveLateVideoFrames <= maxSoftLateDropsPerBurst

                            if shouldSoftDrop {
                                lateVideoDropCount += 1
                                lateVideoSoftDropCount += 1
                                healthDropsSinceReport += 1
                                if lateVideoSoftDropCount <= 10 || lateVideoSoftDropCount % 120 == 0 {
                                    playerDebugLog("[DirectPlayDiag] Soft drop late video #\(lateVideoSoftDropCount): " +
                                          "pts=\(String(format: "%.3f", ptsSeconds))s " +
                                          "sync=\(String(format: "%.3f", syncTime))s " +
                                          "lateness=\(String(format: "%.0f", lateness * 1000))ms " +
                                          "burst=\(consecutiveLateVideoFrames) keyframe=\(packet.isKeyframe)")
                                }
                                droppedThisIteration = true
                            } else if lateVideoObservationCount <= 10 || lateVideoObservationCount % 120 == 0 {
                                playerDebugLog("[DirectPlayDiag] Late video frame #\(lateVideoObservationCount): " +
                                      "pts=\(String(format: "%.3f", ptsSeconds))s " +
                                      "sync=\(String(format: "%.3f", syncTime))s " +
                                      "lateness=\(String(format: "%.0f", lateness * 1000))ms " +
                                      "burst=\(consecutiveLateVideoFrames) keyframe=\(packet.isKeyframe)")
                            }
                        }

                        // Emergency hard drop for extremely stale frames
                        if !droppedThisIteration && lateness > 4.0 {
                            lateVideoDropCount += 1
                            healthDropsSinceReport += 1
                            if lateVideoDropCount <= 10 || lateVideoDropCount % 60 == 0 {
                                playerDebugLog("[DirectPlayDiag] Emergency drop #\(lateVideoDropCount): " +
                                      "pts=\(String(format: "%.3f", ptsSeconds))s " +
                                      "sync=\(String(format: "%.3f", syncTime))s " +
                                      "lateness=\(String(format: "%.0f", lateness * 1000))ms")
                            }
                            droppedThisIteration = true
                        }
                    } else if consecutiveLateVideoFrames > 0 {
                        if consecutiveLateVideoFrames >= 8 {
                            playerDebugLog("[DirectPlayDiag] Late-video burst recovered after \(consecutiveLateVideoFrames) frames")
                        }
                        consecutiveLateVideoFrames = 0
                    }
                }

                if droppedThisIteration {
                    videoGateLocal.completeOne()
                    taskFirstFrame = false
                    taskFramesProcessed += 1
                    continue
                }

                // 2. DV conversion (RPU + EL strip; ~0.7 ms/frame for P8 direct,
                //    can be 10–50 ms/frame for P7 conversion)
                let conversionStart = CFAbsoluteTimeGetCurrent()
                var packetData = packet.data
                if requiresConversion && !conversionDisabled, let converter = profileConverter {
                    packetData = converter.processVideoSample(packetData)

                    if converter.framesConverted == 48 {
                        if !converter.canSustainRealTime() {
                            conversionDisabled = true
                            playerDebugLog("[DirectPlay] DV conversion too slow " +
                                  "(avg=\(String(format: "%.1f", converter.averageConversionTimeMs))ms/frame, " +
                                  "budget=41.7ms), switching to HDR10 passthrough")
                        } else {
                            playerDebugLog("[DirectPlay] DV conversion sustaining realtime " +
                                  "(avg=\(String(format: "%.1f", converter.averageConversionTimeMs))ms/frame)")
                        }
                    }
                }
                let conversionEnd = CFAbsoluteTimeGetCurrent()

                // 3. Sample buffer creation
                let sampleCreateStart = CFAbsoluteTimeGetCurrent()
                let processedPacket = DemuxedPacket(
                    streamIndex: packet.streamIndex,
                    trackType: packet.trackType,
                    data: packetData,
                    pts: packet.pts, dts: packet.dts,
                    duration: packet.duration,
                    timebase: packet.timebase,
                    isKeyframe: packet.isKeyframe
                )
                let effectiveVideoFD = hasDV ? (demuxer.videoFormatDescription ?? videoFD) : videoFD
                let sampleBuffer: CMSampleBuffer
                do {
                    sampleBuffer = try demuxer.createVideoSampleBuffer(
                        from: processedPacket,
                        formatDescription: effectiveVideoFD
                    )
                } catch {
                    playerDebugLog("[DirectPlay] Failed to create video sample buffer for frame \(videoPacketIndex): \(error)")
                    videoGateLocal.completeOne()
                    taskFirstFrame = false
                    taskFramesProcessed += 1
                    continue
                }
                let sampleCreateEnd = CFAbsoluteTimeGetCurrent()

                // 4-6. Combined MainActor entry: jitter stats + enqueueVideo +
                //      post-enqueue state. Folded into a single hop to halve
                //      MainActor entries from 3 to 1 per frame (reduces audio
                //      task starvation under contention). The seek→running
                //      transition only fires once per playback session, so
                //      after the first observed-running frame we skip its
                //      branch entirely. The display-layer-error check is
                //      cheap and stays inside the hop.
                let syncPrepStart = CFAbsoluteTimeGetCurrent()
                let needsSeekToRunningTransition = !hasObservedRunning
                let displayErrorReport: String? = await MainActor.run { [weak self] () -> String? in
                    renderer.jitterStats.recordVideoPTS(ptsSeconds)
                    if needsSeekToRunningTransition, let self {
                        if self.state == .seeking && self.isPlaying {
                            self.state = .running
                            self.onStateChange?(.running)
                        }
                    }
                    return renderer.displayLayerError?.localizedDescription
                }
                let syncPrepEnd = CFAbsoluteTimeGetCurrent()
                let mainActorHopMs = (syncPrepEnd - syncPrepStart) * 1000

                if displayErrorReport != nil {
                    playerDebugLog("[DirectPlay] Display layer error after frame \(videoPacketIndex): \(displayErrorReport ?? "unknown")")
                    healthDisplayErrorsSinceReport += 1
                }

                // 5. Enqueue. May block on lookahead pacing or display layer
                //    backpressure — but only blocks THIS task, not the read loop.
                let enqueueStart = CFAbsoluteTimeGetCurrent()
                await renderer.enqueueVideo(sampleBuffer, bypassLookahead: false)
                let enqueueEnd = CFAbsoluteTimeGetCurrent()
                let enqueueOnlyMs = (enqueueEnd - enqueueStart) * 1000
                let enqueueMs = (enqueueEnd - syncPrepStart) * 1000
                if enqueueMs > 100 {
                    playerDebugLog("[VideoTask] enqueue stall=\(String(format: "%.0f", enqueueMs))ms mainActorHop=\(String(format: "%.0f", mainActorHopMs))ms enqueueVideo=\(String(format: "%.0f", enqueueOnlyMs))ms frame=\(videoPacketIndex) pts=\(String(format: "%.3f", ptsSeconds))s")
                }

                // After the first frame is enqueued post-preroll, the pipeline
                // is in .running. Skip the state-transition branch on subsequent
                // frames so we don't hop into MainActor for a no-op check.
                hasObservedRunning = true

                // 7. Timing accumulators
                let totalPipelineMs = (enqueueEnd - frameWallStart) * 1000
                if totalPipelineMs > 120 {
                    slowVideoPipelineCount += 1
                    healthSlowFramesSinceReport += 1
                }

                if lastVideoEnqueueEnd > 0 {
                    timingReadGapMs += (frameWallStart - lastVideoEnqueueEnd) * 1000
                }
                timingConversionMs += (conversionEnd - conversionStart) * 1000
                timingSampleMs += (sampleCreateEnd - sampleCreateStart) * 1000
                timingSyncMs += (syncPrepEnd - syncPrepStart) * 1000
                timingEnqueueMs += enqueueMs
                timingTotalMs += totalPipelineMs
                timingFrameCount += 1
                lastVideoEnqueueEnd = enqueueEnd

                if timingFrameCount == 120 {
                    let n = Double(timingFrameCount)
                    playerDebugLog("[DirectPlayTiming] \(timingFrameCount)f avg: " +
                          "readGap=\(String(format: "%.1f", timingReadGapMs/n))ms " +
                          "convert=\(String(format: "%.1f", timingConversionMs/n))ms " +
                          "sample=\(String(format: "%.1f", timingSampleMs/n))ms " +
                          "sync=\(String(format: "%.1f", timingSyncMs/n))ms " +
                          "enqueue=\(String(format: "%.1f", timingEnqueueMs/n))ms " +
                          "total=\(String(format: "%.1f", timingTotalMs/n))ms " +
                          "budget=\(String(format: "%.1f", 1000.0/24.0))ms")
                    timingReadGapMs = 0; timingConversionMs = 0; timingSampleMs = 0
                    timingSyncMs = 0; timingEnqueueMs = 0; timingTotalMs = 0
                    timingFrameCount = 0
                }

                // 8. Wall-clock cadence tracking
                let nowWall = CFAbsoluteTimeGetCurrent()
                if let prev = lastVideoWallTime {
                    let wallGapMs = (nowWall - prev) * 1000
                    if wallGapMs > maxVideoWallGapMs {
                        maxVideoWallGapMs = wallGapMs
                    }
                    if wallGapMs > 120 {
                        longVideoWallGaps += 1
                    }
                }
                lastVideoWallTime = nowWall

                // 9. Periodic [DirectPlayDiag] (every 240 task frames)
                taskFramesProcessed += 1
                if taskFramesProcessed % 240 == 0 {
                    // renderer.currentTime is nonisolated — no MainActor hop needed
                    let syncTime = renderer.currentTime
                    let syncMinusPTS = (syncTime - ptsSeconds) * 1000
                    let elapsedWall = nowWall - videoTaskStartWall
                    let streamElapsed = firstVideoPTSForDiag.map { ptsSeconds - $0 } ?? 0
                    let playbackRateVsWall = elapsedWall > 0 ? (streamElapsed / elapsedWall) : 0
                    let audioSnapshot = audioGate?.snapshot()
                    let audioDecodeSnapshot = audioDecodeGate?.snapshot()
                    let videoSnapshot = videoGateLocal.snapshot()
                    let audioQueueDepth = audioSnapshot?.pending ?? -1
                    let audioQueueMaxDepth = audioSnapshot?.maxPending ?? -1
                    let audioQueueDrops = audioSnapshot?.dropped ?? -1
                    let audioDecodeQueueDepth = audioDecodeSnapshot?.pending ?? -1
                    let audioDecodeQueueMaxDepth = audioDecodeSnapshot?.maxPending ?? -1
                    let audioDecodeQueueDrops = audioDecodeSnapshot?.dropped ?? -1

                    playerDebugLog(
                        "[DirectPlayDiag] v=\(videoPacketIndex) " +
                        "pts=\(String(format: "%.3f", ptsSeconds))s sync=\(String(format: "%.3f", syncTime))s " +
                        "sync-pts=\(String(format: "%.0f", syncMinusPTS))ms " +
                        "media/wall=\(String(format: "%.3f", playbackRateVsWall))x " +
                        "audioQ=\(audioQueueDepth) maxGap=\(String(format: "%.0f", maxVideoWallGapMs))ms " +
                        "videoQ=\(videoSnapshot.pending) maxVideoQ=\(videoSnapshot.maxPending) " +
                        "videoDrops=\(videoSnapshot.dropped) videoKfDrops=\(videoSnapshot.keyframesDropped) " +
                        "maxAudioQ=\(audioQueueMaxDepth) audioQDrops=\(audioQueueDrops) " +
                        "audioDecQ=\(audioDecodeQueueDepth) maxAudioDecQ=\(audioDecodeQueueMaxDepth) " +
                        "audioDecDrops=\(audioDecodeQueueDrops) " +
                        "longGaps=\(longVideoWallGaps) lateObs=\(lateVideoObservationCount) " +
                        "lateDrops=\(lateVideoDropCount) lateSoftDrops=\(lateVideoSoftDropCount) " +
                        "lateBurst=\(consecutiveLateVideoFrames) " +
                        "lateResyncs=\(lateVideoResyncCount) slowFrames=\(slowVideoPipelineCount)"
                    )
                }

                // 10. Periodic [PlaybackHealth] (every 5s wall time)
                if nowWall - lastHealthReportWall >= healthReportInterval {
                    let periodWall = nowWall - healthLastPeriodWall
                    let periodStream = ptsSeconds - healthLastPeriodPTS
                    let wallRate = periodWall > 0 ? (periodStream / periodWall) : 1.0
                    let audioSnapshot = audioGate?.snapshot()
                    let audioDrops = audioSnapshot?.dropped ?? 0
                    let capturedLate = healthLateFramesSinceReport
                    let capturedDrops = healthDropsSinceReport
                    let capturedResyncs = healthResyncsSinceReport
                    let capturedSlow = healthSlowFramesSinceReport
                    let capturedDispErr = healthDisplayErrorsSinceReport

                    let isClientDecode = audioDecoder != nil
                    let healthResult = await MainActor.run { [weak self] () -> (line: String, totalPullDel: Int)? in
                        guard let self else { return nil }
                        let jitter = self.renderer.jitterStats.healthSnapshot()
                        let status = Int(self.renderer.audioRenderer.status.rawValue)
                        let isPull = self.renderer.useAudioPullMode
                        let syncTime = self.renderer.currentTime
                        let audioAhead = ptsSeconds - syncTime
                        let dispErr = (self.renderer.displayLayerError != nil ? 1 : 0) + capturedDispErr
                        let totalPullDel = self.renderer.totalAudioPullDeliveries
                        let pullDel = totalPullDel - healthLastPullDeliveries
                        let isAirPlay = PlaybackAudioSessionConfigurator.isAirPlayRouteActive()
                        let report = PlaybackHealthReport(
                            playbackTime: ptsSeconds,
                            fps: jitter.fps,
                            wallRate: wallRate,
                            lateFrames: capturedLate,
                            droppedFrames: capturedDrops,
                            resyncs: capturedResyncs,
                            slowFrames: capturedSlow,
                            audioStatus: status,
                            audioPullMode: isPull,
                            audioAhead: audioAhead,
                            audioDrops: audioDrops,
                            audioPath: isClientDecode ? .clientDecode : .passthrough,
                            audioRoute: isAirPlay ? .airPlay : .hdmi,
                            audioPullDeliveries: pullDel,
                            displayErrors: dispErr,
                            gapMaxMs: jitter.gapMaxMs,
                            gapStdDevMs: jitter.gapStdDevMs,
                            syncDriftPercent: jitter.syncDriftPercent
                        )
                        return (report.logLine, totalPullDel)
                    }

                    if let result = healthResult {
                        playerDebugLog(result.line)
                        healthLastPullDeliveries = result.totalPullDel
                    }

                    healthLateFramesSinceReport = 0
                    healthDropsSinceReport = 0
                    healthResyncsSinceReport = 0
                    healthSlowFramesSinceReport = 0
                    healthDisplayErrorsSinceReport = 0
                    healthLastPeriodPTS = ptsSeconds
                    healthLastPeriodWall = nowWall
                    lastHealthReportWall = nowWall
                }

                taskFirstFrame = false
                videoGateLocal.completeOne()
            }

            // Loop exit summary
            let summary = videoGateLocal.snapshot()
            playerDebugLog("[DirectPlay] Video task exiting: processed=\(taskFramesProcessed) " +
                  "maxVideoQ=\(summary.maxPending) videoDrops=\(summary.dropped) " +
                  "videoKfDrops=\(summary.keyframesDropped) " +
                  "lateObs=\(lateVideoObservationCount) lateDrops=\(lateVideoDropCount) " +
                  "lateResyncs=\(lateVideoResyncCount) slowFrames=\(slowVideoPipelineCount) " +
                  "maxWallGap=\(String(format: "%.0f", maxVideoWallGapMs))ms longGaps=\(longVideoWallGaps)")
        }

        let localVideoEnqueueTask = videoEnqueueTask

        readTask = Task.detached { [weak self] in
            playerDebugLog("[DirectPlay] Read loop started on background thread")
            playerDebugLog("[PlaybackHealth] CONFIG hasDV=\(hasDV) conversion=\(requiresConversion) " +
                  "lookahead=\(String(format: "%.1f", capturedLookahead))s " +
                  "audioDecoder=\(audioDecoder != nil) container=\(capturedContainer)")

            // The read loop is now a thin packet shuttler. Per-frame video state
            // (late counters, timing accumulators, health report, cadence tracking,
            // conversion fallback flag) lives in the videoEnqueueTask above. The
            // read loop only tracks counters needed for the audio path and the
            // inline preroll / paused-seek code paths.
            var isFirstVideoFrame = true
            var videoPacketCount = 0
            var audioPacketCount = 0

            // Per-period throughput counters — emitted every 2 seconds so we
            // can distinguish network bottlenecks (low read rate) from
            // downstream bottlenecks (audio task not draining / audio gate
            // dropping / video task stalling).
            var throughputVideoReadsSincePeriod = 0
            var throughputAudioReadsSincePeriod = 0
            var throughputAvReadTotalMs: Double = 0
            var throughputAvReadMaxMs: Double = 0
            var throughputBytesSincePeriod = 0
            var throughputLastLogWall = CFAbsoluteTimeGetCurrent()
            // Conversion fallback flag for the inline preroll / paused-seek
            // paths only. The video task has its own copy; both observe the
            // same shared `converter.framesConverted` counter, so whichever
            // path hits frame 48 first triggers the auto-fallback.
            var conversionDisabled = false

            var waitingForPrerollStart = false
            var prerollWaitStartWall: CFAbsoluteTime?
            var prerollAnchorPTSSeconds: Double?
            var prerollAnchorTime: CMTime?
            var prerollMaxPTSSeconds: Double?
            var prerollMaxVideoPTSSeconds: Double?  // Video-only PTS for accurate preroll lead
            let hasAudioPath = (audioDecoder != nil || audioFD != nil)

            let maybePrimePrerollTimeline: @Sendable (Double, CMTime, String) async -> Void = { ptsSeconds, ptsTime, source in
                guard ptsSeconds.isFinite, ptsSeconds >= 0 else { return }
                guard !waitingForPrerollStart else { return }

                let decision = await MainActor.run { [weak self] () -> (shouldPreroll: Bool, label: String)? in
                    guard let self else { return nil }

                    if self.needsInitialSync {
                        self.needsInitialSync = false
                        renderer.setRate(0, time: ptsTime)
                        return (self.isPlaying, "Initial sync")
                    }

                    if self.needsRateRestoreAfterSeek {
                        self.needsRateRestoreAfterSeek = false
                        renderer.setRate(0, time: ptsTime)
                        return (self.isPlaying, "Post-seek sync")
                    }

                    return nil
                }

                guard let decision else { return }

                playerDebugLog(
                    "[DirectPlay] \(decision.label): setting rate=0.0 " +
                    "time=\(String(format: "%.3f", ptsSeconds))s " +
                    "(preroll=\(decision.shouldPreroll), source=\(source))"
                )

                if decision.shouldPreroll {
                    waitingForPrerollStart = true
                    prerollWaitStartWall = CFAbsoluteTimeGetCurrent()
                    prerollAnchorPTSSeconds = ptsSeconds
                    prerollAnchorTime = ptsTime
                    prerollMaxPTSSeconds = ptsSeconds
                }
            }

            let maybeCompletePrerollStart: @Sendable (Double?, Bool) async -> Bool = { currentPTSSeconds, audioReadyOverride in
                guard waitingForPrerollStart else { return false }

                let audioPrimed = await MainActor.run {
                    renderer.isAudioPrimedForPlayback
                }
                let audioReliableStart = await MainActor.run {
                    renderer.hasReliableAudioStart
                }
                let audioReady = audioReadyOverride || !hasAudioPath || audioPrimed
                let prerollLeadSeconds: Double = {
                    guard let anchor = prerollAnchorPTSSeconds, let maxPTS = prerollMaxPTSSeconds else { return 0 }
                    return max(0, maxPTS - anchor)
                }()
                // Use video-only PTS for videoReady check — audio PTS can race ahead
                // and cause preroll to complete with insufficient video buffer.
                let videoLeadSeconds: Double = {
                    guard let anchor = prerollAnchorPTSSeconds, let maxVPTS = prerollMaxVideoPTSSeconds else { return 0 }
                    return max(0, maxVPTS - anchor)
                }()
                // Required video lead before the clock starts. DV/HDR content from Plex
                // takes ~10 s for the HTTP read loop to warm up; during that warmup the
                // read loop sustains roughly 0.4–0.82× realtime, so a too-small lead is
                // depleted before the network reaches steady state and the audio renderer
                // underruns. Aim for enough buffer to bridge the entire warmup phase
                // (warmup_seconds × (1 - average_warmup_rate) ≈ 3 s).
                let requiredPrerollLeadSeconds: Double = {
                    if requiresConversion { return 5.0 }
                    if hasDV { return 3.0 }
                    return 0.20
                }()
                let videoReady = videoLeadSeconds >= requiredPrerollLeadSeconds
                let waitedMs: Double = {
                    guard let start = prerollWaitStartWall else { return 0 }
                    return (CFAbsoluteTimeGetCurrent() - start) * 1000
                }()
                // Timeout = enough wall time to actually buffer the requested lead at the
                // worst-case warmup rate (~0.4×), so the lead requirement isn't bypassed
                // by a too-aggressive timeout.
                let prerollTimeout: Double = {
                    if requiresConversion { return 12000 }
                    if hasDV { return 10000 }
                    return 1000
                }()
                let timedOut = hasAudioPath && waitedMs >= prerollTimeout

                if timedOut {
                    playerDebugLog("[DirectPlay] Preroll timeout after \(String(format: "%.0f", waitedMs))ms " +
                          "(audioReady=\(audioReady) reliableStart=\(audioReliableStart) videoReady=\(videoReady) " +
                          "lead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms " +
                          "need=\(String(format: "%.0f", requiredPrerollLeadSeconds * 1000))ms)")
                }

                guard (audioReady && videoReady) || timedOut else { return false }

                let startedRate = await MainActor.run { [weak self] () -> (Float, Double, String)? in
                    guard let self else { return nil }
                    let shouldStartPlayback = (self.state == .running) || self.isPlaying
                    guard shouldStartPlayback else { return nil }
                    let rate = self.playbackRate
                    let anchorTime = prerollAnchorTime ?? CMTime(
                        seconds: prerollAnchorPTSSeconds ?? renderer.currentTime,
                        preferredTimescale: 90_000
                    )
                    let anchorSeconds = prerollAnchorPTSSeconds ?? CMTimeGetSeconds(anchorTime)
                    // Use 2-arg setRate so the synchronizer chooses its own
                    // start timing. On AirPlay the synchronizer knows the
                    // transport latency and aligns the clock with when audio
                    // actually reaches the speaker. A forced atHostTime with a
                    // short hostLead (100 ms) starts the video clock before the
                    // AirPlay buffer is filled, producing a perceptible
                    // audio-behind-video offset after pause/resume.
                    renderer.setRate(rate, time: anchorTime)
                    let reason = timedOut ? "timeout" : "audio+video_primed"
                    return (rate, anchorSeconds, reason)
                }

                guard let started = startedRate else { return false }

                let (playbackRate, anchorTime, reason) = started
                let packetTime = currentPTSSeconds ?? prerollMaxPTSSeconds ?? anchorTime
                waitingForPrerollStart = false
                prerollWaitStartWall = nil
                prerollAnchorPTSSeconds = nil
                prerollAnchorTime = nil
                prerollMaxPTSSeconds = nil
                prerollMaxVideoPTSSeconds = nil
                playerDebugLog(
                    "[DirectPlay] Preroll complete: starting clock from anchor=\(String(format: "%.3f", anchorTime))s " +
                    "packet=\(String(format: "%.3f", packetTime))s rate=\(String(format: "%.2f", playbackRate)) " +
                    "reason=\(reason) wait=\(String(format: "%.0f", waitedMs))ms " +
                    "lead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms"
                )
                playerDebugLog("[PlaybackHealth] EVENT=preroll_complete elapsed=\(String(format: "%.0f", waitedMs))ms")

                // Emit any .running state change that fresh start() deferred until
                // playback was actually visible. This dismisses the player loading
                // view at the same instant audio/video begins.
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if self.deferRunningStateChange {
                        self.deferRunningStateChange = false
                        playerDebugLog("[StartupTrace] deferred .running emitted (preroll done, audio+video flowing)")
                        self.onStateChange?(.running)
                    } else {
                        playerDebugLog("[StartupTrace] preroll done but no deferred .running (flag already cleared)")
                    }
                }

                return true
            }

            await MainActor.run {
                renderer.onAudioPrimedForPlayback = { deliveredPTSSeconds in
                    Task.detached {
                        _ = await maybeCompletePrerollStart(deliveredPTSSeconds, true)
                    }
                }
            }

            let enqueueAudioBuffer: @Sendable (CMSampleBuffer) async -> Void = { sampleBuffer in
                let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let samplePTSSeconds = CMTimeGetSeconds(samplePTS)

                // Skip the preroll-prime call entirely once preroll has
                // completed. The closure has its own early-return guard, but
                // the await suspension overhead is non-trivial at 30+ audio
                // packets/sec and adds to MainActor contention.
                if waitingForPrerollStart || audioPacketCount < 8 {
                    await maybePrimePrerollTimeline(samplePTSSeconds, samplePTS, "audio")
                }

                if waitingForPrerollStart,
                   let anchor = prerollAnchorPTSSeconds,
                   samplePTSSeconds.isFinite,
                   samplePTSSeconds + 0.05 < anchor {
                    let previousAnchor = anchor
                    prerollAnchorPTSSeconds = samplePTSSeconds
                    prerollAnchorTime = samplePTS
                    if let maxPTS = prerollMaxPTSSeconds {
                        prerollMaxPTSSeconds = max(maxPTS, samplePTSSeconds)
                    }
                    await MainActor.run {
                        renderer.setRate(0, time: samplePTS)
                    }
                    playerDebugLog(
                        "[DirectPlay] Preroll anchor adjusted for early audio sample: " +
                        "old=\(String(format: "%.3f", previousAnchor))s " +
                        "new=\(String(format: "%.3f", samplePTSSeconds))s " +
                        "delta=\(String(format: "%.0f", (previousAnchor - samplePTSSeconds) * 1000))ms"
                    )
                }

                if waitingForPrerollStart {
                    if let maxPTS = prerollMaxPTSSeconds {
                        prerollMaxPTSSeconds = max(maxPTS, samplePTSSeconds)
                    } else if samplePTSSeconds.isFinite {
                        prerollMaxPTSSeconds = samplePTSSeconds
                    }

                    await renderer.enqueueAudio(sampleBuffer)
                    _ = await maybeCompletePrerollStart(samplePTSSeconds, false)
                    return
                }

                if let localAudioContinuation, let localAudioGate {
                    let reservation = localAudioGate.reserveSlot()
                    if !reservation.accepted {
                        let dropped = reservation.dropped
                        if dropped <= 10 || dropped % 120 == 0 {
                            playerDebugLog("[DirectPlayDiag] Dropping queued audio sample #\(dropped) " +
                                  "(audioQ=\(reservation.depth), limit=\(localAudioGate.limit))")
                        }
                        return
                    }

                    guard !Task.isCancelled else { return }
                    localAudioContinuation.yield(sampleBuffer)
                } else {
                    await renderer.enqueueAudio(sampleBuffer)
                }
            }

            var localAudioDecodeTask: Task<Void, Never>?
            if let decoder = audioDecoder,
               let localAudioDecodeStream,
               let localAudioDecodeGate {
                if audioEncoder != nil {
                    playerDebugLog("[DirectPlayDiag] Audio transcode path active: decoder->EAC3 encoder " +
                          "encoderRate=\(activeAudioSampleRate)Hz encoderChannels=\(activeAudioChannels) " +
                          "routeTargetRate=\(activeTargetOutputSampleRate > 0 ? "\(activeTargetOutputSampleRate)" : "native")")
                }
                localAudioDecodeTask = Task.detached {
                    for await compressedPacket in localAudioDecodeStream {
                        guard !Task.isCancelled else { break }

                        let batchedFrames = decoder.decodeAndBatch(compressedPacket)
                        for batchedFrame in batchedFrames {
                            if let audioEncoder {
                                // Re-encode path: PCM -> EAC3
                                let encodedFrames = audioEncoder.encode(batchedFrame)
                                for encodedFrame in encodedFrames {
                                    if let sb = try? audioEncoder.createEAC3SampleBuffer(from: encodedFrame) {
                                        await enqueueAudioBuffer(sb)
                                    }
                                }
                            } else {
                                // Direct PCM path
                                if let sampleBuffer = try? decoder.createPCMSampleBuffer(from: batchedFrame) {
                                    await enqueueAudioBuffer(sampleBuffer)
                                }
                            }
                        }

                        localAudioDecodeGate.completeOne()
                    }

                    // Flush residual decoder batch on stream end.
                    if let remaining = decoder.flushBatch() {
                        if let audioEncoder {
                            let encodedFrames = audioEncoder.encode(remaining)
                            for encodedFrame in encodedFrames {
                                if let sb = try? audioEncoder.createEAC3SampleBuffer(from: encodedFrame) {
                                    await enqueueAudioBuffer(sb)
                                }
                            }
                            // Drain encoder's internal buffers
                            let flushed = audioEncoder.flush()
                            for encodedFrame in flushed {
                                if let sb = try? audioEncoder.createEAC3SampleBuffer(from: encodedFrame) {
                                    await enqueueAudioBuffer(sb)
                                }
                            }
                        } else {
                            if let sampleBuffer = try? decoder.createPCMSampleBuffer(from: remaining) {
                                await enqueueAudioBuffer(sampleBuffer)
                            }
                        }
                    }
                }
            }

            // Track loop exit reason for cleanup
            enum LoopExit { case eos, pausedSeek, error(Error), cancelled }
            var exitReason: LoopExit = .cancelled

            readLoop: while !Task.isCancelled {
                // Pause gate: suspend here (without polling) while transport
                // is paused. This prevents the demuxer from drifting forward
                // while the renderer synchronizer is frozen at rate=0, which
                // would otherwise fill the video gate, shed non-keyframe
                // references, and produce chunky/pixelated decode on resume.
                //
                // The flag is nonisolated(unsafe) and cheaply read per
                // iteration; `waitForResume()` re-validates the paused state
                // under MainActor isolation before stashing a continuation.
                if self?.isPausedFlag == true {
                    await self?.waitForResume()
                    if Task.isCancelled { break readLoop }
                    continue
                }

                do {
                    // Measure av_read_frame wall time so we can see whether the
                    // read loop is starving on network I/O vs downstream work.
                    let readStartWall = CFAbsoluteTimeGetCurrent()
                    guard let packet = try demuxer.readPacket() else {
                        exitReason = .eos
                        break readLoop
                    }
                    let readEndWall = CFAbsoluteTimeGetCurrent()
                    let readMs = (readEndWall - readStartWall) * 1000
                    throughputAvReadTotalMs += readMs
                    if readMs > throughputAvReadMaxMs {
                        throughputAvReadMaxMs = readMs
                    }
                    throughputBytesSincePeriod += packet.data.count

                    // Read-loop rate throttle. Without this, a fast network
                    // (ethernet on this Apple TV runs ~900 Mbps — 14× realtime
                    // for a 63 Mbps stream) lets the read loop pull content
                    // faster than the video pipeline can render it, which
                    // saturates the display layer and forces multi-second
                    // enqueue stalls. The threshold is tuned to keep us
                    // slightly ahead of what AVSampleBufferDisplayLayer can
                    // actually hold in its internal queue for 4K HEVC on tvOS
                    // (empirically ~3–5 s). Preroll bypasses the throttle so
                    // the initial buffer still fills quickly.
                    if !waitingForPrerollStart {
                        let renderedNow = renderer.currentTime
                        if renderedNow > 0.1 {
                            let ahead = packet.ptsSeconds - renderedNow
                            // Throttle at 0.8 s ahead. AVSampleBufferDisplayLayer's
                            // effective forward acceptance window for 4K HEVC on
                            // tvOS is ~1.0 s — frames queued further ahead get
                            // refused until the clock catches up. Measured by
                            // instrumenting isReadyForMoreMediaData waits: every
                            // stall exited when the frame was ~0.9 s ahead of
                            // the synchronizer. 0.8 s keeps the pipeline buffer
                            // below the layer's cap with a small safety margin.
                            let throttleThreshold: TimeInterval = 0.8
                            if ahead > throttleThreshold {
                                let napSeconds = min(ahead - throttleThreshold, 0.05)
                                try? await Task.sleep(nanoseconds: UInt64(napSeconds * 1_000_000_000))
                            }
                        }
                    }

                    // Emit throughput log every 2 seconds so we can see read-
                    // rate vs consumer-rate separation in real time.
                    if readEndWall - throughputLastLogWall >= 2.0 {
                        let elapsed = readEndWall - throughputLastLogWall
                        let totalReads = throughputVideoReadsSincePeriod + throughputAudioReadsSincePeriod
                        let avgReadMs = totalReads > 0 ? throughputAvReadTotalMs / Double(totalReads) : 0
                        let mbps = (Double(throughputBytesSincePeriod) * 8 / 1_000_000) / elapsed
                        playerDebugLog("[ReadLoopThroughput] elapsed=\(String(format: "%.2f", elapsed))s " +
                              "video=\(throughputVideoReadsSincePeriod) audio=\(throughputAudioReadsSincePeriod) " +
                              "videoRate=\(String(format: "%.1f", Double(throughputVideoReadsSincePeriod) / elapsed))/s " +
                              "audioRate=\(String(format: "%.1f", Double(throughputAudioReadsSincePeriod) / elapsed))/s " +
                              "avReadAvg=\(String(format: "%.2f", avgReadMs))ms " +
                              "avReadMax=\(String(format: "%.1f", throughputAvReadMaxMs))ms " +
                              "bytes=\(throughputBytesSincePeriod) " +
                              "Mbps=\(String(format: "%.1f", mbps))")
                        throughputVideoReadsSincePeriod = 0
                        throughputAudioReadsSincePeriod = 0
                        throughputAvReadTotalMs = 0
                        throughputAvReadMaxMs = 0
                        throughputBytesSincePeriod = 0
                        throughputLastLogWall = readEndWall
                    }

                    switch packet.trackType {
                    case .video:
                        throughputVideoReadsSincePeriod += 1
                        let frameWallStart = CFAbsoluteTimeGetCurrent()
                        videoPacketCount += 1
                        let ptsSeconds = packet.ptsSeconds
                        if videoPacketCount == 1 {
                            playerDebugLog("[DirectPlay] First video packet: pts=\(ptsSeconds)s size=\(packet.data.count)B keyframe=\(packet.isKeyframe) tb=\(packet.timebase.timescale)")
                        } else if videoPacketCount % 500 == 0 {
                            playerDebugLog("[DirectPlay] Progress: \(videoPacketCount) video / \(audioPacketCount) audio packets, pts=\(String(format: "%.1f", ptsSeconds))s")
                        }

                        // bufferedTime tracks the demuxer's read position. Batch
                        // the MainActor hop to once every 30 frames (~1 second
                        // at 24-30 fps) — UI progress bars don't need higher
                        // precision and this removes 30+ hops/sec from the
                        // read-loop hot path, which was contending with the
                        // video task and audio task on MainActor.
                        if videoPacketCount % 30 == 0 {
                            await MainActor.run { [weak self] in
                                self?.bufferedTime = ptsSeconds
                            }
                        }

                        // Prime preroll timeline if needed. The closure has its
                        // own MainActor hop that early-returns post-preroll, but
                        // even the await itself has overhead — check the local
                        // flag first to skip it entirely on the hot path.
                        if waitingForPrerollStart || isFirstVideoFrame {
                            await maybePrimePrerollTimeline(ptsSeconds, packet.cmPTS, "video")
                        }

                        // ── Inline preroll path ──
                        // During preroll, run the entire video pipeline inline on
                        // the read loop (DV conversion → sample buffer → enqueue
                        // with bypassLookahead=true → preroll bookkeeping). This
                        // mirrors the audio enqueueAudioBuffer preroll bypass and
                        // keeps prerollAnchor*/prerollMax* state lock-free
                        // (single-thread access). Preroll is brief (~3-7s), so
                        // the brief duplication of conversion+sampleBuffer code
                        // here vs. the video task is acceptable.
                        if waitingForPrerollStart {
                            var packetData = packet.data
                            if requiresConversion && !conversionDisabled, let converter = profileConverter {
                                packetData = converter.processVideoSample(packetData)
                                if converter.framesConverted == 48 {
                                    if !converter.canSustainRealTime() {
                                        conversionDisabled = true
                                        playerDebugLog("[DirectPlay] DV conversion too slow " +
                                              "(avg=\(String(format: "%.1f", converter.averageConversionTimeMs))ms/frame, " +
                                              "budget=41.7ms), switching to HDR10 passthrough")
                                    } else {
                                        playerDebugLog("[DirectPlay] DV conversion sustaining realtime " +
                                              "(avg=\(String(format: "%.1f", converter.averageConversionTimeMs))ms/frame)")
                                    }
                                }
                            }

                            let processedPacket = DemuxedPacket(
                                streamIndex: packet.streamIndex,
                                trackType: packet.trackType,
                                data: packetData,
                                pts: packet.pts, dts: packet.dts,
                                duration: packet.duration,
                                timebase: packet.timebase,
                                isKeyframe: packet.isKeyframe
                            )

                            let effectiveVideoFD = hasDV ? (demuxer.videoFormatDescription ?? videoFD) : videoFD
                            let sampleBuffer = try demuxer.createVideoSampleBuffer(
                                from: processedPacket, formatDescription: effectiveVideoFD
                            )

                            await MainActor.run {
                                renderer.jitterStats.recordVideoPTS(ptsSeconds)
                            }

                            // Bypass lookahead during preroll: rate=0 means
                            // currentTime never advances, so the lookahead sleep
                            // would deadlock. Display layer's own backpressure
                            // still prevents overflow.
                            await renderer.enqueueVideo(sampleBuffer, bypassLookahead: true)

                            if let maxPTS = prerollMaxPTSSeconds {
                                prerollMaxPTSSeconds = max(maxPTS, ptsSeconds)
                            } else {
                                prerollMaxPTSSeconds = ptsSeconds
                            }
                            if let maxVPTS = prerollMaxVideoPTSSeconds {
                                prerollMaxVideoPTSSeconds = max(maxVPTS, ptsSeconds)
                            } else {
                                prerollMaxVideoPTSSeconds = ptsSeconds
                            }

                            let didStartPreroll = await maybeCompletePrerollStart(ptsSeconds, false)
                            if !didStartPreroll, (videoPacketCount <= 10 || videoPacketCount % 120 == 0) {
                                let audioPrimed = await MainActor.run {
                                    renderer.isAudioPrimedForPlayback
                                }
                                let audioReliableStart = await MainActor.run {
                                    renderer.hasReliableAudioStart
                                }
                                let audioReady = !hasAudioPath || audioPrimed
                                let prerollLeadSeconds: Double = {
                                    guard let anchor = prerollAnchorPTSSeconds, let maxPTS = prerollMaxPTSSeconds else { return 0 }
                                    return max(0, maxPTS - anchor)
                                }()
                                let requiredPrerollLeadSeconds: Double = {
                                    if requiresConversion { return 5.0 }
                                    if hasDV { return 3.0 }
                                    return 0.20
                                }()
                                let waitedMs: Double = {
                                    guard let start = prerollWaitStartWall else { return 0 }
                                    return (CFAbsoluteTimeGetCurrent() - start) * 1000
                                }()
                                playerDebugLog(
                                    "[DirectPlayDiag] Waiting for preroll start: frame=\(videoPacketCount) " +
                                    "pts=\(String(format: "%.3f", ptsSeconds))s audioQ=\(localAudioGate?.snapshot().pending ?? -1) " +
                                    "audioPrimed=\(audioPrimed) audioReady=\(audioReady) reliableStart=\(audioReliableStart) " +
                                    "videoLead=\(String(format: "%.0f", prerollLeadSeconds * 1000))ms " +
                                    "bypass=true " +
                                    "needLead=\(String(format: "%.0f", requiredPrerollLeadSeconds * 1000))ms " +
                                    "wait=\(String(format: "%.0f", waitedMs))ms"
                                )
                            }

                            isFirstVideoFrame = false
                            continue
                        }

                        // ── Paused-seek inline path ──
                        // After seek(to:isPlaying:false), the very first video
                        // frame must be enqueued inline so we can break the read
                        // loop synchronously (the consumer task can't break the
                        // loop). This is the only case where the read loop calls
                        // renderer.enqueueVideo directly post-preroll.
                        if isFirstVideoFrame {
                            let isPlayingNow = await MainActor.run { [weak self] () -> Bool in
                                self?.isPlaying ?? false
                            }
                            if !isPlayingNow {
                                var packetData = packet.data
                                if requiresConversion && !conversionDisabled, let converter = profileConverter {
                                    packetData = converter.processVideoSample(packetData)
                                }

                                let processedPacket = DemuxedPacket(
                                    streamIndex: packet.streamIndex,
                                    trackType: packet.trackType,
                                    data: packetData,
                                    pts: packet.pts, dts: packet.dts,
                                    duration: packet.duration,
                                    timebase: packet.timebase,
                                    isKeyframe: packet.isKeyframe
                                )

                                let effectiveVideoFD = hasDV ? (demuxer.videoFormatDescription ?? videoFD) : videoFD
                                let sampleBuffer = try demuxer.createVideoSampleBuffer(
                                    from: processedPacket, formatDescription: effectiveVideoFD
                                )

                                await MainActor.run {
                                    renderer.jitterStats.recordVideoPTS(ptsSeconds)
                                    renderer.setRate(0, time: packet.cmPTS)
                                }

                                await renderer.enqueueVideo(sampleBuffer, bypassLookahead: false)

                                await MainActor.run { [weak self] in
                                    guard let self else { return }
                                    if let layerError = renderer.displayLayerError {
                                        playerDebugLog("[DirectPlay] Display layer error after paused-seek frame \(videoPacketCount): \(layerError)")
                                    }
                                    self.state = .paused
                                    self.onStateChange?(.paused)
                                }
                                exitReason = .pausedSeek
                                break readLoop
                            }
                        }

                        // ── Normal path: yield to video task ──
                        // Keyframe-aware drop policy:
                        //  - Above 90% gate depth, shed non-keyframes pre-emptively
                        //    so we don't fill up and force a keyframe drop.
                        //  - At hard limit, briefly wait for a slot for keyframes
                        //    (50 ms); silently drop non-keyframes.
                        if localVideoGate.isApproachingLimit() && !packet.isKeyframe {
                            isFirstVideoFrame = false
                            continue
                        }

                        var reservation = localVideoGate.reserveSlot()
                        if !reservation.accepted {
                            if packet.isKeyframe {
                                let waitStart = CFAbsoluteTimeGetCurrent()
                                while CFAbsoluteTimeGetCurrent() - waitStart < 0.050 && !Task.isCancelled {
                                    try? await Task.sleep(nanoseconds: 5_000_000)
                                    let retry = localVideoGate.reserveSlot()
                                    if retry.accepted {
                                        reservation = retry
                                        break
                                    }
                                }
                                if !reservation.accepted {
                                    localVideoGate.recordKeyframeDrop()
                                    playerDebugLog("[VideoGate] keyframe DROPPED at depth=\(localVideoGate.snapshot().pending) frame=\(videoPacketCount)")
                                    isFirstVideoFrame = false
                                    continue
                                }
                            } else {
                                isFirstVideoFrame = false
                                continue
                            }
                        }

                        let payload = VideoTaskPayload(
                            packet: packet,
                            videoPacketIndex: videoPacketCount,
                            frameWallStart: frameWallStart
                        )
                        localVideoContinuation.yield(payload)
                        isFirstVideoFrame = false

                    case .audio:
                        audioPacketCount += 1
                        throughputAudioReadsSincePeriod += 1
                        if audioPacketCount == 1 {
                            let durationSeconds = CMTimeGetSeconds(packet.cmDuration)
                            let dtsSeconds = CMTimeGetSeconds(packet.cmDTS)
                            let durationLog = durationSeconds.isFinite ? String(format: "%.4f", durationSeconds) : "invalid"
                            let dtsLog = dtsSeconds.isFinite ? String(format: "%.3f", dtsSeconds) : "invalid"
                            playerDebugLog(
                                "[DirectPlay] First audio packet: pts=\(String(format: "%.3f", packet.ptsSeconds))s " +
                                "dts=\(dtsLog)s dur=\(durationLog)s size=\(packet.data.count)B tb=\(packet.timebase.timescale)" +
                                " decode=\(audioDecoder != nil ? "client" : "passthrough")"
                            )
                        }

                        if let decoder = audioDecoder {
                            if let localAudioDecodeContinuation, let localAudioDecodeGate {
                                let reservation = localAudioDecodeGate.reserveSlot()
                                if !reservation.accepted {
                                    let dropped = reservation.dropped
                                    if dropped <= 10 || dropped % 120 == 0 {
                                        playerDebugLog("[DirectPlayDiag] Dropping queued compressed audio packet #\(dropped) " +
                                              "(audioDecQ=\(reservation.depth), limit=\(localAudioDecodeGate.limit))")
                                    }
                                    continue
                                }

                                localAudioDecodeContinuation.yield(packet)
                            } else {
                                // Fallback if decode queue setup failed.
                                let batchedFrames = decoder.decodeAndBatch(packet)
                                for batchedFrame in batchedFrames {
                                    let sampleBuffer = try decoder.createPCMSampleBuffer(from: batchedFrame)
                                    await enqueueAudioBuffer(sampleBuffer)
                                }
                            }
                        } else {
                            // Passthrough: native codec (AAC, AC3, EAC3, etc.)
                            guard let audioFD else {
                                if audioPacketCount == 1 {
                                    playerDebugLog("[DirectPlay] Skipping audio — no format description")
                                }
                                continue
                            }
                            if audioPacketCount == 1 {
                                let mediaType = CMFormatDescriptionGetMediaType(audioFD)
                                let mediaSubType = CMFormatDescriptionGetMediaSubType(audioFD)
                                let subTypeStr = String(format: "%c%c%c%c",
                                    (mediaSubType >> 24) & 0xFF, (mediaSubType >> 16) & 0xFF,
                                    (mediaSubType >> 8) & 0xFF, mediaSubType & 0xFF)
                                playerDebugLog("[DirectPlay] Audio passthrough FD: mediaType=\(mediaType) subType=\(subTypeStr)(\(mediaSubType))")
                                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFD) {
                                    let a = asbd.pointee
                                    playerDebugLog("[DirectPlay] Audio passthrough ASBD: rate=\(Int(a.mSampleRate)) ch=\(a.mChannelsPerFrame) " +
                                          "bitsPerCh=\(a.mBitsPerChannel) framesPerPkt=\(a.mFramesPerPacket) " +
                                          "bytesPerFrame=\(a.mBytesPerFrame) bytesPerPkt=\(a.mBytesPerPacket) " +
                                          "formatID=\(a.mFormatID) formatFlags=\(a.mFormatFlags)")
                                }
                            }
                            let sampleBuffer = try demuxer.createAudioSampleBuffer(
                                from: packet, formatDescription: audioFD
                            )
                            await enqueueAudioBuffer(sampleBuffer)
                        }

                    case .subtitle:
                        if let decoder = await MainActor.run(body: { [weak self] in self?.subtitleDecoder }) {
                            // Bitmap subtitle (PGS, DVB-SUB)
                            if let frame = decoder.decode(packet) {
                                let cueId = await MainActor.run { [weak self] () -> Int in
                                    guard let self else { return 0 }
                                    let id = self.bitmapCueCounter
                                    self.bitmapCueCounter += 1
                                    return id
                                }
                                let cue = BitmapSubtitleCue(
                                    id: cueId,
                                    startTime: frame.startTime,
                                    endTime: frame.endTime,
                                    rects: frame.rects,
                                    referenceWidth: frame.referenceWidth,
                                    referenceHeight: frame.referenceHeight
                                )
                                await MainActor.run { [weak self] in
                                    self?.onBitmapSubtitleCue?(cue)
                                }
                            }
                        } else {
                            // Text subtitle (SRT, ASS embedded in MKV)
                            let rawText = String(data: packet.data, encoding: .utf8) ?? ""
                            let text = Self.cleanEmbeddedSubtitleText(rawText)
                            if !text.isEmpty {
                                let start = packet.ptsSeconds
                                let dur = Double(packet.duration) * Double(packet.timebase.value) / Double(packet.timebase.timescale)
                                let end = start + dur
                                if dur > 0 {
                                    await MainActor.run { [weak self] in
                                        self?.onSubtitleCue?(text, start, end)
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    exitReason = .error(error)
                    break readLoop
                }
            }

            // --- Cleanup ---
            let summaryAudio = localAudioGate?.snapshot()
            let summaryAudioDec = localAudioDecodeGate?.snapshot()
            let summaryVideo = localVideoGate.snapshot()
            let summaryMaxAudioQ = summaryAudio?.maxPending ?? -1
            let summaryAudioDrops = summaryAudio?.dropped ?? -1
            let summaryMaxAudioDecQ = summaryAudioDec?.maxPending ?? -1
            let summaryAudioDecDrops = summaryAudioDec?.dropped ?? -1
            playerDebugLog("[DirectPlay] Read loop exiting: reason=\(exitReason) video=\(videoPacketCount) audio=\(audioPacketCount)")
            playerDebugLog("[DirectPlayDiag] Read summary: " +
                  "maxAudioQ=\(summaryMaxAudioQ) audioQDrops=\(summaryAudioDrops) " +
                  "maxAudioDecQ=\(summaryMaxAudioDecQ) audioDecDrops=\(summaryAudioDecDrops) " +
                  "maxVideoQ=\(summaryVideo.maxPending) videoDrops=\(summaryVideo.dropped) " +
                  "videoKfDrops=\(summaryVideo.keyframesDropped)")

            // CRITICAL: finish ALL continuations before awaiting any tasks. If
            // any await happens before the corresponding continuation is
            // finished, the `for await` loop in that task never exits and we
            // hang here forever (and shutdown()/seek() also hang).
            localAudioDecodeContinuation?.finish()
            localAudioContinuation?.finish()
            localVideoContinuation.finish()

            await localAudioDecodeTask?.value
            await localAudioEnqueueTask?.value
            await localVideoEnqueueTask?.value

            await MainActor.run { [weak self] in
                renderer.onAudioPrimedForPlayback = nil
                self?.audioEnqueueTask = nil
                self?.videoEnqueueTask = nil
            }

            // Handle exit reason
            switch exitReason {
            case .eos:
                playerDebugLog("[DirectPlay] End of stream (video=\(videoPacketCount) audio=\(audioPacketCount) packets)")
                if !Task.isCancelled {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.isPlaying = false
                        self.state = .ended
                        self.onEndOfStream?()
                    }
                }
            case .error(let error):
                if !Task.isCancelled {
                    playerDebugLog("[DirectPlay] Read error: \(error)")
                    SentrySDK.capture(error: error) { scope in
                        scope.setTag(value: "direct_play", key: "component")
                        scope.setTag(value: "read_loop", key: "error_type")
                    }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.state = .failed(error.localizedDescription)
                        self.onError?(error)
                    }
                }
            case .pausedSeek:
                // Signal that resume() must restart the read loop
                await MainActor.run { [weak self] in
                    self?.readTask = nil
                }
            case .cancelled:
                break
            }
        }
    }

    // MARK: - Private: Track Population

    private func populateTrackInfo() {
        audioTracks = demuxer.audioTracks.enumerated().map { index, track in
            MediaTrack(
                id: Int(track.streamIndex),
                name: track.title ?? track.codecName.uppercased(),
                language: track.language.flatMap { languageName(from: $0) },
                languageCode: track.language,
                codec: track.codecName,
                isDefault: track.isDefault || index == 0,
                isForced: false,
                isHearingImpaired: false,
                channels: Int(track.channels)
            )
        }

        subtitleTracks = demuxer.subtitleTracks.enumerated().map { index, track in
            MediaTrack(
                id: Int(track.streamIndex),
                name: track.title ?? track.codecName.uppercased(),
                language: track.language.flatMap { languageName(from: $0) },
                languageCode: track.language,
                codec: track.codecName,
                isDefault: track.isDefault,
                isForced: false,
                isHearingImpaired: false
            )
        }
    }

    /// Convert ISO 639-2 language code to display name
    private func languageName(from code: String) -> String {
        let locale = Locale(identifier: "en")
        return locale.localizedString(forLanguageCode: code) ?? code
    }

    private func codecNeedsClientDecode(_ codec: String) -> Bool {
        if forceClientDecodeAllAudio { return true }
        if Self.codecSet(forceClientDecodeCodecs, matches: codec) {
            return true
        }
        return Self.codecSet(FFmpegAudioDecoder.supportedCodecs, matches: codec)
    }

    private func preferredNativeAudioTrack(preferredLanguage: String?) -> FFmpegTrackInfo? {
        let nativeCandidates = demuxer.audioTracks.filter { track in
            !codecNeedsClientDecode(track.codecName) && codecIsLikelyNative(track.codecName)
        }
        guard !nativeCandidates.isEmpty else { return nil }

        let languageScoped: [FFmpegTrackInfo]
        if let preferredLanguage {
            let matches = nativeCandidates.filter { $0.language == preferredLanguage }
            languageScoped = matches.isEmpty ? nativeCandidates : matches
        } else {
            languageScoped = nativeCandidates
        }

        return languageScoped.max(by: { nativeTrackScore($0) < nativeTrackScore($1) })
    }

    /// Whether a codec requires heavy CPU-intensive FFmpeg decode (TrueHD, DTS-HD).
    /// These bottleneck the read loop on 4K DV content.
    private func codecIsHeavyDecode(_ codec: String) -> Bool {
        let normalized = Self.normalizedCodecIdentifier(codec)
        let heavy = ["truehd", "mlp", "dts", "dca", "dtshd"]
        return heavy.contains(where: { normalized == $0 || normalized.hasPrefix($0) })
    }

    /// Find a lighter audio track for DV throughput. Prefers same language,
    /// prioritizes EAC3 > AC3 > AAC by channel count.
    private func preferredLighterAudioTrack(than current: FFmpegTrackInfo) -> FFmpegTrackInfo? {
        let candidates = demuxer.audioTracks.filter { track in
            track.streamIndex != current.streamIndex && !codecIsHeavyDecode(track.codecName)
        }
        guard !candidates.isEmpty else { return nil }

        // Prefer same language
        let languageScoped: [FFmpegTrackInfo]
        if let lang = current.language {
            let matches = candidates.filter { $0.language == lang }
            languageScoped = matches.isEmpty ? candidates : matches
        } else {
            languageScoped = candidates
        }

        // Score: prefer surround > stereo, EAC3 > AC3 > AAC
        return languageScoped.max(by: { lighterTrackScore($0) < lighterTrackScore($1) })
    }

    private func lighterTrackScore(_ track: FFmpegTrackInfo) -> Int {
        let normalized = Self.normalizedCodecIdentifier(track.codecName)
        var score = Int(track.channels) * 10  // More channels = better
        if normalized.hasPrefix("eac3") || normalized.hasPrefix("ec3") { score += 5 }
        else if normalized.hasPrefix("ac3") { score += 3 }
        else if normalized.hasPrefix("aac") { score += 1 }
        return score
    }

    private func codecIsLikelyNative(_ codec: String) -> Bool {
        let normalized = Self.normalizedCodecIdentifier(codec)

        let nativePrefixes = [
            "eac3", "ec3", "ac3",
            "aac", "alac", "flac",
            "mp3", "mp2", "opus", "pcm"
        ]
        return nativePrefixes.contains(where: { normalized == $0 || normalized.hasPrefix($0) })
    }

    /// Strip ASS/SSA dialogue metadata from embedded subtitle packets.
    /// FFmpeg returns embedded ASS subtitles as raw dialogue events:
    ///   "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
    /// We need to extract just the Text field (everything after the 8th comma).
    nonisolated private static func cleanEmbeddedSubtitleText(_ rawText: String) -> String {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // ASS event format: 8 metadata fields followed by the text field.
        // The text field is everything after the 8th comma (may itself contain commas).
        let assFieldCount = 8
        var commaCount = 0
        for (i, char) in text.enumerated() {
            if char == "," {
                commaCount += 1
                if commaCount == assFieldCount {
                    // Check that preceding fields look like ASS metadata
                    // (contain a style name like "Default" or digits)
                    let prefix = String(text[text.startIndex..<text.index(text.startIndex, offsetBy: i)])
                    if prefix.contains("Default") || prefix.contains("default") ||
                       prefix.allSatisfy({ $0.isNumber || $0 == "," || $0.isWhitespace }) {
                        text = String(text[text.index(text.startIndex, offsetBy: i + 1)...])
                    }
                    break
                }
            }
        }

        // ASS line breaks
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")

        // Strip ASS override blocks: {\an8}, {\i1}, {\pos(x,y)}, etc.
        text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)

        // Strip HTML-like tags sometimes present in embedded subs
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nativeTrackScore(_ track: FFmpegTrackInfo) -> Int {
        let codec = Self.normalizedCodecIdentifier(track.codecName)

        let codecScore: Int
        if codec.hasPrefix("eac3") || codec.hasPrefix("ec3") {
            codecScore = 500
        } else if codec.hasPrefix("ac3") {
            codecScore = 450
        } else if codec.hasPrefix("aac") {
            codecScore = 400
        } else if codec.hasPrefix("opus") {
            codecScore = 350
        } else if codec.hasPrefix("flac") || codec.hasPrefix("alac") {
            codecScore = 320
        } else if codec.hasPrefix("mp3") || codec.hasPrefix("mp2") {
            codecScore = 260
        } else {
            codecScore = 100
        }

        let defaultBonus = track.isDefault ? 30 : 0
        return codecScore + Int(track.channels) * 4 + defaultBonus
    }

    private static func codecSet(_ candidates: Set<String>, matches codec: String) -> Bool {
        let normalized = normalizedCodecIdentifier(codec)
        return candidates.contains { candidate in
            let candidateKey = normalizedCodecIdentifier(candidate)
            return normalized == candidateKey || normalized.hasPrefix(candidateKey)
        }
    }

    private static func normalizedCodecIdentifier(_ codec: String) -> String {
        codec.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

#endif // RIVULET_FFMPEG
