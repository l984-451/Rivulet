//
//  MPVMetalViewController.swift
//  Rivulet
//
//  MPV player view controller with Metal rendering and HDR support
//

import Foundation
import UIKit
import Libmpv
import AVFoundation

final class MPVMetalViewController: UIViewController {

    // MARK: - Properties

    private var metalLayer = MetalLayer()
    private var mpv: OpaquePointer?
    private lazy var queue = DispatchQueue(label: "mpv", qos: .userInitiated)

    weak var delegate: MPVPlayerDelegate?
    var playUrl: URL?
    var httpHeaders: [String: String]?
    var startTime: Double?

    /// Enable lightweight mode for live streams (smaller buffers, simpler rendering)
    var isLiveStreamMode: Bool = false

    private var timeObserverActive = false
    private var currentState: MPVPlayerState = .idle
    private var isShuttingDown = false
    private var lastKnownSize: CGSize = .zero
    private var previousDrawableSize: CGSize = .zero
    private var audioRouteObserver: NSObjectProtocol?

    /// Explicit target size set by parent - when set, enables transform-based scaling
    /// to avoid swapchain recreation during multiview layout changes
    private var explicitTargetSize: CGSize?

    /// The original size at which MPV was initialized - used as reference for transform scaling
    private var originalRenderSize: CGSize?

    // MARK: - Simulator Detection

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    // MARK: - HDR Support

    var hdrAvailable: Bool {
        let maxEDRRange = view.window?.screen.potentialEDRHeadroom ?? 1.0
        let sigPeak = getDouble(MPVProperty.videoParamsSigPeak)
        return maxEDRRange > 1.0 && sigPeak > 1.0
    }

    // MARK: - Lifecycle

    private var hasSetupMpv = false

    override func viewDidLoad() {
        super.viewDidLoad()

        // Ensure the view clips its contents to bounds
        view.clipsToBounds = true
        view.layer.masksToBounds = true

        // Use trait collection scale instead of deprecated UIScreen.main
        metalLayer.contentsScale = view.traitCollection.displayScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor

        view.layer.addSublayer(metalLayer)

        // Don't setup MPV here - wait for viewDidLayoutSubviews when we have proper bounds
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let newSize = view.bounds.size
        guard newSize.width > 0 && newSize.height > 0 else { return }

        // For multiview (when explicitTargetSize is set), use transform-based scaling
        // to avoid swapchain recreation which disrupts playback
        if explicitTargetSize != nil {
            updateLayerTransform(for: newSize)
            return
        }

        // For single-stream playback, use normal frame-based sizing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.anchorPoint = CGPoint(x: 0, y: 0)  // Reset to default
        metalLayer.transform = CATransform3DIdentity
        metalLayer.frame = view.bounds
        CATransaction.commit()

        // Setup MPV after we have proper bounds (not .zero)
        if !hasSetupMpv {
            hasSetupMpv = true
            lastKnownSize = newSize
            previousDrawableSize = metalLayer.drawableSize
            setupMpv()

            if let url = playUrl {
                loadFile(url)
            }
        }
    }

    /// Set explicit target size hint from parent (for multi-stream layout)
    /// Pass .zero to exit multiview mode and use normal frame-based sizing
    func setExplicitSize(_ size: CGSize) {
        if size == .zero {
            // Exiting multiview mode - reset to normal frame-based sizing
            let wasSet = explicitTargetSize != nil
            explicitTargetSize = nil
            originalRenderSize = nil

            // Reset layer to use normal frame-based sizing
            if wasSet && hasSetupMpv {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                metalLayer.anchorPoint = CGPoint(x: 0, y: 0)
                metalLayer.transform = CATransform3DIdentity
                metalLayer.frame = view.bounds
                CATransaction.commit()
            }
            return
        }

        let wasNil = explicitTargetSize == nil
        explicitTargetSize = size

        // First time entering multiview mode - initialize layer at this size
        if wasNil && !hasSetupMpv {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.frame = CGRect(origin: .zero, size: size)
            CATransaction.commit()

            hasSetupMpv = true
            lastKnownSize = size
            originalRenderSize = size  // Save original size for transform scaling
            previousDrawableSize = metalLayer.drawableSize
            setupMpv()

            if let url = playUrl {
                loadFile(url)
            }
        } else if hasSetupMpv {
            // MPV already running - update transform to fit new size
            updateLayerTransform(for: size)
        }
    }

