//
//  SampleBufferRenderer.swift
//  Rivulet
//
//  Shared rendering layer for video and audio sample buffers.
//  Owns AVSampleBufferDisplayLayer for video.
//  Audio output uses AVAudioEngine for selected PCM routes, or
//  AVSampleBufferAudioRenderer for compressed passthrough / sample-buffer audio.
//

import Foundation
import AVFoundation
import CoreMedia

/// Shared rendering layer that accepts CMSampleBuffers and manages A/V synchronization.
@MainActor
final class SampleBufferRenderer {

    // MARK: - Public: Display layer for view binding

    let displayLayer = AVSampleBufferDisplayLayer()

    /// Audio renderer — used for compressed passthrough and sample-buffer audio.
    nonisolated(unsafe) let audioRenderer = AVSampleBufferAudioRenderer()

    /// Render synchronizer — drives A/V sync, handles AirPlay latency compensation,
    /// and manages the shared timebase for both video and audio.
    nonisolated(unsafe) let renderSynchronizer = AVSampleBufferRenderSynchronizer()

    // MARK: - AVAudioEngine (PCM Audio)

    /// When true, decoded PCM audio routes through AVAudioEngine instead of
    /// AVSampleBufferAudioRenderer. The engine handles route-specific buffering
    /// and conversion more reliably on stereo AirPlay/HomePod routes.
    nonisolated(unsafe) private(set) var useAudioEngine = false

    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var pcmAudioFormat: AVAudioFormat?
    private var engineConfigObserver: NSObjectProtocol?
    private var audioEngineVideoLatency: CMTime = .zero

    /// Independent video clock used while the audio engine owns audio playback.
    /// AVSampleBufferRenderSynchronizer handles AirPlay latency natively, so no
    /// manual video delay queue is needed for the sample-buffer audio path.
    nonisolated(unsafe) private var videoTimebase: CMTimebase?

    // MARK: - Configuration

    /// Maximum seconds of lookahead before pacing slows enqueue
    var maxVideoLookahead: TimeInterval = 2.0

    /// Maximum seconds to wait for audio renderer backpressure before dropping.
    var audioBackpressureMaxWait: TimeInterval = 0.5

    /// Use pull-mode audio delivery. Marked nonisolated so the audio enqueue
    /// task can read it without hopping to MainActor (the value is only set
    /// once during pipeline configuration before any reads happen).
    nonisolated(unsafe) var useAudioPullMode = false

    /// Minimum queued audio duration before starting pull-mode delivery after a reset.
    /// Helps AirPlay routes build a meaningful initial renderer cushion instead of
    /// draining one PCM buffer at a time.
    nonisolated(unsafe) var minimumAudioPullStartBuffer: TimeInterval = 0

    /// Minimum queued audio duration required to restart pull-mode delivery after
    /// an active request drained completely. Keeps buffered routes from oscillating
    /// between one-sample requests and empty playback once startup completes.
    nonisolated(unsafe) var minimumAudioPullResumeBuffer: TimeInterval = 0

    // MARK: - Pull-Mode Audio State

    private let audioPullLock = NSLock()
    private nonisolated(unsafe) var audioPullBuffer: [CMSampleBuffer] = []
    private nonisolated(unsafe) var audioPullBufferedDuration: TimeInterval = 0
    private nonisolated(unsafe) var audioPullRequesting = false
    private nonisolated(unsafe) var audioPullPaused = false
    private nonisolated(unsafe) var hasStartedAudioPullSinceReset = false
    private nonisolated(unsafe) var hasReachedReliableAudioPullStartSinceReset = false
    private let audioPullQueue = DispatchQueue(label: "rivulet.audio-pull", qos: .userInteractive)
    private nonisolated(unsafe) var audioPullDrainCount = 0
    private nonisolated(unsafe) var audioPullRequestStartWall: CFAbsoluteTime = 0
    private nonisolated(unsafe) var audioPullStartCount = 0
    private nonisolated(unsafe) var audioPullDeliveredCount = 0
    private nonisolated(unsafe) var audioPullWaitingLogCount = 0
    private nonisolated(unsafe) var audioPullShouldLogCurrentRequest = false
    private nonisolated(unsafe) var lastLoggedAudioPullReliableStart: Bool?

    // MARK: - Callbacks

    /// Called when the audio renderer is automatically flushed by the system.
    var onAudioRendererFlushedAutomatically: ((CMTime) -> Void)?

    /// Called when the audio output configuration changes.
    var onAudioOutputConfigurationChanged: (() -> Void)?

    /// Called when audio becomes genuinely primed for playback.
    /// For pull-mode audio this fires on the first delivered sample PTS, not
    /// merely when a request starts or data is buffered.
    var onAudioPrimedForPlayback: ((Double) -> Void)?

    /// Called when the video sink switches between AVSampleBufferDisplayLayer
    /// and MetalVideoRenderer (in either direction). UI layers bound to the
    /// player observe this to re-host the underlying view.
    var onVideoSinkChanged: (() -> Void)?

    // MARK: - Metal Video Sink (optional)

    /// Alternate video sink used for HLG HDR content where
    /// AVSampleBufferDisplayLayer renders black on tvOS. Owns its own
    /// VTDecompressionSession and a CAMetalLayer-backed UIView. Nil while
    /// the default AVSBL sink is active.
    private(set) var metalRenderer: MetalVideoRenderer?

    // MARK: - Audio State

    // hasLoggedFirstAudioSample, audioEnqueueCount, lastAudioDiagWallTime are
    // marked nonisolated(unsafe) so the audio enqueue task can update them
    // without hopping to MainActor. They're either one-shot flags or
    // diagnostic counters where the occasional race is harmless.
    private nonisolated(unsafe) var hasLoggedFirstAudioSample = false
    private var lastAudioRendererStatus: AVQueuedSampleBufferRenderingStatus?
    private var audioBackpressureDropCount = 0
    private nonisolated(unsafe) var audioEnqueueCount = 0
    private var lastAudioRecoveryWallTime: CFAbsoluteTime = 0
    private nonisolated(unsafe) var lastAudioDiagWallTime: CFAbsoluteTime = 0
    private var audioNotReadyStreak = 0
    private var isMuted = false

    // MARK: - Notification Observers

    private var autoFlushObserver: NSObjectProtocol?
    private var outputConfigObserver: NSObjectProtocol?

    // MARK: - Jitter Diagnostics

    var jitterStats = PlaybackJitterStats()

    // MARK: - Init

    init() {
        // Add BOTH renderers to the synchronizer so it can coordinate
        // video and audio timing together — including AirPlay latency
        // compensation. Per WWDC 2017 (Introducing AirPlay 2):
        // "AVSampleBufferDisplayLayer integrates identically to the
        // AudioRenderer — add it to a RenderSynchronizer just as you
        // add the AudioRenderer."
        //
        // Previously only the audio renderer was added, and the display
        // layer used controlTimebase. That bypassed the synchronizer's
        // A/V coordination, breaking pause/resume sync on AirPlay.
        renderSynchronizer.addRenderer(audioRenderer)
        renderSynchronizer.addRenderer(displayLayer)

        if #available(tvOS 14.5, *) {
            // Keep the system's reliable-start gate enabled so AirPlay routes can
            // build the renderer's preroll before playback rate changes take effect.
            renderSynchronizer.delaysRateChangeUntilHasSufficientMediaData = true
        }

        displayLayer.videoGravity = .resizeAspect

        audioRenderer.volume = 1.0
        audioRenderer.isMuted = isMuted
        audioRenderer.allowedAudioSpatializationFormats = []

        observeAudioRendererNotifications()
    }

    /// Diagnostic-only: log the HDR-relevant extensions on the incoming
    /// video CMFormatDescription, and (if a Metal video sink is active)
    /// hand the format description to the Metal renderer so it can build
    /// its VTDecompressionSession + layer color configuration.
    @MainActor
    func configureLayerForVideoFormat(_ formatDesc: CMFormatDescription) {
        guard let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [CFString: Any] else {
            playerDebugLog("[Renderer] configureLayerForVideoFormat: no extensions")
            return
        }
        let transferFn = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        let fullRange = extensions[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool
        let pq = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        let hlg = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        let isHDR = transferFn == pq || transferFn == hlg
        playerDebugLog("[Renderer] configureLayerForVideoFormat: primaries=\(primaries ?? "nil") transfer=\(transferFn ?? "nil") matrix=\(matrix ?? "nil") fullRange=\(fullRange.map(String.init) ?? "nil") isHDR=\(isHDR)")

        metalRenderer?.configure(formatDescription: formatDesc)
    }

    /// Switch video output from AVSampleBufferDisplayLayer to a Metal-backed
    /// renderer. Call before the first video sample is enqueued. Returns the
    /// renderer on success, or nil if Metal is unavailable on this device.
    ///
    /// Side-effects: removes `displayLayer` from the synchronizer so the
    /// synchronizer no longer drives it. Audio renderer stays attached. The
    /// Metal renderer's CADisplayLink reads `synchronizer.currentTime()` to
    /// pick which queued frame to present each tick.
    @MainActor
    func enableMetalVideoSink() -> MetalVideoRenderer? {
        if let metalRenderer { return metalRenderer }
        guard let renderer = MetalVideoRenderer(synchronizer: renderSynchronizer) else {
            playerDebugLog("[Renderer] enableMetalVideoSink: Metal unavailable; staying on AVSBL")
            return nil
        }
        renderSynchronizer.removeRenderer(displayLayer, at: .invalid) { _ in }
        renderer.start()
        metalRenderer = renderer
        playerDebugLog("[Renderer] enableMetalVideoSink: video sink switched to Metal")
        onVideoSinkChanged?()
        return renderer
    }

    /// Reverse `enableMetalVideoSink()`. Stops the Metal renderer and re-attaches
    /// `displayLayer` to the synchronizer. Used on player teardown.
    @MainActor
    func disableMetalVideoSink() {
        guard let renderer = metalRenderer else { return }
        renderer.stop()
        metalRenderer = nil
        renderSynchronizer.addRenderer(displayLayer)
        playerDebugLog("[Renderer] disableMetalVideoSink: video sink reverted to AVSBL")
        onVideoSinkChanged?()
    }

    deinit {
        if audioPullRequesting {
            audioRenderer.stopRequestingMediaData()
        }
        if let autoFlushObserver {
            NotificationCenter.default.removeObserver(autoFlushObserver)
        }
        if let outputConfigObserver {
            NotificationCenter.default.removeObserver(outputConfigObserver)
        }
        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
        }
    }

    // MARK: - AVAudioEngine Setup

    func enableAudioEngine() {
        guard !useAudioEngine else { return }

        stopAudioPullMode()
        audioRenderer.flush()

        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )

        if let timebase {
            videoTimebase = timebase
            displayLayer.controlTimebase = timebase
        }

        useAudioEngine = true
        playerDebugLog("[Renderer] Audio engine mode enabled — video uses independent timebase")
    }

    func disableAudioEngine() {
        guard useAudioEngine else { return }

        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioPlayerNode = nil
        audioEngine = nil
        pcmAudioFormat = nil
        audioEngineVideoLatency = .zero

        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
            self.engineConfigObserver = nil
        }

        displayLayer.controlTimebase = renderSynchronizer.timebase
        videoTimebase = nil
        useAudioEngine = false
        audioRenderer.flush()
        playerDebugLog("[Renderer] Audio engine mode disabled — reverted to sample-buffer audio")
    }

    private func configureAudioEngine(from sampleBuffer: CMSampleBuffer) -> Bool {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            playerDebugLog("[Renderer] AudioEngine: cannot read format from sample buffer")
            return false
        }

        let stream = asbd.pointee
        let isFloat = (stream.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let commonFormat: AVAudioCommonFormat = isFloat ? .pcmFormatFloat32 : .pcmFormatInt16

        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: stream.mSampleRate,
            channels: AVAudioChannelCount(stream.mChannelsPerFrame),
            interleaved: true
        ) else {
            playerDebugLog("[Renderer] AudioEngine: failed to create AVAudioFormat")
            return false
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = isMuted ? 0 : 1

        do {
            try engine.start()
        } catch {
            playerDebugLog("[Renderer] AudioEngine: failed to start — \(error.localizedDescription)")
            return false
        }

        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigChange()
            }
        }

        audioEngine = engine
        audioPlayerNode = playerNode
        pcmAudioFormat = format
        let previousLatency = audioEngineVideoLatency
        refreshAudioEngineLatency(reason: "engine_started")
        applyAudioEngineLatencyDelta(previousLatency: previousLatency, reason: "engine_started")

        let formatName = isFloat ? "float32" : "s16"
        playerDebugLog(
            "[Renderer] AudioEngine started: \(Int(stream.mSampleRate))Hz " +
            "\(stream.mChannelsPerFrame)ch \(formatName) -> output \(engine.outputNode.outputFormat(forBus: 0))"
        )
        return true
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audioRenderer.isMuted = muted
        audioEngine?.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    private func handleEngineConfigChange() {
        playerDebugLog("[Renderer] AudioEngine config changed — restarting")
        guard let engine = audioEngine, let playerNode = audioPlayerNode else { return }

        let previousLatency = audioEngineVideoLatency

        do {
            try engine.start()
            refreshAudioEngineLatency(reason: "engine_config_changed")
            applyAudioEngineLatencyDelta(previousLatency: previousLatency, reason: "engine_config_changed")
            if let timebase = videoTimebase, CMTimebaseGetRate(timebase) > 0 {
                playerNode.play()
            }
            playerDebugLog("[Renderer] AudioEngine restarted after config change (playing=\(playerNode.isPlaying))")
        } catch {
            playerDebugLog("[Renderer] AudioEngine restart failed: \(error.localizedDescription)")
        }

        onAudioOutputConfigurationChanged?()
    }

    // MARK: - Synchronizer / Timebase Control

    /// Current playback position.
    nonisolated var currentTime: TimeInterval {
        // Audio engine mode: the video timebase is the only clock (synchronizer unused).
        if useAudioEngine, let timebase = videoTimebase {
            let time = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            return time.isFinite && time >= 0 ? time : 0
        }
        // Sample buffer mode (including AirPlay video compensation):
        // Always use the synchronizer for pacing, UI, and diagnostics.
        // The AirPlay-shifted video timebase only affects display layer rendering.
        let time = CMTimeGetSeconds(renderSynchronizer.currentTime())
        return time.isFinite && time >= 0 ? time : 0
    }

    /// Current time as CMTime.
    nonisolated var currentCMTime: CMTime {
        if useAudioEngine, let timebase = videoTimebase {
            return CMTimebaseGetTime(timebase)
        }
        return renderSynchronizer.currentTime()
    }

    /// Media time currently visible on screen. Same as `currentTime` since
    /// AirPlay latency is handled natively by AVSampleBufferRenderSynchronizer.
    nonisolated var displayTime: TimeInterval {
        return currentTime
    }

    /// Set playback rate (0 = paused, 1 = normal).
    func setRate(_ rate: Float) {
        if rate > 0 && !useAudioEngine {
            audioPullLock.lock()
            let pullBuf = audioPullBuffer.count
            let pullDur = audioPullBufferedDuration
            let pullReq = audioPullRequesting
            audioPullLock.unlock()
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            playerDebugLog("[Renderer] setRate(\(rate)) syncTime=\(String(format: "%.3f", syncTime))s " +
                  "pullBuffer=\(pullBuf) pullDur=\(String(format: "%.3f", pullDur))s pullRequesting=\(pullReq) " +
                  "audioStatus=\(audioRenderer.status.rawValue)")
        } else {
            playerDebugLog("[Renderer] setRate(\(rate))")
        }

        if useAudioEngine, let timebase = videoTimebase {
            CMTimebaseSetRate(timebase, rate: Float64(rate))
        }

        if useAudioEngine {
            if rate > 0 {
                audioPlayerNode?.play()
            } else {
                audioPlayerNode?.pause()
            }
        } else {
            renderSynchronizer.rate = rate
        }
    }

    /// Set playback rate and time simultaneously.
    func setRate(_ rate: Float, time: CMTime) {
        playerDebugLog("[Renderer] setRate(\(rate), time=\(String(format: "%.3f", CMTimeGetSeconds(time)))s)")

        if useAudioEngine {
            // Audio engine: update video timebase first (host clock, no source dependency)
            if let timebase = videoTimebase {
                let compensated = compensatedVideoTime(forMediaTime: time)
                CMTimebaseSetTime(timebase, time: compensated)
                CMTimebaseSetRate(timebase, rate: Float64(rate))
            }
            if rate > 0 {
                audioPlayerNode?.play()
            } else {
                audioPlayerNode?.pause()
            }
        } else {
            renderSynchronizer.setRate(rate, time: time)
        }
    }

    /// Set playback rate and media time against a future host-time edge.
    func setRate(_ rate: Float, time: CMTime, atHostTime hostTime: CMTime) {
        let session = AVAudioSession.sharedInstance()
        let outputLatency = session.outputLatency
        let delaysSufficientData = renderSynchronizer.delaysRateChangeUntilHasSufficientMediaData
        playerDebugLog(
            "[Renderer] setRate(\(rate), time=\(String(format: "%.3f", CMTimeGetSeconds(time)))s, " +
            "hostTime=\(String(format: "%.3f", CMTimeGetSeconds(hostTime)))s) " +
            "outputLatency=\(String(format: "%.3f", outputLatency))s " +
            "delaysSufficientData=\(delaysSufficientData) " +
            "audioStatus=\(audioRenderer.status.rawValue) " +
            "pullDelivered=\(audioPullDeliveredCountSnapshot())"
        )
        if rate > 0 {
            playerDebugLog("[StartupTrace] renderer clock starts (rate=\(rate)) — audio/video begins NOW")
        }
        if useAudioEngine {
            setRate(rate, time: time)
        } else {
            if #available(tvOS 14.5, iOS 14.5, macOS 11.3, watchOS 7.4, visionOS 1.0, *) {
                renderSynchronizer.setRate(rate, time: time, atHostTime: hostTime)
            } else {
                renderSynchronizer.setRate(rate, time: time)
            }
        }
    }

    private func refreshAudioEngineLatency(reason: String) {
        guard let engine = audioEngine else {
            audioEngineVideoLatency = .zero
            return
        }

        let session = AVAudioSession.sharedInstance()
        let sessionOutputLatency = session.outputLatency
        let ioBufferLatency = session.ioBufferDuration
        let enginePresentationLatency = engine.outputNode.presentationLatency

        let appliedSeconds = max(
            sessionOutputLatency + ioBufferLatency,
            enginePresentationLatency
        )
        audioEngineVideoLatency = CMTime(
            seconds: appliedSeconds,
            preferredTimescale: 90_000
        )

        playerDebugLog(
            "[Renderer] AudioEngine latency: reason=\(reason) " +
            "sessionOutput=\(String(format: "%.3f", sessionOutputLatency))s " +
            "ioBuffer=\(String(format: "%.3f", ioBufferLatency))s " +
            "enginePresentation=\(String(format: "%.3f", enginePresentationLatency))s " +
            "applied=\(String(format: "%.3f", appliedSeconds))s"
        )
    }

    private func applyAudioEngineLatencyDelta(previousLatency: CMTime, reason: String) {
        guard let timebase = videoTimebase else { return }

        let currentTime = CMTimebaseGetTime(timebase)
        let delta = CMTimeSubtract(previousLatency, audioEngineVideoLatency)
        let rebasedTime = CMTimeAdd(currentTime, delta)
        let clampedTime = rebasedTime < .zero ? .zero : rebasedTime
        CMTimebaseSetTime(timebase, time: clampedTime)

        playerDebugLog(
            "[Renderer] AudioEngine timebase rebase: reason=\(reason) " +
            "previousLatency=\(String(format: "%.3f", CMTimeGetSeconds(previousLatency)))s " +
            "newLatency=\(String(format: "%.3f", CMTimeGetSeconds(audioEngineVideoLatency)))s " +
            "oldTime=\(String(format: "%.3f", CMTimeGetSeconds(currentTime)))s " +
            "newTime=\(String(format: "%.3f", CMTimeGetSeconds(clampedTime)))s"
        )
    }

    private func compensatedVideoTime(forMediaTime mediaTime: CMTime) -> CMTime {
        guard audioEngineVideoLatency.isValid,
              audioEngineVideoLatency.isNumeric,
              audioEngineVideoLatency > .zero else {
            return mediaTime
        }

        let compensated = CMTimeSubtract(mediaTime, audioEngineVideoLatency)
        return compensated < .zero ? .zero : compensated
    }

    private nonisolated var hasReliableAudioStartBuffer: Bool {
        if #available(tvOS 14.5, iOS 14.5, macOS 11.3, watchOS 7.4, visionOS 1.0, *) {
            return audioRenderer.hasSufficientMediaDataForReliablePlaybackStart
        }
        return false
    }

    private nonisolated func audioPullDeliveredCountSnapshot() -> Int {
        audioPullLock.lock()
        defer { audioPullLock.unlock() }
        return audioPullDeliveredCount
    }

    /// Total audio pull deliveries (for health reporting).
    nonisolated var totalAudioPullDeliveries: Int {
        audioPullDeliveredCountSnapshot()
    }

    // MARK: - Enqueue Video

    /// Enqueue a video sample buffer with pacing to prevent buffer overflow.
    func enqueueVideo(_ sampleBuffer: CMSampleBuffer, bypassLookahead: Bool = false) async {
        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let sampleTime = CMTimeGetSeconds(samplePTS)

        // Lookahead pacing: limit how far the read loop gets ahead of playback.
        if !bypassLookahead {
            while !Task.isCancelled {
                let syncTime = currentTime
                let ahead = sampleTime - syncTime

                if ahead <= maxVideoLookahead || syncTime < 0.1 {
                    break
                }

                let sleepTime = min(ahead - maxVideoLookahead, 0.1)
                try? await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
            }
        }

        guard !Task.isCancelled else { return }

        if !displayLayer.isReadyForMoreMediaData {
            // During preroll, the display layer cannot drain (rate=0). Once it's
            // full there is nowhere for new frames to go. The read loop is
            // single-threaded, so blocking here would also stall audio packet
            // reads — that's why we previously had a 120 ms wait that ate ~1 s
            // of audio per preroll. Drop the frame immediately instead and keep
            // reading audio. The video will skip by the dropped frames at the
            // start of playback, but audio stays in sync.
            if bypassLookahead {
                jitterStats.recordEnqueueStall(duration: 0)
                return
            }

            let stallStart = CFAbsoluteTimeGetCurrent()
            let maxWait: TimeInterval = 2.0
            let stallPTS = sampleTime
            let stallSyncTime = currentTime

            while !displayLayer.isReadyForMoreMediaData && !Task.isCancelled {
                let elapsed = CFAbsoluteTimeGetCurrent() - stallStart
                if elapsed > maxWait {
                    playerDebugLog("[Renderer] Video enqueue timeout after \(String(format: "%.0f", elapsed * 1000))ms — dropping frame (layer error: \(displayLayer.error?.localizedDescription ?? "none"))")
                    jitterStats.recordEnqueueStall(duration: elapsed)
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }

            let stallDuration = CFAbsoluteTimeGetCurrent() - stallStart
            if stallDuration > 0.2 {
                let nowSyncTime = currentTime
                playerDebugLog(String(
                    format: "[Renderer] Enqueue wait %.0fms: samplePTS=%.3f syncAtEntry=%.3f syncAtExit=%.3f aheadAtEntry=%.3f aheadAtExit=%.3f rate=%.2f status=%d error=%@",
                    stallDuration * 1000,
                    stallPTS, stallSyncTime, nowSyncTime,
                    stallPTS - stallSyncTime,
                    stallPTS - nowSyncTime,
                    Double(renderSynchronizer.rate),
                    displayLayer.status.rawValue,
                    displayLayer.error?.localizedDescription ?? "none"
                ))
            }
            jitterStats.recordEnqueueStall(duration: stallDuration)
        }

        guard !Task.isCancelled else { return }

        if let error = displayLayer.error {
            playerDebugLog("[Renderer] Display layer error before enqueue: \(error)")
        }

        displayLayer.enqueue(sampleBuffer)
    }

    // MARK: - Enqueue Audio

    /// Enqueue an audio sample buffer via the audio renderer.
    func enqueueAudio(_ sampleBuffer: CMSampleBuffer) async {
        if useAudioEngine {
            enqueueAudioViaEngine(sampleBuffer)
            return
        }

        if useAudioPullMode {
            enqueueAudioPullMode(sampleBuffer)
            return
        }

        // --- Push mode ---

        let currentStatus = audioRenderer.status
        if lastAudioRendererStatus != currentStatus {
            lastAudioRendererStatus = currentStatus
            let errorDescription = audioRenderer.error?.localizedDescription ?? "none"
            playerDebugLog("[Renderer] Audio renderer status changed: \(audioRendererStatusDescription(currentStatus)) (error=\(errorDescription))")
        }

        if currentStatus == .failed {
            guard recoverAudioRendererIfNeeded(reason: "pre_enqueue") else { return }
        }

        if !hasLoggedFirstAudioSample {
            hasLoggedFirstAudioSample = true
            let syncRate = renderSynchronizer.rate
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let ready = audioRenderer.isReadyForMoreMediaData
            let status = audioRenderer.status.rawValue
            playerDebugLog("[Renderer] Audio enqueue attempt: ready=\(ready), syncRate=\(syncRate), syncTime=\(String(format: "%.3f", syncTime))s, status=\(status)")
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            playerDebugLog("[Renderer] Audio sample PTS=\(CMTimeGetSeconds(pts))s, size=\(CMSampleBufferGetTotalSampleSize(sampleBuffer))B")
            logAudioSampleFormat(sampleBuffer)
            AudioRouteDiagnostics.shared.logCurrentRoute(owner: "SampleBufferRenderer", reason: "first_audio_sample")
        }

        if !audioRenderer.isReadyForMoreMediaData {
            let waitStart = CFAbsoluteTimeGetCurrent()
            let maxWait = audioBackpressureMaxWait

            while !audioRenderer.isReadyForMoreMediaData && !Task.isCancelled {
                if audioRenderer.status == .failed {
                    guard recoverAudioRendererIfNeeded(reason: "backpressure_wait") else { return }
                }

                let elapsed = CFAbsoluteTimeGetCurrent() - waitStart
                if elapsed > maxWait {
                    audioBackpressureDropCount += 1
                    audioNotReadyStreak += 1
                    if audioBackpressureDropCount == 1 || audioBackpressureDropCount % 50 == 0 {
                        let syncRate = renderSynchronizer.rate
                        let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
                        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                        playerDebugLog(
                            "[Renderer] Dropping audio sample after \(String(format: "%.0f", elapsed * 1000))ms backpressure " +
                            "(drops=\(audioBackpressureDropCount), streak=\(audioNotReadyStreak), " +
                            "status=\(audioRenderer.status.rawValue), error=\(audioRenderer.error?.localizedDescription ?? "none"), " +
                            "syncRate=\(syncRate), syncTime=\(String(format: "%.3f", syncTime))s, " +
                            "samplePTS=\(String(format: "%.3f", pts))s, muted=\(audioRenderer.isMuted))"
                        )
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        guard !Task.isCancelled else { return }

        if audioRenderer.status == .failed {
            guard recoverAudioRendererIfNeeded(reason: "post_wait") else { return }
        }

        if let error = audioRenderer.error {
            playerDebugLog("[Renderer] Audio renderer error before enqueue: \(error)")
            return
        }

        audioRenderer.enqueue(sampleBuffer)
        audioEnqueueCount += 1
        audioNotReadyStreak = 0

        // Periodic audio diagnostics (every 5s)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioDiagWallTime >= 5.0 {
            lastAudioDiagWallTime = now
            let syncRate = renderSynchronizer.rate
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let audioAhead = pts - syncTime
            playerDebugLog("[Renderer] AudioDiag: enqueued=\(audioEnqueueCount) drops=\(audioBackpressureDropCount) " +
                  "syncRate=\(syncRate) syncTime=\(String(format: "%.3f", syncTime))s " +
                  "audioPTS=\(String(format: "%.3f", pts))s ahead=\(String(format: "%.3f", audioAhead))s " +
                  "ready=\(audioRenderer.isReadyForMoreMediaData) status=\(audioRenderer.status.rawValue) " +
                  "muted=\(audioRenderer.isMuted) vol=\(audioRenderer.volume)")
        }
    }

    // MARK: - AVAudioEngine Audio Enqueue

    private func enqueueAudioViaEngine(_ sampleBuffer: CMSampleBuffer) {
        if audioEngine == nil {
            guard configureAudioEngine(from: sampleBuffer) else { return }
        }

        guard let playerNode = audioPlayerNode,
              let format = pcmAudioFormat,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer, length > 0 else { return }

        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }

        let frameCount = AVAudioFrameCount(length / bytesPerFrame)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }

        pcmBuffer.frameLength = frameCount
        guard let destination = pcmBuffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
        memcpy(destination, dataPointer, length)

        playerNode.scheduleBuffer(pcmBuffer)
        audioEnqueueCount += 1
        audioNotReadyStreak = 0

        if !hasLoggedFirstAudioSample {
            hasLoggedFirstAudioSample = true
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let outputFormat = audioEngine?.outputNode.outputFormat(forBus: 0)
            playerDebugLog(
                "[Renderer] AudioEngine first sample: PTS=\(String(format: "%.3f", CMTimeGetSeconds(pts)))s " +
                "inputFormat=\(format) frames=\(frameCount) " +
                "outputRate=\(outputFormat.map { String(Int($0.sampleRate)) } ?? "?")"
            )
            logAudioSampleFormat(sampleBuffer)
            AudioRouteDiagnostics.shared.logCurrentRoute(owner: "SampleBufferRenderer", reason: "first_audio_engine")
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioDiagWallTime >= 5.0 {
            lastAudioDiagWallTime = now
            let timebaseTime = videoTimebase.map { CMTimeGetSeconds(CMTimebaseGetTime($0)) } ?? 0
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            playerDebugLog(
                "[Renderer] AudioEngineDiag: enqueued=\(audioEnqueueCount) " +
                "tbTime=\(String(format: "%.3f", timebaseTime))s " +
                "audioPTS=\(String(format: "%.3f", pts))s " +
                "engineRunning=\(audioEngine?.isRunning ?? false)"
            )
        }
    }

    private nonisolated func sampleBufferDuration(_ sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        let durationSeconds = CMTimeGetSeconds(duration)
        if durationSeconds.isFinite, durationSeconds > 0 {
            return durationSeconds
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }

        let sampleRate = asbd.pointee.mSampleRate
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleRate > 0, sampleCount > 0 else { return 0 }
        return Double(sampleCount) / sampleRate
    }

    // MARK: - Pull-Mode Audio

    /// Public entry point for the audio enqueue task to bypass the @MainActor
    /// hop entirely when in pull mode. The pull-mode path only touches lock-
    /// protected and nonisolated(unsafe) state, so calling it from a detached
    /// task is safe and avoids competing with the video pipeline for MainActor.
    /// Returns true if the buffer was handled here, false if the caller should
    /// fall back to the @MainActor `enqueueAudio` path.
    nonisolated func enqueueAudioPullDirect(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard useAudioPullMode else { return false }
        enqueueAudioPullMode(sampleBuffer)
        return true
    }

    private nonisolated func enqueueAudioPullMode(_ sampleBuffer: CMSampleBuffer) {
        if !hasLoggedFirstAudioSample {
            hasLoggedFirstAudioSample = true
            let syncRate = renderSynchronizer.rate
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            playerDebugLog("[Renderer] Pull-mode audio first sample: syncRate=\(syncRate), " +
                  "syncTime=\(String(format: "%.3f", syncTime))s, " +
                  "PTS=\(String(format: "%.3f", CMTimeGetSeconds(pts)))s")
            logAudioSampleFormat(sampleBuffer)
            AudioRouteDiagnostics.shared.logCurrentRoute(owner: "SampleBufferRenderer", reason: "first_audio_pull")
        }

        let sampleDuration = sampleBufferDuration(sampleBuffer)
        audioPullLock.lock()
        let previousBufferedDuration = audioPullBufferedDuration
        audioPullBuffer.append(sampleBuffer)
        audioPullBufferedDuration += sampleDuration
        let bufferCount = audioPullBuffer.count
        let bufferedDuration = audioPullBufferedDuration
        let paused = audioPullPaused
        let needsRestart = !audioPullRequesting
        if hasReliableAudioStartBuffer {
            hasReachedReliableAudioPullStartSinceReset = true
        }
        let requiresStartupThreshold = !hasStartedAudioPullSinceReset || !hasReachedReliableAudioPullStartSinceReset
        let restartThreshold = requiresStartupThreshold
            ? minimumAudioPullStartBuffer
            : minimumAudioPullResumeBuffer
        let shouldStart = restartThreshold <= 0 || bufferedDuration >= restartThreshold
        audioPullLock.unlock()

        audioEnqueueCount += 1

        // Periodic audio diagnostics (every 5s)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioDiagWallTime >= 5.0 {
            lastAudioDiagWallTime = now
            let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let audioAhead = pts - syncTime
            playerDebugLog("[Renderer] AudioPullDiag: buffered=\(bufferCount) enqueued=\(audioEnqueueCount) " +
                  "bufferedDur=\(String(format: "%.3f", bufferedDuration))s " +
                  "requesting=\(audioPullRequesting) " +
                  "reliableStart=\(hasReliableAudioStartBuffer) " +
                  "syncTime=\(String(format: "%.3f", syncTime))s " +
                  "audioPTS=\(String(format: "%.3f", pts))s " +
                  "audioAhead=\(String(format: "%.3f", audioAhead))s " +
                  "rate=\(renderSynchronizer.rate) " +
                  "status=\(audioRenderer.status.rawValue)")
        }

        if paused {
            return
        }

        if needsRestart && shouldStart {
            startAudioPullMode()
        } else if !needsRestart && shouldStart && previousBufferedDuration < restartThreshold && audioRenderer.isReadyForMoreMediaData {
            audioPullQueue.async { [weak self] in
                self?.drainAudioPullBuffer()
            }
        } else if needsRestart && restartThreshold > 0 {
            audioPullWaitingLogCount += 1
            let waitLogCount = audioPullWaitingLogCount
            if waitLogCount <= 4 || waitLogCount % 60 == 0 {
                playerDebugLog(
                    "[Renderer] Audio pull waiting for cushion: " +
                    "buffered=\(bufferCount) bufferedDur=\(String(format: "%.3f", bufferedDuration))s " +
                    "need=\(String(format: "%.3f", restartThreshold))s " +
                    "phase=\(requiresStartupThreshold ? "startup" : "resume")"
                )
            }
        }
    }

    private nonisolated func startAudioPullMode() {
        audioPullLock.lock()
        guard !audioPullPaused else {
            audioPullLock.unlock()
            return
        }
        audioPullRequesting = true
        let buffered = audioPullBuffer.count
        let bufferedDuration = audioPullBufferedDuration
        audioPullLock.unlock()
        hasStartedAudioPullSinceReset = true
        audioPullRequestStartWall = CFAbsoluteTimeGetCurrent()
        audioPullStartCount += 1
        let startCount = audioPullStartCount
        let reliableStart = hasReliableAudioStartBuffer
        if reliableStart {
            hasReachedReliableAudioPullStartSinceReset = true
        }
        let reliableStartChanged = lastLoggedAudioPullReliableStart != reliableStart
        lastLoggedAudioPullReliableStart = reliableStart
        let shouldLogRequest = reliableStartChanged || startCount <= 4 || startCount % 120 == 0
        audioPullShouldLogCurrentRequest = shouldLogRequest

        if shouldLogRequest {
            playerDebugLog(
                "[Renderer] Audio pull start: buffered=\(buffered) " +
                "bufferedDur=\(String(format: "%.3f", bufferedDuration))s " +
                "status=\(audioRenderer.status.rawValue) ready=\(audioRenderer.isReadyForMoreMediaData) " +
                "reliableStart=\(reliableStart) count=\(startCount)"
            )
        }

        audioRenderer.requestMediaDataWhenReady(on: audioPullQueue) { [weak self] in
            self?.drainAudioPullBuffer()
        }
    }

    private nonisolated func drainAudioPullBuffer() {
        while audioRenderer.isReadyForMoreMediaData {
            audioPullLock.lock()
            guard !audioPullBuffer.isEmpty else {
                audioPullLock.unlock()
                let elapsed = CFAbsoluteTimeGetCurrent() - audioPullRequestStartWall
                if audioPullDrainCount > 0 && audioPullShouldLogCurrentRequest {
                    playerDebugLog(
                        "[Renderer] Audio pull drained: delivered=\(audioPullDrainCount) " +
                        "elapsed=\(String(format: "%.0f", elapsed * 1000))ms " +
                        "status=\(audioRenderer.status.rawValue)"
                    )
                }
                audioPullDrainCount = 0
                audioPullShouldLogCurrentRequest = false
                return
            }
            let sample = audioPullBuffer.removeFirst()
            audioPullBufferedDuration = max(0, audioPullBufferedDuration - sampleBufferDuration(sample))
            let remaining = audioPullBuffer.count
            let remainingDuration = audioPullBufferedDuration
            audioPullLock.unlock()

            audioRenderer.enqueue(sample)
            audioPullLock.lock()
            audioPullDrainCount += 1
            audioPullDeliveredCount += 1
            let drainCount = audioPullDrainCount
            let deliveredCount = audioPullDeliveredCount
            audioPullLock.unlock()
            let becamePrimed = (deliveredCount == 1)
            if hasReliableAudioStartBuffer {
                hasReachedReliableAudioPullStartSinceReset = true
            }
            if becamePrimed {
                let deliveredPTS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                Task { @MainActor [weak self] in
                    guard deliveredPTS.isFinite else { return }
                    self?.onAudioPrimedForPlayback?(deliveredPTS)
                }
            }
            if audioPullShouldLogCurrentRequest && drainCount == 1 {
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let syncTime = CMTimeGetSeconds(renderSynchronizer.currentTime())
                playerDebugLog("[Renderer] Audio pull deliver #\(deliveredCount): pts=\(String(format: "%.3f", pts))s " +
                      "ahead=\(String(format: "%.3f", pts - syncTime))s remaining=\(remaining) " +
                      "remainingDur=\(String(format: "%.3f", remainingDuration))s " +
                      "reliableStart=\(hasReliableAudioStartBuffer) status=\(audioRenderer.status.rawValue)")
            }
        }

        audioPullLock.lock()
        let buffered = audioPullBuffer.count
        let bufferedDuration = audioPullBufferedDuration
        audioPullLock.unlock()
        if audioPullShouldLogCurrentRequest {
            playerDebugLog(
                "[Renderer] Audio pull paused: buffered=\(buffered) " +
                "bufferedDur=\(String(format: "%.3f", bufferedDuration))s " +
                "ready=\(audioRenderer.isReadyForMoreMediaData) " +
                "reliableStart=\(hasReliableAudioStartBuffer) status=\(audioRenderer.status.rawValue) " +
                "error=\(audioRenderer.error?.localizedDescription ?? "none")"
            )
        }
    }

    func stopAudioPullMode() {
        audioPullLock.lock()
        if audioPullRequesting {
            audioPullRequesting = false
            audioPullLock.unlock()
            audioRenderer.stopRequestingMediaData()
        } else {
            audioPullLock.unlock()
        }

        audioPullLock.lock()
        audioPullBuffer.removeAll()
        audioPullBufferedDuration = 0
        audioPullPaused = false
        audioPullLock.unlock()
        audioPullDrainCount = 0
        audioPullShouldLogCurrentRequest = false
        hasStartedAudioPullSinceReset = false
        hasReachedReliableAudioPullStartSinceReset = false
    }

    /// Reset audio diagnostics and recovery state (call after flush/seek).
    func resetAudioState() {
        hasLoggedFirstAudioSample = false
        lastAudioRendererStatus = nil
        audioBackpressureDropCount = 0
        audioEnqueueCount = 0
        lastAudioRecoveryWallTime = 0
        lastAudioDiagWallTime = 0
        audioNotReadyStreak = 0
        audioPullLock.lock()
        audioPullBuffer.removeAll()
        audioPullBufferedDuration = 0
        audioPullPaused = false
        audioPullLock.unlock()
        hasStartedAudioPullSinceReset = false
        audioPullDrainCount = 0
        audioPullStartCount = 0
        audioPullDeliveredCount = 0
        audioPullWaitingLogCount = 0
        audioPullShouldLogCurrentRequest = false
        lastLoggedAudioPullReliableStart = nil
        hasReachedReliableAudioPullStartSinceReset = false
    }

    // MARK: - Flush

    /// Pause audio delivery without discarding buffered data.
    /// Stops pull-mode requests so the renderer doesn't drain the buffer,
    /// but keeps buffered audio intact for seamless resume.
    func pauseAudio() {
        if useAudioEngine {
            audioPlayerNode?.pause()
            return
        }

        guard useAudioPullMode else { return }

        audioPullLock.lock()
        audioPullPaused = true
        let wasRequesting = audioPullRequesting
        let buffered = audioPullBuffer.count
        let bufferedDuration = audioPullBufferedDuration
        if wasRequesting {
            audioPullRequesting = false
        }
        audioPullLock.unlock()

        if wasRequesting {
            audioRenderer.stopRequestingMediaData()
        }

        audioPullDrainCount = 0
        audioPullShouldLogCurrentRequest = false
        playerDebugLog(
            "[Renderer] Audio pull paused for transport: buffered=\(buffered) " +
            "bufferedDur=\(String(format: "%.3f", bufferedDuration))s"
        )
    }

    /// Resume pull-mode audio delivery after a transport pause.
    func resumeAudio() {
        if useAudioEngine {
            return
        }

        guard useAudioPullMode else { return }

        audioPullLock.lock()
        audioPullPaused = false
        let isRequesting = audioPullRequesting
        let buffered = audioPullBuffer.count
        let bufferedDuration = audioPullBufferedDuration
        audioPullLock.unlock()

        if isRequesting {
            playerDebugLog("[Renderer] Audio pull resume: already requesting, buffered=\(buffered)")
            return
        }

        if buffered > 0 {
            playerDebugLog(
                "[Renderer] Audio pull resume for transport: buffered=\(buffered) " +
                "bufferedDur=\(String(format: "%.3f", bufferedDuration))s"
            )
            startAudioPullMode()
        } else {
            // Pull buffer was empty at pause time (normal — it's kept small).
            // Don't start pull mode yet. enqueueAudioPullMode() will restart
            // it once enough audio arrives from the read loop. Use the resume
            // threshold (0.3s) not startup threshold (1.0s) for faster restart.
            audioPullLock.lock()
            hasStartedAudioPullSinceReset = true
            hasReachedReliableAudioPullStartSinceReset = true
            audioPullLock.unlock()
            playerDebugLog("[Renderer] Audio pull resume: buffer empty, will restart on next audio (resume threshold)")
        }
    }

    /// Flush audio renderer and pull-mode state without touching video.
    /// Used for stop/seek where the timeline changes.
    func flushAudio() {
        if useAudioEngine {
            audioPlayerNode?.stop()
        } else {
            stopAudioPullMode()
            audioRenderer.flush()
        }
        resetAudioState()
    }

    /// Flush both video and audio buffers (for seeking).
    func flush() {
        displayLayer.flushAndRemoveImage()

        if useAudioEngine {
            audioPlayerNode?.stop()
            audioEngine?.stop()
            audioPlayerNode = nil
            audioEngine = nil
            pcmAudioFormat = nil
            if let engineConfigObserver {
                NotificationCenter.default.removeObserver(engineConfigObserver)
                self.engineConfigObserver = nil
            }
        } else {
            audioPullLock.lock()
            let wasPulling = audioPullRequesting
            if wasPulling {
                audioPullRequesting = false
            }
            audioPullLock.unlock()

            if wasPulling {
                audioRenderer.stopRequestingMediaData()
            }

            audioRenderer.flush()
        }
        resetAudioState()
    }

    /// Check for errors on display layer or audio renderer.
    var displayLayerError: Error? { displayLayer.error }
    var audioRendererError: Error? {
        useAudioEngine ? nil : audioRenderer.error
    }
    var hasReliableAudioStart: Bool {
        if useAudioEngine {
            return audioEnqueueCount > 0
        }
        return hasReliableAudioStartBuffer
    }
    var isAudioPrimedForPlayback: Bool {
        if useAudioEngine {
            return audioEnqueueCount > 0
        }
        if useAudioPullMode {
            // Consider primed once the internal pull buffer has enough data,
            // even if delivery to the renderer hasn't started yet.
            // Without this, preroll deadlocks: it waits for delivered audio,
            // but delivery waits for the startup cushion to fill.
            if audioPullDeliveredCountSnapshot() > 0 { return true }
            audioPullLock.lock()
            let buffered = audioPullBufferedDuration
            audioPullLock.unlock()
            return buffered >= minimumAudioPullStartBuffer
        }
        return audioEnqueueCount > 0 || audioRenderer.status == .rendering
    }

    @discardableResult
    private func recoverAudioRendererIfNeeded(reason: String) -> Bool {
        guard audioRenderer.status == .failed else { return true }

        let errorDescription = audioRenderer.error?.localizedDescription ?? "none"
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAudioRecoveryWallTime > 0.25 {
            lastAudioRecoveryWallTime = now
            playerDebugLog("[Renderer] Audio renderer failed during \(reason); flushing to recover (error=\(errorDescription))")
        }
        audioRenderer.flush()
        return true
    }

    private nonisolated func logAudioSampleFormat(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            playerDebugLog("[Renderer] Audio format: unavailable")
            return
        }

        let asbd = streamBasicDescription.pointee
        let codec = fourCCString(asbd.mFormatID)

        var channelLayoutSummary = "unknown"
        var layoutSize = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &layoutSize) {
            let tag = layout.pointee.mChannelLayoutTag
            let channels = AudioChannelLayoutTag_GetNumberOfChannels(tag)
            channelLayoutSummary = "tag=\(tag),channels=\(channels)"
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSigned = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isPacked = (asbd.mFormatFlags & kAudioFormatFlagIsPacked) != 0
        let formatType = isFloat ? "float" : (isSigned ? "sint" : "uint")

        playerDebugLog(
            "[Renderer] Audio format details: codec=\(codec) sampleRate=\(Int(asbd.mSampleRate)) " +
            "channels=\(asbd.mChannelsPerFrame) bitsPerChannel=\(asbd.mBitsPerChannel) " +
            "type=\(formatType) packed=\(isPacked) flags=\(asbd.mFormatFlags) " +
            "bytesPerFrame=\(asbd.mBytesPerFrame) layout=\(channelLayoutSummary)"
        )
    }

    private nonisolated func fourCCString(_ fourCC: UInt32) -> String {
        let n = Int(fourCC.bigEndian)
        let scalars = [
            UnicodeScalar((n >> 24) & 255),
            UnicodeScalar((n >> 16) & 255),
            UnicodeScalar((n >> 8) & 255),
            UnicodeScalar(n & 255)
        ]
        let characters = scalars.compactMap { $0.map(Character.init) }
        return String(characters)
    }

    private func audioRendererStatusDescription(_ status: AVQueuedSampleBufferRenderingStatus) -> String {
        switch status {
        case .unknown:
            return "unknown(0)"
        case .rendering:
            return "rendering(1)"
        case .failed:
            return "failed(2)"
        @unknown default:
            return "unknown_future(\(status.rawValue))"
        }
    }

    // MARK: - Notification Observers

    private func observeAudioRendererNotifications() {
        autoFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: audioRenderer,
            queue: .main
        ) { [weak self] notification in
            let flushTime: CMTime
            if let timeValue = notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue {
                flushTime = timeValue.timeValue
            } else {
                flushTime = .invalid
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.useAudioEngine else { return }
                let flushTimeSeconds = CMTimeGetSeconds(flushTime)
                let syncTime = CMTimeGetSeconds(self.renderSynchronizer.currentTime())
                let rate = self.renderSynchronizer.rate

                // Always handle auto-flush, even during pause (rate==0).
                // Per Apple's SampleBufferPlayer sample code, auto-flush
                // requires a full restart — the renderer's AirPlay transport
                // is invalidated and will silently discard audio if not
                // recovered. Previously we skipped this during pause, which
                // caused silent audio on resume.
                let isPaused = rate == 0
                playerDebugLog("[Renderer] Audio renderer auto-flushed at \(String(format: "%.3f", flushTimeSeconds))s " +
                      "(syncTime=\(String(format: "%.3f", syncTime))s, rate=\(rate), " +
                      "paused=\(isPaused), enqueued=\(self.audioEnqueueCount), drops=\(self.audioBackpressureDropCount))")

                self.resetAudioState()
                self.onAudioRendererFlushedAutomatically?(flushTime)
            }
        }

        outputConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: audioRenderer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.useAudioEngine else { return }
                let syncTime = CMTimeGetSeconds(self.renderSynchronizer.currentTime())
                playerDebugLog("[Renderer] Audio output configuration changed (syncTime=\(String(format: "%.3f", syncTime))s)")

                AudioRouteDiagnostics.shared.logCurrentRoute(
                    owner: "SampleBufferRenderer",
                    reason: "output_config_changed"
                )

                self.onAudioOutputConfigurationChanged?()
            }
        }
    }
}