    /// Update metal layer transform to scale content to fit new bounds
    /// This avoids swapchain recreation by keeping the drawable size fixed
    private func updateLayerTransform(for targetSize: CGSize) {
        guard targetSize.width > 0 && targetSize.height > 0 else { return }

        // If MPV isn't set up yet, initialize at current size and save as original
        if !hasSetupMpv {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.frame = CGRect(origin: .zero, size: targetSize)
            CATransaction.commit()

            hasSetupMpv = true
            lastKnownSize = targetSize
            originalRenderSize = targetSize  // Save the original size
            previousDrawableSize = metalLayer.drawableSize
            setupMpv()

            if let url = playUrl {
                loadFile(url)
            }
            return
        }

        // Use the original render size (saved at initialization) as reference
        // This ensures we're scaling from a fixed known size, not the current drawable
        guard let originalSize = originalRenderSize,
              originalSize.width > 0 && originalSize.height > 0 else {
            // Fallback: just set frame if we don't have original size yet
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.frame = CGRect(origin: .zero, size: targetSize)
            CATransaction.commit()
            return
        }

        // Calculate scale factors to fit original render size into target size
        let scaleX = targetSize.width / originalSize.width
        let scaleY = targetSize.height / originalSize.height

        // Use uniform scale to maintain aspect ratio
        let uniformScale = min(scaleX, scaleY)

        // Calculate the scaled size
        let scaledWidth = originalSize.width * uniformScale
        let scaledHeight = originalSize.height * uniformScale

        // Center in the view
        let offsetX = (targetSize.width - scaledWidth) / 2
        let offsetY = (targetSize.height - scaledHeight) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // IMPORTANT: Keep the layer at its ORIGINAL size (so drawable doesn't change)
        // Use anchorPoint + position + transform to scale and position it
        metalLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        metalLayer.bounds = CGRect(origin: .zero, size: originalSize)
        metalLayer.position = CGPoint(x: offsetX + scaledWidth / 2, y: offsetY + scaledHeight / 2)
        metalLayer.transform = CATransform3DMakeScale(uniformScale, uniformScale, 1.0)

        CATransaction.commit()
    }

    deinit {
        shutdownMpv()
    }

    private func shutdownMpv() {
        guard let mpvHandle = mpv, !isShuttingDown else { return }
        isShuttingDown = true

        // Clear delegate to prevent callbacks during shutdown
        delegate = nil

        // Remove audio route change observer
        if let observer = audioRouteObserver {
            NotificationCenter.default.removeObserver(observer)
            audioRouteObserver = nil
        }

        // Clear the wakeup callback to prevent dangling pointer
        mpv_set_wakeup_callback(mpvHandle, nil, nil)

        // Stop playback first - this begins GPU resource cleanup
        command("stop")

        // Tell MPV to quit gracefully - starts Vulkan cleanup
        command("quit")

        // Clear our reference immediately so we don't try to use it
        mpv = nil

        // Capture metal layer reference for cleanup after MPV destruction
        let layerToRemove = metalLayer

        // Do the heavy Vulkan/GPU cleanup on background thread
        // This prevents blocking the UI during mpv_terminate_destroy
        // IMPORTANT: Metal layer must be removed AFTER mpv_terminate_destroy
        // to avoid destroying textures while command buffers still reference them
        DispatchQueue.global(qos: .background).async {
            #if targetEnvironment(simulator)
            // Simulator: MoltenVK software rendering needs significant time for GPU flush
            // The simulator uses software rendering which is much slower to complete
            Thread.sleep(forTimeInterval: 1.0)
            #else
            // Device: Wait for GPU commands to flush
            Thread.sleep(forTimeInterval: 0.15)
            #endif

            // Now safe to destroy - this does the heavy Vulkan cleanup
            mpv_terminate_destroy(mpvHandle)

            // Only remove metal layer AFTER MPV has fully released all GPU resources
            // This ensures no command buffers reference the layer's textures
            DispatchQueue.main.async {
                layerToRemove.removeFromSuperlayer()
            }
        }
    }

    // MARK: - Audio Session Configuration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()

        do {
            // Use playback category with default mode
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
            try session.setActive(true, options: [])

            let routeType = session.currentRoute.outputs.first?.portType.rawValue ?? "unknown"
            print("🎬 AVAudioSession: Configured (route: \(routeType), channels: \(session.outputNumberOfChannels))")
        } catch {
            print("🎬 AVAudioSession: Configuration failed - \(error.localizedDescription)")
        }

        // Observe audio route changes
        if audioRouteObserver == nil {
            audioRouteObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioRouteChange(notification)
            }
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard !isShuttingDown, mpv != nil else { return }

        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        let session = AVAudioSession.sharedInstance()
        let newRoute = session.currentRoute.outputs.first?.portType.rawValue ?? "unknown"

        switch reason {
        case .newDeviceAvailable:
            print("🎬 AVAudioSession: New device available, switching to: \(newRoute)")
            reinitializeAudio()

        case .oldDeviceUnavailable:
            print("🎬 AVAudioSession: Device unavailable, switching to: \(newRoute)")
            reinitializeAudio()

        case .routeConfigurationChange:
            print("🎬 AVAudioSession: Route configuration changed to: \(newRoute)")
            reinitializeAudio()

        default:
            break
        }
    }

    private func reinitializeAudio() {
        guard mpv != nil, !isShuttingDown else { return }

        // Reconfigure audio session for new route
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("🎬 AVAudioSession: Reactivation failed - \(error.localizedDescription)")
        }

        // Trigger MPV audio reinitialization by resetting audio-device to default
        // Setting to empty string tells MPV to use system default
        setString("audio-device", "auto")
        print("🎬 MPV: Audio device reset to auto for route change")
    }

    // MARK: - MPV Setup

    private func setupMpv() {
        // Configure AVAudioSession BEFORE mpv creates its AudioUnit
        // Request max channels (up to 8 for 7.1) - requires patched MPVKit for tvOS
        configureAudioSession()

        mpv = mpv_create()
        guard mpv != nil else {
            print("Failed to create MPV context")
            return
        }

        // Logging
        #if DEBUG
        checkError(mpv_request_log_messages(mpv, "info"))
        #else
        checkError(mpv_request_log_messages(mpv, "no"))
        #endif

        // Rendering - use different settings for simulator vs device
        // Pass the metal layer as an Int64 pointer value to MPV
        var layerPtr = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerPtr))

        if isSimulator {
            // Simulator: Use 'gpu' renderer (more stable with MoltenVK)
            checkError(mpv_set_option_string(mpv, "vo", "gpu"))
            checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
            checkError(mpv_set_option_string(mpv, "hwdec", "no"))  // No hardware decode in simulator
            checkError(mpv_set_option_string(mpv, "vulkan-swap-mode", "fifo"))  // Sync mode for stability
            print("🎬 MPV: Using simulator-safe settings (gpu + software decode)")
        } else if isLiveStreamMode {
            // Live TV: Use 'gpu' with OpenGL - lighter weight, no HDR needed
            // Skips Vulkan/MoltenVK translation layer for lower resource usage
            checkError(mpv_set_option_string(mpv, "vo", "gpu"))
            checkError(mpv_set_option_string(mpv, "gpu-api", "opengl"))
            checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))  // Still use hardware decode
            checkError(mpv_set_option_string(mpv, "gpu-hwdec-interop", "videotoolbox"))

            print("🎬 MPV: Using live stream settings (gpu + OpenGL + VideoToolbox)")
        } else {
            // VOD: Use gpu-next with Vulkan (via MoltenVK) for HDR support
            // Note: gpu-next uses libplacebo which requires Vulkan; there's no native Metal path
            checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
            checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
            checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))  // Zero-copy hardware decode
            checkError(mpv_set_option_string(mpv, "target-colorspace-hint", "yes"))  // HDR passthrough

            // GPU optimizations - minimize CPU work
            checkError(mpv_set_option_string(mpv, "gpu-hwdec-interop", "videotoolbox"))  // Keep frames on GPU

            // Dolby Vision / HDR robustness options
            // Extra frames help with complex GOP structures in DV content
            checkError(mpv_set_option_string(mpv, "hwdec-extra-frames", "4"))
            // Allow recovery from hardware decode errors by seeking to keyframe
            checkError(mpv_set_option_string(mpv, "hr-seek-framedrop", "yes"))

            print("🎬 MPV: Using VOD settings (gpu-next + Vulkan/MoltenVK + VideoToolbox + HDR)")
        }

        // Audio configuration
        // Use audiounit which is the standard for tvOS
        checkError(mpv_set_option_string(mpv, "ao", "audiounit"))

        // CRITICAL: Allow video playback to continue if audio fails to initialize
        // This prevents the eARC handshake delay from blocking video entirely
        checkError(mpv_set_option_string(mpv, "audio-fallback-to-null", "yes"))

        // Whitelist 7.1, 5.1, and stereo layouts - mpv will pick the best match for the content
        // Note: 7.1 requires patched MPVKit to fix tvOS kAudioChannelLabel_Unknown bug for channels 7-8
        checkError(mpv_set_option_string(mpv, "audio-channels", "7.1,5.1,stereo"))
        print("🎬 MPV: Audio output: audiounit with null fallback enabled")

        // Audio buffer for smoother playback (default ~0.2s can cause stuttering with high-bitrate 4K content)
        let audioBufferResult = mpv_set_option_string(mpv, "audio-buffer", "1.0")
        if audioBufferResult < 0 {
            print("🎬 MPV: audio-buffer option not available (error \(audioBufferResult)), using default")
        }

        // Subtitles - use standard MPV options
        checkError(mpv_set_option_string(mpv, "sub-auto", "fuzzy"))
        checkError(mpv_set_option_string(mpv, "slang", "en,eng"))  // Prefer English subtitles

        // Performance
        // video-rotate=0 means no rotation
        checkError(mpv_set_option_string(mpv, "video-rotate", "0"))
        // Disable youtube-dl integration (not needed, saves startup time)
        mpv_set_option_string(mpv, "ytdl", "no")  // May not exist in all builds

        // Network & buffering - use smaller buffers for live streams to reduce CPU/memory
        checkError(mpv_set_option_string(mpv, "demuxer-lavf-o", "reconnect=1,reconnect_streamed=1"))
        if isLiveStreamMode {
            // Live TV: minimal buffering, no back-buffer (can't seek anyway)
            checkError(mpv_set_option_string(mpv, "cache", "yes"))
            checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "32MiB"))
            checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", "0"))
            checkError(mpv_set_option_string(mpv, "cache-secs", "10"))
            checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "5"))

            // Live edge behavior: always stay at the leading edge of the stream
            // When paused and resumed, or after buffering, jump to live edge
            checkError(mpv_set_option_string(mpv, "stream-lavf-o", "live_start_index=-1"))  // Start at live edge
            checkError(mpv_set_option_string(mpv, "cache-pause-initial", "no"))  // Don't wait for cache to fill
            checkError(mpv_set_option_string(mpv, "cache-pause-wait", "1"))  // Resume quickly after buffer (1 sec)

            // Reduce CPU overhead for live streams
            checkError(mpv_set_option_string(mpv, "vd-lavc-threads", "1"))  // Single decode thread (HW does the work)
            checkError(mpv_set_option_string(mpv, "scale", "bilinear"))  // Fast GPU scaling
            checkError(mpv_set_option_string(mpv, "dscale", "bilinear"))  // Fast downscaling
            checkError(mpv_set_option_string(mpv, "dither", "no"))  // Disable dithering
            checkError(mpv_set_option_string(mpv, "correct-downscaling", "no"))  // Skip correction
            checkError(mpv_set_option_string(mpv, "linear-downscaling", "no"))  // Skip linear light
            checkError(mpv_set_option_string(mpv, "deband", "no"))  // No debanding
            checkError(mpv_set_option_string(mpv, "interpolation", "no"))  // No frame interpolation

            print("🎬 MPV: Using live stream optimized settings (live edge, minimal processing)")
        } else {
            // VOD: larger buffers for smooth 4K HDR playback (100+ Mbps streams)
            // 250MiB forward buffer + 30s readahead provides ~30 seconds of 4K content
            checkError(mpv_set_option_string(mpv, "cache", "yes"))
            checkError(mpv_set_option_string(mpv, "demuxer-max-bytes", "250MiB"))
            checkError(mpv_set_option_string(mpv, "demuxer-max-back-bytes", "100MiB"))
            checkError(mpv_set_option_string(mpv, "cache-secs", "30"))
            checkError(mpv_set_option_string(mpv, "demuxer-readahead-secs", "30"))

            // High quality scaling for 720p/1080p content upscaled to 4K
            // Skip for Live TV - use fast bilinear to reduce GPU load for multiview
            let highQualityScaling = UserDefaults.standard.bool(forKey: "highQualityScaling")
            if highQualityScaling && !isLiveStreamMode {
                checkError(mpv_set_option_string(mpv, "scale", "ewa_lanczossharp"))  // Best quality upscaling
                checkError(mpv_set_option_string(mpv, "dscale", "mitchell"))         // Quality downscaling
                checkError(mpv_set_option_string(mpv, "cscale", "ewa_lanczossharp")) // Best chroma upscaling
                print("🎬 MPV: High quality scaling enabled (ewa_lanczossharp/mitchell)")
            } else if isLiveStreamMode {
                print("🎬 MPV: Live TV mode - using fast bilinear scaling")
            }
        }

        checkError(mpv_initialize(mpv))

        // Observe properties
        mpv_observe_property(mpv, 0, MPVProperty.pause, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.coreIdle, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.eofReached, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.seeking, MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, MPVProperty.timePos, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.duration, MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, MPVProperty.trackListCount, MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, MPVProperty.videoParamsSigPeak, MPV_FORMAT_DOUBLE)

        // Setup wakeup callback
        mpv_set_wakeup_callback(mpv, { ctx in
            let client = unsafeBitCast(ctx, to: MPVMetalViewController.self)
            client.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    // MARK: - Playback Controls

    func loadFile(_ url: URL) {
        guard mpv != nil else { return }

        updateState(.loading)

        let args = [url.absoluteString, "replace"]

        // Add HTTP headers if provided
        if let headers = httpHeaders, !headers.isEmpty {
            let headerString = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
            setString("http-header-fields", headerString)
        }

        // Set start position BEFORE loading file - MPV will seek to this position
        // during file load, which is more reliable than seeking after load
        if let startTime = startTime, startTime > 0 {
            setString("start", String(format: "%.3f", startTime))
            print("🎬 MPV: Setting start position to \(startTime)s")
        } else {
            setString("start", "0")
        }

        command("loadfile", args: args)
    }

    func play() {
        setFlag(MPVProperty.pause, false)
    }

    func pause() {
        setFlag(MPVProperty.pause, true)
    }

    func togglePause() {
        getFlag(MPVProperty.pause) ? play() : pause()
    }

    func stop() {
        command("stop")
        updateState(.idle)
        // Trigger full shutdown to ensure clean state for next player instance
        shutdownMpv()
    }

    func seek(to seconds: Double) {
        guard mpv != nil else { return }
        command("seek", args: [String(seconds), "absolute"])
    }

    func seekRelative(by seconds: Double) {
        guard mpv != nil else { return }
        command("seek", args: [String(seconds), "relative"])
    }

    // MARK: - Track Selection

    func selectAudioTrack(_ trackId: Int) {
        setInt(MPVProperty.aid, Int64(trackId))
    }

    func selectSubtitleTrack(_ trackId: Int?) {
        if let id = trackId {
            setInt(MPVProperty.sid, Int64(id))
        } else {
            setString(MPVProperty.sid, "no")
        }
    }

    func disableSubtitles() {
        setString(MPVProperty.sid, "no")
    }

    // MARK: - Audio Control

    var isMuted: Bool {
        getFlag(MPVProperty.mute)
    }

    func setMuted(_ muted: Bool) {
        setFlag(MPVProperty.mute, muted)
    }

    // MARK: - Property Getters

    var currentTime: Double {
        getDouble(MPVProperty.timePos)
    }

    var duration: Double {
        getDouble(MPVProperty.duration)
    }

    var isPlaying: Bool {
        !getFlag(MPVProperty.pause) && !getFlag(MPVProperty.coreIdle)
    }

    var isPaused: Bool {
        getFlag(MPVProperty.pause)
    }

    var playbackRate: Float {
        get { Float(getDouble(MPVProperty.speed)) }
        set { setDouble(MPVProperty.speed, Double(newValue)) }
    }

    // MARK: - Track Enumeration

    func getTracks() -> (audio: [MPVTrack], subtitles: [MPVTrack]) {
        guard mpv != nil else { return ([], []) }

        var audioTracks: [MPVTrack] = []
        var subtitleTracks: [MPVTrack] = []

        let count = Int(getInt(MPVProperty.trackListCount))

        for i in 0..<count {
            let prefix = "track-list/\(i)"

            guard let typeStr = getString("\(prefix)/type") else { continue }

            let type: MPVTrack.TrackType
            switch typeStr {
            case "audio": type = .audio
            case "sub": type = .subtitle
            case "video": type = .video
            default: continue
            }

            let track = MPVTrack(
                id: Int(getInt("\(prefix)/id")),
                type: type,
                title: getString("\(prefix)/title"),
                language: getString("\(prefix)/lang"),
                codec: getString("\(prefix)/codec"),
                isDefault: getFlag("\(prefix)/default"),
                isForced: getFlag("\(prefix)/forced"),
                isSelected: getFlag("\(prefix)/selected"),
                channels: nil,
                sampleRate: nil
            )

            switch type {
            case .audio:
                audioTracks.append(track)
            case .subtitle:
                subtitleTracks.append(track)
            case .video:
                break
            }
        }

        return (audioTracks, subtitleTracks)
    }

    // MARK: - Event Handling

    private func readEvents() {
        queue.async { [weak self] in
            guard let self, self.mpv != nil, !self.isShuttingDown else { return }

            while self.mpv != nil && !self.isShuttingDown {
                let event = mpv_wait_event(self.mpv, 0)
                guard event?.pointee.event_id != MPV_EVENT_NONE else { break }

                self.handleEvent(event!.pointee)
            }
        }
    }

    private func handleEvent(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            handlePropertyChange(event)

        case MPV_EVENT_START_FILE:
            DispatchQueue.main.async { [weak self] in
                self?.updateState(.loading)
            }

        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let tracks = self.getTracks()
                self.delegate?.mpvPlayerDidUpdateTracks(audio: tracks.audio, subtitles: tracks.subtitles)
                self.updateState(.playing)
            }

        case MPV_EVENT_PLAYBACK_RESTART:
            DispatchQueue.main.async { [weak self] in
                if self?.currentState == .buffering {
                    self?.updateState(.playing)
                }
            }

        case MPV_EVENT_END_FILE:
            let endFile = event.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let reason = endFile.reason
            DispatchQueue.main.async { [weak self] in
                if reason == MPV_END_FILE_REASON_EOF {
                    self?.updateState(.ended)
                } else if reason == MPV_END_FILE_REASON_ERROR {
                    // Capture detailed error from MPV
                    let errorCode = endFile.error
                    let errorString: String
                    if let cString = mpv_error_string(errorCode) {
                        errorString = String(cString: cString)
                    } else {
                        errorString = "Unknown error (code: \(errorCode))"
                    }
                    let detailedError = "MPV error: \(errorString)"
                    self?.updateState(.error(detailedError))
                    self?.delegate?.mpvPlayerDidEncounterError(detailedError)
                }
            }

        case MPV_EVENT_SHUTDOWN:
            // Don't call mpv_terminate_destroy here - let shutdownMpv() handle it
            // to ensure proper GPU resource cleanup before destruction
            DispatchQueue.main.async { [weak self] in
                self?.shutdownMpv()
            }

        case MPV_EVENT_LOG_MESSAGE:
            #if DEBUG
            let msg = event.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            if let prefix = msg.prefix, let text = msg.text {
                print("[MPV \(String(cString: prefix))] \(String(cString: text))", terminator: "")
            }
            #endif

        default:
            break
        }
    }

    private func handlePropertyChange(_ event: mpv_event) {
        guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
              let name = property.name else { return }

        let propertyName = String(cString: name)

        switch propertyName {
        case MPVProperty.pause:
            let paused = property.data?.assumingMemoryBound(to: Int32.self).pointee ?? 0
            DispatchQueue.main.async { [weak self] in
                self?.updateState(paused != 0 ? .paused : .playing)
            }

        case MPVProperty.pausedForCache:
            let buffering = property.data?.assumingMemoryBound(to: Int32.self).pointee ?? 0
            DispatchQueue.main.async { [weak self] in
                if buffering != 0 {
                    self?.updateState(.buffering)
                } else if self?.currentState == .buffering {
                    self?.updateState(.playing)
                }
            }

        case MPVProperty.timePos:
            // Note: Live edge detection was removed because MPV handles timestamp
            // discontinuities automatically via "Reset playback due to audio timestamp reset".
            // Our seek attempts were interfering with MPV's built-in recovery.

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.mpvPlayerTimeDidChange(
                    current: self.currentTime,
                    duration: self.duration
                )
            }

        case MPVProperty.duration:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.mpvPlayerTimeDidChange(
                    current: self.currentTime,
                    duration: self.duration
                )
            }

        case MPVProperty.trackListCount:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let tracks = self.getTracks()
                self.delegate?.mpvPlayerDidUpdateTracks(audio: tracks.audio, subtitles: tracks.subtitles)
            }

        case MPVProperty.eofReached:
            let eof = property.data?.assumingMemoryBound(to: Int32.self).pointee ?? 0
            if eof != 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.updateState(.ended)
                }
            }

        default:
            break
        }
    }

    private func updateState(_ newState: MPVPlayerState) {
        guard currentState != newState else { return }
        currentState = newState
        delegate?.mpvPlayerDidChangeState(newState)
    }

    // MARK: - MPV Property Helpers

    private func command(_ command: String, args: [String] = []) {
        guard mpv != nil else { return }

        let allArgs = [command] + args
        var cStrings = allArgs.map { strdup($0) }
        cStrings.append(nil)
        defer { cStrings.compactMap { $0 }.forEach { free($0) } }

        cStrings.withUnsafeMutableBufferPointer { buffer in
            buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { reboundBuffer in
                let result = mpv_command(mpv, reboundBuffer.baseAddress)
                if result < 0 {
                    print("MPV command '\(command)' failed: \(String(cString: mpv_error_string(result)))")
                }
            }
        }
    }

    private func getDouble(_ name: String) -> Double {
        guard mpv != nil else { return 0 }
        var data: Double = 0
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard mpv != nil else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    }

    private func getInt(_ name: String) -> Int64 {
        guard mpv != nil else { return 0 }
        var data: Int64 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return data
    }

    private func setInt(_ name: String, _ value: Int64) {
        guard mpv != nil else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data)
    }

    private func getFlag(_ name: String) -> Bool {
        guard mpv != nil else { return false }
        var data: Int32 = 0
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data != 0
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard mpv != nil else { return }
        var data: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private func getString(_ name: String) -> String? {
        guard mpv != nil else { return nil }
        guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
        let str = String(cString: cstr)
        mpv_free(cstr)
        return str
    }

    private func setString(_ name: String, _ value: String) {
        guard mpv != nil else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func checkError(_ status: CInt) {
        if status < 0 {
            print("MPV error: \(String(cString: mpv_error_string(status)))")
        }
    }
}
