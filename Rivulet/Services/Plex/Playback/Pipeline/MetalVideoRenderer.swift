//
//  MetalVideoRenderer.swift
//  Rivulet
//
//  A CAMetalLayer-based video renderer that owns its VTDecompressionSession,
//  buffers decoded CVPixelBuffers, and presents them in sync with the shared
//  AVSampleBufferRenderSynchronizer.
//
//  Designed as a parallel video sink to AVSampleBufferDisplayLayer. The pipeline
//  hands encoded CMSampleBuffers to `enqueue(_:)`; VT decode runs async, decoded
//  frames land in a PTS-keyed queue, and a CADisplayLink picks the matching frame
//  on each tick by reading `synchronizer.currentTime()`. Audio remains gated by
//  the synchronizer's audio renderer; the synchronizer's clock is the source of
//  truth for video presentation.
//
//  HDR rationale on tvOS 26: CAEDRMetadata and wantsExtendedDynamicRangeContent
//  are unavailable. The supported path is CALayer.toneMapMode = .ifSupported
//  (tvOS 18+) plus CALayer.preferredDynamicRange (tvOS 26+) plus a CAMetalLayer
//  with rgba16Float pixel format and an HDR-tagged colorspace. The system applies
//  HLG/PQ tonemapping; we do not implement OETF inversion ourselves.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import Metal
import QuartzCore
import UIKit

/// Mirrors the subset of `AVSampleBufferDisplayLayer` API that
/// `SampleBufferRenderer` consumes. Methods are intentionally named to match.
@MainActor
final class MetalVideoRenderer {

    // MARK: - Public

    /// The hosting UIView. Pipeline attaches this to its SwiftUI view.
    let view: MetalVideoRendererView

    /// Status mirroring AVQueuedSampleBufferRenderingStatus.
    private(set) var status: AVQueuedSampleBufferRenderingStatus = .unknown

    /// Last error, if any.
    private(set) var error: Error?

    /// Whether enqueue should be called: total pending work (queued + in-flight
    /// in VT) not yet at the cap. Counting in-flight is essential — without it,
    /// the demuxer reads far ahead and stuffs VT's pipeline, callbacks complete
    /// in a burst, queue saturates, drop-newest silently drops frames. That
    /// gaps the queue, halves the achievable pop cadence, and shows on screen
    /// as steady ~12.5 fps stutter on 25 fps source.
    var isReadyForMoreMediaData: Bool {
        queueLock.lock()
        defer { queueLock.unlock() }
        let inFlight = max(0, enqueueCount - decodeCallbackCount)
        return (frameQueue.count + inFlight) < maxQueueDepth
    }

    /// One-shot flag mirroring `SampleBufferRenderer.hasLoggedFirstVideoEnqueue`.
    /// Reset on flush so post-seek startup can re-emit a marker.
    private(set) var hasLoggedFirstFrame = false

    // MARK: - Synchronizer / Timing

    private let synchronizer: AVSampleBufferRenderSynchronizer

    // MARK: - Metal

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var pipelineState: MTLRenderPipelineState?
    private let metalLayer: CAMetalLayer

    // MARK: - VT Decode

    private var decompressionSession: VTDecompressionSession?
    private var configuredFormatDescription: CMFormatDescription?

    /// True when we've initialized the colorspace + pipeline for the current
    /// content's color characteristics. Set in `configure(formatDescription:)`.
    private var hasAppliedColorConfiguration = false

    /// When the demuxer hands us an HEVC FD whose hvcC has numArrays=0 (in-band
    /// parameter sets only, typical of `hev1`-muxed content tagged as `hvc1`),
    /// we defer VT session creation to the first sample and extract VPS/SPS/PPS
    /// from the NALU stream. Once built, this FD is used for both the VT
    /// session and to re-stamp every incoming sample buffer (so the session's
    /// FD matches the per-sample FD).
    private var rebuiltFormatDescription: CMFormatDescription?

    /// Whether we've tried + failed to build VT session from the FD alone,
    /// so enqueue should attempt sample-based parameter set extraction.
    private var awaitingSampleBasedFD = false

    // MARK: - Frame Queue

    /// Bounded queue of decoded frames sorted by PTS ascending.
    /// 8 frames ~= 133ms at 60fps; enough cushion for one missed display tick
    /// without back-pressuring the demuxer too aggressively.
    private let maxQueueDepth = 8
    private let queueLock = NSLock()
    private nonisolated(unsafe) var frameQueue: [(pts: CMTime, pixelBuffer: CVPixelBuffer)] = []
    private nonisolated(unsafe) var lastPresentedPTS: CMTime = .invalid

    // MARK: - Display Link

    private var displayLink: CADisplayLink?

    // MARK: - Diagnostics

    private var enqueueCount: Int = 0
    private nonisolated(unsafe) var decodeCallbackCount: Int = 0
    private var presentedFrameCount: Int = 0
    private var droppedFrameCount: Int = 0
    private var tickCount: Int = 0
    private var lastLogWallTime: CFAbsoluteTime = 0
    // Branch counters reset by tick-stats log.
    private var brDuePop: Int = 0          // while-loop popped a due frame
    private var brImmPop: Int = 0          // imminent-pop branch popped
    private var brSkipEmpty: Int = 0       // queue empty
    private var brSkipFar: Int = 0         // head ahead by >= threshold
    private var skipAheadMsSum: Double = 0 // accumulated aheadMs for skipFar
    private var skipAheadMsMax: Double = 0

    // MARK: - Init / Lifecycle

    /// Returns nil if Metal is unavailable on this device (shouldn't happen on
    /// Apple TV 4K but we should fall back to AVSBL gracefully if it ever does).
    init?(synchronizer: AVSampleBufferRenderSynchronizer) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            playerDebugLog("[MetalRenderer] init: Metal unavailable")
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.synchronizer = synchronizer
        self.metalLayer = CAMetalLayer()
        self.view = MetalVideoRendererView(metalLayer: metalLayer)

        // Defaults; refined in configure(formatDescription:).
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = UIColor.black.cgColor

        // Tone-map mode is the tvOS 18+ path: ifSupported lets the system tonemap
        // HLG/PQ contents on the drawable. Without this, HDR transfer functions
        // would not be honored.
        if #available(tvOS 18.0, *) {
            metalLayer.toneMapMode = .ifSupported
        }

        // Texture cache for zero-copy CVPixelBuffer -> MTLTexture.
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            playerDebugLog("[MetalRenderer] init: CVMetalTextureCacheCreate failed (\(cacheStatus))")
            return nil
        }
        self.textureCache = cache

        playerDebugLog("[MetalRenderer] init: device=\(device.name)")
    }

    deinit {
        // displayLink invalidate and VT session tear-down both safe from deinit
        // (no main-actor isolation requirement).
        displayLink?.invalidate()
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Begin presentation. Idempotent.
    func start() {
        if displayLink == nil {
            // CADisplayLink target is a Sendable trampoline so we don't capture
            // self with a non-isolated closure.
            let link = CADisplayLink(
                target: DisplayLinkTrampoline(owner: self),
                selector: #selector(DisplayLinkTrampoline.tick)
            )
            link.add(to: .main, forMode: .common)
            displayLink = link
            playerDebugLog("[MetalRenderer] displayLink started")
        }
        status = .rendering
    }

    /// Stop presentation and tear down the display link.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        status = .unknown
        playerDebugLog("[MetalRenderer] displayLink stopped")
    }

    // MARK: - Configuration

    /// Configure VT session + Metal layer for the given video format.
    /// Called once at start of playback after the first format description is
    /// known. Subsequent calls with a different format trigger a re-init.
    func configure(formatDescription: CMFormatDescription) {
        // Tear down prior session if the format is different (e.g. resolution
        // change or codec switch).
        if let configuredFormatDescription,
           !CMFormatDescriptionEqual(configuredFormatDescription, otherFormatDescription: formatDescription) {
            if let session = decompressionSession {
                VTDecompressionSessionInvalidate(session)
            }
            decompressionSession = nil
        }
        configuredFormatDescription = formatDescription

        applyLayerColorConfiguration(for: formatDescription)
        buildRenderPipelineIfNeeded()
        createDecompressionSessionIfNeeded(for: formatDescription)
    }

    // MARK: - Enqueue

    /// Hand an encoded CMSampleBuffer to VT decode. Non-blocking. Safe to call
    /// from any thread (the pipeline calls from a read task off main).
    nonisolated func enqueue(_ sampleBuffer: CMSampleBuffer) {
        Task { @MainActor in
            self.enqueueOnMain(sampleBuffer)
        }
    }

    private func enqueueOnMain(_ sampleBuffer: CMSampleBuffer) {
        enqueueCount += 1

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            playerDebugLog("[MetalRenderer] enqueue: sample has no format description")
            return
        }

        // Configure exactly once per unique format description. If VT session
        // creation failed on the first attempt, do NOT retry on every sample —
        // that produces a log storm and burns CPU. Same FD always gives the
        // same outcome.
        let needsConfigure: Bool
        if let existing = configuredFormatDescription {
            needsConfigure = !CMFormatDescriptionEqual(existing, otherFormatDescription: formatDescription)
        } else {
            needsConfigure = true
        }
        if needsConfigure {
            configure(formatDescription: formatDescription)
        }

        // Sample-based VT-session rebuild: if the demuxer's FD had an empty
        // hvcC and configure() couldn't build a VT session, scan this sample's
        // NALU stream for in-band VPS/SPS/PPS and rebuild the FD from those.
        if decompressionSession == nil && awaitingSampleBasedFD {
            buildSessionFromSampleBuffer(sampleBuffer, originalFormatDescription: formatDescription)
        }

        guard let session = decompressionSession else {
            // First few samples after a failed configure: log once, then stay quiet.
            if enqueueCount == 1 || enqueueCount % 500 == 0 {
                playerDebugLog("[MetalRenderer] enqueue: no decompression session (sample #\(enqueueCount) dropped)")
            }
            return
        }

        // Re-stamp the sample buffer with the rebuilt FD when present. VT
        // rejects samples whose FD differs from the session's FD with
        // kVTFormatDescriptionChangeNotSupportedErr (-12916), so we copy the
        // sample into a new CMSampleBuffer that carries the corrected FD.
        let sampleBufferForDecode: CMSampleBuffer
        if let rebuiltFormatDescription,
           let restamped = Self.restampSampleBuffer(sampleBuffer, with: rebuiltFormatDescription) {
            sampleBufferForDecode = restamped
        } else {
            sampleBufferForDecode = sampleBuffer
        }

        var flagsOut = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBufferForDecode,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )

        if decodeStatus != noErr {
            playerDebugLog("[MetalRenderer] VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
            if decodeStatus == kVTInvalidSessionErr {
                // Session went south; re-create on next sample.
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
            }
        }
    }

    // MARK: - Flush

    /// Drop all queued frames + flush VT session. Mirrors `displayLayer.flush()`.
    func flush() {
        if let session = decompressionSession {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        queueLock.lock()
        frameQueue.removeAll(keepingCapacity: true)
        lastPresentedPTS = .invalid
        queueLock.unlock()
        hasLoggedFirstFrame = false
        playerDebugLog("[MetalRenderer] flush")
    }

    /// Flush + clear last-presented image. Mirrors `displayLayer.flushAndRemoveImage()`.
    func flushAndRemoveImage() {
        flush()
        // Render one black frame so the layer doesn't hold the last image.
        renderBlack()
    }

    // MARK: - Color / Layer Configuration

    private func applyLayerColorConfiguration(for formatDescription: CMFormatDescription) {
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] ?? [:]
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String

        let isHLG = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let isPQ = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        let isHDR = isHLG || isPQ

        if isHDR {
            metalLayer.pixelFormat = .rgba16Float
            if isHLG {
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            } else {
                metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            }
        } else {
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        // tvOS 26+: explicitly request high dynamic range when the content is HDR.
        // For SDR, leave at default (CADynamicRangeStandard) so layer composites
        // cleanly with surrounding UI.
        if #available(tvOS 26.0, *) {
            metalLayer.preferredDynamicRange = isHDR ? .high : .standard
        }

        hasAppliedColorConfiguration = true

        playerDebugLog(
            "[MetalRenderer] applyLayerColorConfiguration: " +
            "transfer=\(transfer ?? "nil") primaries=\(primaries ?? "nil") " +
            "isHDR=\(isHDR) pixelFormat=\(metalLayer.pixelFormat.rawValue)"
        )
    }

    // MARK: - VT Session

    private func createDecompressionSessionIfNeeded(for formatDescription: CMFormatDescription) {
        guard decompressionSession == nil else { return }

        // Decide output pixel format: 10-bit for HDR, 8-bit for SDR.
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] ?? [:]
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
        let isHDR = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)

        let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
        playerDebugLog(
            "[MetalRenderer] preparing VT session: codec=\(fourCCString(codecType)) " +
            "dims=\(dims.width)x\(dims.height) hdr=\(isHDR) " +
            "transfer=\(transfer ?? "nil") extensions=\(extensions.keys.count)"
        )

        let outputPixelFormat: OSType = isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputPixelFormat,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
        ]

        var session: VTDecompressionSession?
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (
                decompressionOutputRefCon, sourceFrameRefCon, status, infoFlags,
                imageBuffer, presentationTimeStamp, presentationDuration
            ) in
                guard let decompressionOutputRefCon else { return }
                let renderer = Unmanaged<MetalVideoRenderer>
                    .fromOpaque(decompressionOutputRefCon)
                    .takeUnretainedValue()
                renderer.handleDecodedFrame(
                    status: status,
                    imageBuffer: imageBuffer,
                    pts: presentationTimeStamp
                )
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        // Canonicalise the format description via the parameter-set API. The
        // FFmpegDemuxer-built FD passes AVSampleBufferDisplayLayer fine but
        // VTDecompressionSessionCreate rejects it with status -4 (unimpErr).
        // Apple's own DV conversion path also rebuilds via the parameter-set
        // API for the same reason.
        let canonicalFD = Self.canonicaliseHEVCFormatDescription(formatDescription) ?? formatDescription
        if canonicalFD !== formatDescription {
            playerDebugLog("[MetalRenderer] canonicalised FD via CMVideoFormatDescriptionCreateFromHEVCParameterSets")
        }

        // Try with output attributes first. If that fails, retry with nil to let
        // VT pick its preferred format. The CVMetalTextureCache binding step
        // handles the actual format inspection at draw time.
        var createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: canonicalFD,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        if createStatus != noErr {
            playerDebugLog(
                "[MetalRenderer] VTDecompressionSessionCreate failed with full attrs (status=\(createStatus)); retrying without pixelFormat hint"
            )
            // Keep Metal compatibility so the output CVPixelBuffer is still
            // bindable via CVMetalTextureCache; drop the pixelFormat hint so
            // VT picks its own preferred output (typically 10-bit p010 for
            // HEVC HLG on Apple TV 4K).
            let fallbackAttrs: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
            ]
            createStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: canonicalFD,
                decoderSpecification: nil,
                imageBufferAttributes: fallbackAttrs as CFDictionary,
                outputCallback: &callbackRecord,
                decompressionSessionOut: &session
            )
            if createStatus != noErr {
                playerDebugLog(
                    "[MetalRenderer] VTDecompressionSessionCreate failed with Metal-only attrs (status=\(createStatus)); retrying nil attrs"
                )
                createStatus = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault,
                    formatDescription: canonicalFD,
                    decoderSpecification: nil,
                    imageBufferAttributes: nil,
                    outputCallback: &callbackRecord,
                    decompressionSessionOut: &session
                )
            }
        }

        guard createStatus == noErr, let session else {
            playerDebugLog("[MetalRenderer] VTDecompressionSessionCreate failed (final): \(createStatus); will retry with sample-extracted parameter sets")
            // Defer to enqueue, which will pull VPS/SPS/PPS from the first
            // sample's in-band NALU stream and rebuild the FD.
            awaitingSampleBasedFD = true
            return
        }

        // Realtime hint: encourages VT to allocate higher-priority decoder threads.
        VTSessionSetProperty(session,
                             key: kVTDecompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)

        decompressionSession = session

        playerDebugLog(
            "[MetalRenderer] VT session created: codec=\(fourCCString(codecType)) " +
            "outputPixelFormat=\(fourCCString(outputPixelFormat)) hdr=\(isHDR)"
        )
    }

    /// VT decode callback (runs on VT's private thread). Push the decoded frame
    /// onto the queue.
    private nonisolated func handleDecodedFrame(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        pts: CMTime
    ) {
        // Count every callback (including failures) so the in-flight delta
        // used by isReadyForMoreMediaData stays accurate — otherwise failed
        // decodes leak in-flight count and the demuxer would eventually wedge.
        decodeCallbackCount += 1

        if status != noErr {
            playerDebugLog("[MetalRenderer] decode callback: status=\(status)")
            return
        }
        guard let pixelBuffer = imageBuffer else { return }
        guard pts.isValid, pts.isNumeric else { return }

        if decodeCallbackCount == 1 {
            let pf = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
            let plane0Width = planeCount > 0 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : 0
            let plane0Stride = planeCount > 0 ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : 0
            let plane1Stride = planeCount > 1 ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) : 0
            playerDebugLog(
                "[MetalRenderer] first decoded frame: pixelFormat=\(fourCCNonisolated(pf)) " +
                "(0x\(String(pf, radix: 16))) dims=\(w)x\(h) planes=\(planeCount) " +
                "plane0Width=\(plane0Width) plane0Stride=\(plane0Stride) plane1Stride=\(plane1Stride)"
            )
        }

        queueLock.lock()

        // Drop frames older than the most recently presented PTS (post-flush
        // out-of-order callbacks).
        if lastPresentedPTS.isValid && CMTimeCompare(pts, lastPresentedPTS) < 0 {
            queueLock.unlock()
            return
        }

        // Cap queue depth. If saturated, drop the NEWEST frame (furthest in
        // the future) rather than the oldest — the oldest is what we're about
        // to present, dropping it skips visible frames. The newest can be
        // recomputed if needed.
        let entry = (pts: pts, pixelBuffer: pixelBuffer)
        if frameQueue.count >= maxQueueDepth {
            // Determine where this PTS would land. If it'd go at/near the
            // back, just discard it; if it'd go near the front, evict the
            // current back and insert.
            if let last = frameQueue.last, CMTimeCompare(pts, last.pts) >= 0 {
                queueLock.unlock()
                return  // newest; drop it
            }
            frameQueue.removeLast()
        }

        // Insert sorted by PTS (B-frame reorder produces out-of-order callbacks).
        if let last = frameQueue.last, CMTimeCompare(pts, last.pts) >= 0 {
            frameQueue.append(entry)
        } else {
            let idx = frameQueue.firstIndex(where: { CMTimeCompare($0.pts, pts) > 0 }) ?? frameQueue.endIndex
            frameQueue.insert(entry, at: idx)
        }
        queueLock.unlock()
    }

    // MARK: - Present

    /// CADisplayLink tick. Pick the best queued frame for the current sync time
    /// and draw it.
    fileprivate func displayLinkTick() {
        tickCount += 1
        let tickStart = CFAbsoluteTimeGetCurrent()
        defer {
            let elapsed = (CFAbsoluteTimeGetCurrent() - tickStart) * 1000
            if elapsed > 30 {
                playerDebugLog(String(format: "[MetalRenderer] tick slow: %.1fms", elapsed))
            }
        }

        let syncTime = synchronizer.currentTime()
        guard syncTime.isValid, syncTime.isNumeric else { return }

        // Find largest PTS <= syncTime. Anything strictly less than syncTime is
        // already due. We want the latest such frame; older queued frames are
        // dropped.
        // Pop head if its PTS is already due, OR if it's the next frame and
        // we want to schedule its presentation at exactly its PTS. We use
        // `commandBuffer.present(drawable, atTime:)` to hand presentation
        // timing to Metal's compositor — it queues the drawable for the right
        // vsync. Without this, CADisplayLink's tick alignment can cause
        // adjacent ticks to coalesce and present rate halves.
        // Vsync alignment: pop a frame if its scheduled present time is at or
        // before the next display vsync. Avoids the arbitrary-threshold pitfall
        // of the prior `aheadMs < 80` gate, which on 25fps/50Hz produced a
        // ~1-pop-per-4-ticks cadence (≈12.5 fps presented) instead of the
        // expected 1-pop-per-2-ticks (25 fps).
        let nowHost = CFTimeInterval(CACurrentMediaTime())
        let nextVsync = displayLink?.targetTimestamp ?? (nowHost + 0.02)
        let syncSeconds = CMTimeGetSeconds(syncTime)

        var selected: (pts: CMTime, pixelBuffer: CVPixelBuffer)?
        var skipAheadMs: Double = -1  // -1 = empty queue
        queueLock.lock()
        let initialQueueDepth = frameQueue.count
        // Catch-up: pop all already-due frames; keep the latest (drop older).
        while let head = frameQueue.first, CMTimeCompare(head.pts, syncTime) <= 0 {
            if selected != nil { droppedFrameCount += 1 }
            selected = head
            frameQueue.removeFirst()
        }
        if selected != nil {
            brDuePop += 1
        } else if let head = frameQueue.first {
            // Pop the head if its scheduled present time falls at or before the
            // next display vsync. Slack of 2ms covers float/clock jitter.
            let headPts = CMTimeGetSeconds(head.pts)
            let headHostTime = nowHost + (headPts - syncSeconds)
            let aheadMs = (headPts - syncSeconds) * 1000
            if headHostTime <= nextVsync + 0.002 {
                selected = head
                frameQueue.removeFirst()
                brImmPop += 1
            } else {
                brSkipFar += 1
                skipAheadMs = aheadMs
                skipAheadMsSum += aheadMs
                if aheadMs > skipAheadMsMax { skipAheadMsMax = aheadMs }
            }
        } else {
            brSkipEmpty += 1
        }
        queueLock.unlock()

        guard let frame = selected else {
            if tickCount % 30 == 0 {
                playerDebugLog(String(
                    format: "[MetalRenderer] skip tick: queue=%d sync=%.3f aheadMs=%.1f",
                    initialQueueDepth, CMTimeGetSeconds(syncTime), skipAheadMs
                ))
            }
            return
        }
        lastPresentedPTS = frame.pts

        // Convert the frame's PTS to host time so Metal can present at the
        // correct vsync. nowHost + (frame_pts - sync_seconds) gives the wall-
        // host time at which this frame should appear on screen.
        let frameSeconds = CMTimeGetSeconds(frame.pts)
        let targetHostTime = nowHost + max(0, frameSeconds - syncSeconds)
        render(pixelBuffer: frame.pixelBuffer, atHostTime: targetHostTime)

        presentedFrameCount += 1
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            playerDebugLog(String(
                format: "[MetalRenderer] first_video_present pts=%.3f syncTime=%.3f",
                CMTimeGetSeconds(frame.pts), CMTimeGetSeconds(syncTime)
            ))
        }

        // Periodic diag log.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLogWallTime > 5.0 {
            lastLogWallTime = now
            queueLock.lock()
            let queueDepth = frameQueue.count
            queueLock.unlock()
            let skipSummary = renderSkipReason.isEmpty ? "" : " skip=" + renderSkipReason
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            let skipFarAvg = brSkipFar > 0 ? skipAheadMsSum / Double(brSkipFar) : 0
            playerDebugLog(
                "[MetalRenderer] tick stats: ticks=\(tickCount) enq=\(enqueueCount) decoded=\(decodeCallbackCount) " +
                "presented=\(presentedFrameCount) dropped=\(droppedFrameCount) " +
                "queue=\(queueDepth) syncTime=\(String(format: "%.3f", CMTimeGetSeconds(syncTime))) " +
                "br[duePop=\(brDuePop) immPop=\(brImmPop) skipEmpty=\(brSkipEmpty) skipFar=\(brSkipFar) " +
                String(format: "farAvg=%.1f farMax=%.1f]", skipFarAvg, skipAheadMsMax) +
                skipSummary
            )
            // Reset branch counters per window.
            brDuePop = 0; brImmPop = 0; brSkipEmpty = 0; brSkipFar = 0
            skipAheadMsSum = 0; skipAheadMsMax = 0
        }
    }

    private var renderSkipReason: [String: Int] = [:]
    private func render(pixelBuffer: CVPixelBuffer, atHostTime: CFTimeInterval = 0) {
        guard let pipelineState else {
            renderSkipReason["no_pipeline", default: 0] += 1
            return
        }
        guard let textureCache else {
            renderSkipReason["no_cache", default: 0] += 1
            return
        }
        guard let drawable = metalLayer.nextDrawable() else {
            renderSkipReason["no_drawable", default: 0] += 1
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Update drawable size to match content. The layer's bounds are driven
        // by AutoLayout via MetalVideoRendererView; drawableSize controls the
        // backing texture resolution.
        let scaledSize = view.scaledDrawableSize(forContentWidth: width, height: height)
        if metalLayer.drawableSize != scaledSize {
            metalLayer.drawableSize = scaledSize
        }

        // Wrap the CVPixelBuffer planes as MTLTextures via the cache.
        let yTextureFormat: MTLPixelFormat = pixelBufferIs10Bit(pixelBuffer) ? .r16Unorm : .r8Unorm
        let cbcrTextureFormat: MTLPixelFormat = pixelBufferIs10Bit(pixelBuffer) ? .rg16Unorm : .rg8Unorm

        guard let yTexture = makePlaneTexture(
                pixelBuffer: pixelBuffer, plane: 0,
                format: yTextureFormat, textureCache: textureCache) else {
            renderSkipReason["no_y_texture", default: 0] += 1
            return
        }
        guard let cbcrTexture = makePlaneTexture(
                pixelBuffer: pixelBuffer, plane: 1,
                format: cbcrTextureFormat, textureCache: textureCache) else {
            renderSkipReason["no_cbcr_texture", default: 0] += 1
            return
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(cbcrTexture, index: 1)

        // Pass a uniform telling the shader which color matrix to use.
        var matrixSelector: UInt32 = pixelBufferIs10Bit(pixelBuffer) ? 1 : 0  // 1 = BT.2020, 0 = BT.709
        encoder.setFragmentBytes(&matrixSelector, length: MemoryLayout<UInt32>.size, index: 0)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        if atHostTime > 0 {
            commandBuffer.present(drawable, atTime: atHostTime)
        } else {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    private func renderBlack() {
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = drawable.texture
        pd.colorAttachments[0].loadAction = .clear
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pd.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pd) {
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Pipeline State

    private func buildRenderPipelineIfNeeded() {
        guard pipelineState == nil else { return }
        do {
            let library = try device.makeLibrary(source: Self.metalShaderSource, options: nil)
            guard let vertexFunc = library.makeFunction(name: "rivuletFullscreenVertex"),
                  let fragmentFunc = library.makeFunction(name: "rivuletYCbCrFragment") else {
                playerDebugLog("[MetalRenderer] makeFunction failed")
                return
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            playerDebugLog("[MetalRenderer] pipeline build failed: \(error.localizedDescription)")
            self.error = error
            status = .failed
        }
    }

    // MARK: - Helpers

    private func makePlaneTexture(
        pixelBuffer: CVPixelBuffer,
        plane: Int,
        format: MTLPixelFormat,
        textureCache: CVMetalTextureCache
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            plane,
            &cvTexture
        )
        guard result == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func pixelBufferIs10Bit(_ buffer: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        return format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    private nonisolated func fourCCNonisolated(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func fourCCString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// Extract VPS/SPS/PPS NALUs from a sample's in-band NALU stream and build
    /// a corrected CMFormatDescription via `CMVideoFormatDescriptionCreateFromHEVCParameterSets`.
    /// Then retry VTDecompressionSessionCreate with the rebuilt FD. Used when
    /// the demuxer's hvcC carries no parameter sets (numArrays=0) — typical of
    /// `hev1`-muxed content that's been tagged `hvc1`. AVSampleBufferDisplayLayer
    /// tolerates this; standalone VT does not.
    private func buildSessionFromSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        originalFormatDescription: CMFormatDescription
    ) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength >= 5 else { return }
        var dataPointer: UnsafeMutablePointer<Int8>?
        let getStatus = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: nil, dataPointerOut: &dataPointer
        )
        guard getStatus == noErr, let dataPointer else { return }
        let data = Data(bytes: dataPointer, count: totalLength)

        let extracted = Self.extractParameterSetsFromNALUs(data, lengthSize: 4)
        guard let vps = extracted.vps, let sps = extracted.sps, let pps = extracted.pps else {
            // Not a keyframe; will succeed on the next IDR.
            return
        }
        playerDebugLog(
            "[MetalRenderer] extracted in-band parameter sets: " +
            "VPS=\(vps.count)B SPS=\(sps.count)B PPS=\(pps.count)B"
        )

        // Build the new FD.
        let paramSets = [vps, sps, pps]
        var flatBuffer = [UInt8]()
        var offsets: [(offset: Int, length: Int)] = []
        for set in paramSets {
            offsets.append((flatBuffer.count, set.count))
            flatBuffer.append(contentsOf: set)
        }
        var rebuiltFD: CMFormatDescription?
        let rebuildStatus: OSStatus = flatBuffer.withUnsafeBufferPointer { flatBuf in
            guard let base = flatBuf.baseAddress else { return -1 }
            var pointers: [UnsafePointer<UInt8>] = offsets.map { base + $0.offset }
            var sizes: [Int] = offsets.map { $0.length }
            return pointers.withUnsafeMutableBufferPointer { ptrBuf in
                sizes.withUnsafeMutableBufferPointer { sizesBuf in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: paramSets.count,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: sizesBuf.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &rebuiltFD
                    )
                }
            }
        }
        guard rebuildStatus == noErr, let rebuiltFD else {
            playerDebugLog("[MetalRenderer] rebuild FD from in-band params failed: \(rebuildStatus)")
            return
        }

        // Create the VT session using the rebuilt FD.
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (
                decompressionOutputRefCon, _, status, _, imageBuffer, presentationTimeStamp, _
            ) in
                guard let decompressionOutputRefCon else { return }
                let renderer = Unmanaged<MetalVideoRenderer>
                    .fromOpaque(decompressionOutputRefCon)
                    .takeUnretainedValue()
                renderer.handleDecodedFrame(
                    status: status, imageBuffer: imageBuffer, pts: presentationTimeStamp
                )
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        // Request kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ('x420').
        // Without this, VT defaults to 'p420' (Apple's compact 10-bit, 4 bytes
        // per 3 pixels) which Metal can't sample via the standard r16Unorm /
        // rg16Unorm planes. 'x420' stores each 10-bit value in the upper 10
        // bits of a 16-bit word, sample-friendly.
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!,
        ]
        var session: VTDecompressionSession?
        var createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: rebuiltFD,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )
        if createStatus != noErr {
            playerDebugLog("[MetalRenderer] VT create with x420 hint failed: \(createStatus); retrying Metal-only")
            let fallback: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue!]
            createStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: rebuiltFD,
                decoderSpecification: nil,
                imageBufferAttributes: fallback as CFDictionary,
                outputCallback: &callbackRecord,
                decompressionSessionOut: &session
            )
        }
        guard createStatus == noErr, let session else {
            playerDebugLog("[MetalRenderer] VT session create from rebuilt FD failed: \(createStatus)")
            return
        }
        VTSessionSetProperty(session,
                             key: kVTDecompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        self.decompressionSession = session
        self.rebuiltFormatDescription = rebuiltFD
        self.awaitingSampleBasedFD = false
        playerDebugLog("[MetalRenderer] VT session created from rebuilt FD (in-band parameter sets)")
    }

    /// Build a new CMSampleBuffer that shares the original's data buffer +
    /// timing + sync attachments but carries a different CMFormatDescription.
    /// Apple doesn't provide a public CMSampleBufferCreateCopyWithNewFormatDescription
    /// API, so we assemble it via CMSampleBufferCreateReady — same pattern
    /// FFmpegDemuxer.createSampleBuffer uses.
    private static func restampSampleBuffer(
        _ original: CMSampleBuffer, with newFD: CMFormatDescription
    ) -> CMSampleBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(original) else { return nil }
        var timingInfo = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(
            original, at: 0, timingInfoOut: &timingInfo
        )
        guard timingStatus == noErr else { return nil }
        var sampleSize = CMSampleBufferGetTotalSampleSize(original)
        var newBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: newFD,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &newBuffer
        )
        guard createStatus == noErr, let newBuffer else { return nil }

        // Propagate sync / NotSync attachment so VT B-frame handling works.
        if let originalAttachments = CMSampleBufferGetSampleAttachmentsArray(
                original, createIfNecessary: false),
           CFArrayGetCount(originalAttachments) > 0,
           let newAttachments = CMSampleBufferGetSampleAttachmentsArray(
                newBuffer, createIfNecessary: true),
           CFArrayGetCount(newAttachments) > 0 {
            let originalDict = unsafeBitCast(
                CFArrayGetValueAtIndex(originalAttachments, 0), to: CFDictionary.self)
            let newDict = unsafeBitCast(
                CFArrayGetValueAtIndex(newAttachments, 0), to: CFMutableDictionary.self)
            let notSyncKey = unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self)
            if let raw = CFDictionaryGetValue(originalDict, notSyncKey) {
                CFDictionarySetValue(newDict, notSyncKey, raw)
            }
        }
        return newBuffer
    }

    /// Scan a length-prefixed NALU stream and return any VPS/SPS/PPS NALUs found.
    private static func extractParameterSetsFromNALUs(
        _ data: Data, lengthSize: Int
    ) -> (vps: Data?, sps: Data?, pps: Data?) {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        var offset = 0
        while offset + lengthSize + 2 <= data.count {
            let length: Int
            if lengthSize == 4 {
                length = (Int(data[offset]) << 24)
                       | (Int(data[offset + 1]) << 16)
                       | (Int(data[offset + 2]) << 8)
                       | Int(data[offset + 3])
            } else if lengthSize == 2 {
                length = (Int(data[offset]) << 8) | Int(data[offset + 1])
            } else {
                return (vps, sps, pps)
            }
            if length <= 0 || offset + lengthSize + length > data.count {
                return (vps, sps, pps)
            }
            let nalStart = offset + lengthSize
            let naluType = (data[nalStart] >> 1) & 0x3F  // HEVC NAL header: first byte high 6 bits
            let nalu = data.subdata(in: nalStart..<(nalStart + length))
            switch naluType {
            case 32: vps = nalu     // VPS_NUT
            case 33: sps = nalu     // SPS_NUT
            case 34: pps = nalu     // PPS_NUT
            default: break
            }
            if vps != nil && sps != nil && pps != nil { return (vps, sps, pps) }
            offset = nalStart + length
        }
        return (vps, sps, pps)
    }

    /// Rebuild an HEVC CMFormatDescription via `CMVideoFormatDescriptionCreateFromHEVCParameterSets`
    /// from the parameter sets carried in its hvcC extension atom. This is the
    /// canonical Apple-blessed FD shape and is what VTDecompressionSessionCreate
    /// expects. FFmpegDemuxer's `CMVideoFormatDescriptionCreate(extensions:)` form
    /// produces an FD that AVSampleBufferDisplayLayer accepts but that VT rejects
    /// with status -4 (unimpErr). The DV conversion path in FFmpegDemuxer uses
    /// the same approach for the same reason.
    private static func canonicaliseHEVCFormatDescription(_ formatDescription: CMFormatDescription) -> CMFormatDescription? {
        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        guard subType == kCMVideoCodecType_HEVC else {
            playerDebugLog("[MetalRenderer] canonicalise: not HEVC (subType=\(subType))")
            return nil
        }
        guard let ext = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] else {
            playerDebugLog("[MetalRenderer] canonicalise: no extensions")
            return nil
        }
        guard let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [CFString: Any] else {
            playerDebugLog("[MetalRenderer] canonicalise: no SampleDescriptionExtensionAtoms (keys=\(ext.keys.map { $0 as String }))")
            return nil
        }
        guard let hvcCData = atoms["hvcC" as CFString] as? Data else {
            playerDebugLog("[MetalRenderer] canonicalise: no hvcC in atoms (keys=\(atoms.keys.map { $0 as String }))")
            return nil
        }
        let paramSets = HEVCNALParser.extractParameterSets(from: hvcCData)
        guard paramSets.count >= 3 else {
            let preview = hvcCData.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            let numArraysByte: String = hvcCData.count > 22 ? String(format: "%02x", hvcCData[22]) : "?"
            playerDebugLog(
                "[MetalRenderer] canonicalise: only \(paramSets.count) parameter sets in hvcC " +
                "(size=\(hvcCData.count) byte22(numArrays)=\(numArraysByte) head=\(preview))"
            )
            return nil
        }
        playerDebugLog("[MetalRenderer] canonicalise: extracted \(paramSets.count) parameter sets from hvcC")

        // Build pointers + sizes for the C API.
        var flatBuffer = [UInt8]()
        var offsets: [(offset: Int, length: Int)] = []
        for set in paramSets {
            let start = flatBuffer.count
            flatBuffer.append(contentsOf: set)
            offsets.append((start, set.count))
        }

        var rebuilt: CMFormatDescription?
        let rebuildStatus: OSStatus = flatBuffer.withUnsafeBufferPointer { flatBuf in
            guard let base = flatBuf.baseAddress else { return -1 }
            var pointers: [UnsafePointer<UInt8>] = offsets.map { base + $0.offset }
            var sizes: [Int] = offsets.map { $0.length }
            return pointers.withUnsafeMutableBufferPointer { ptrBuf in
                sizes.withUnsafeMutableBufferPointer { sizesBuf in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: paramSets.count,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: sizesBuf.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &rebuilt
                    )
                }
            }
        }
        guard rebuildStatus == noErr, let rebuilt else {
            playerDebugLog("[MetalRenderer] canonicaliseHEVCFormatDescription: rebuild status=\(rebuildStatus)")
            return nil
        }
        return rebuilt
    }

    // MARK: - Metal Shader (inline MSL)

    /// Full-screen triangle vertex shader + YCbCr->RGB fragment shader.
    /// The fragment shader applies BT.709 (SDR) or BT.2020 (HDR) limited-range
    /// matrix conversion to produce RGB. HDR transfer (HLG/PQ) is left as the
    /// CVPixelBuffer's tagged transfer function so the system's tone-map mode
    /// (CALayer.toneMapMode = .ifSupported on tvOS 18+) can convert it for the
    /// display. We do NOT apply OETF inversion in shader.
    private static let metalShaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct FullscreenVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Three-vertex fullscreen triangle. No vertex buffer needed.
    vertex FullscreenVertexOut rivuletFullscreenVertex(uint vid [[vertex_id]]) {
        // UVs for a triangle that covers the [-1,1] clip space when its three
        // vertices are placed at (-1,-1), (3,-1), (-1,3).
        const float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        FullscreenVertexOut out;
        float2 p = positions[vid];
        out.position = float4(p, 0.0, 1.0);
        // UV in [0,1] across the visible portion; the triangle's parts that
        // overlap clip space get sampled.
        out.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);
        return out;
    }

    fragment float4 rivuletYCbCrFragment(
        FullscreenVertexOut in [[stage_in]],
        texture2d<float, access::sample> yPlane    [[texture(0)]],
        texture2d<float, access::sample> cbcrPlane [[texture(1)]],
        constant uint &matrixSelector              [[buffer(0)]]
    ) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y  = yPlane.sample(s, in.uv).r;
        float2 cbcr = cbcrPlane.sample(s, in.uv).rg;

        // Limited-range to full-range expansion (10-bit values are exposed in
        // [0,1] by Metal's r16Unorm/rg16Unorm sampling; coefficients work for
        // both 8-bit and 10-bit limited-range because the unorm normalization
        // already scales both the same way).
        float y_expanded = (y  - 16.0/255.0) * (255.0/(235.0-16.0));
        float cb        = (cbcr.r - 128.0/255.0) * (255.0/(240.0-16.0));
        float cr        = (cbcr.g - 128.0/255.0) * (255.0/(240.0-16.0));

        float3 rgb;
        if (matrixSelector == 1u) {
            // BT.2020 non-constant-luminance
            rgb.r = y_expanded + 1.4747 * cr;
            rgb.g = y_expanded - 0.1645 * cb - 0.5713 * cr;
            rgb.b = y_expanded + 1.8814 * cb;
        } else {
            // BT.709
            rgb.r = y_expanded + 1.5748 * cr;
            rgb.g = y_expanded - 0.1873 * cb - 0.4681 * cr;
            rgb.b = y_expanded + 1.8556 * cb;
        }
        return float4(saturate(rgb), 1.0);
    }
    """
}

// MARK: - Display Link Trampoline

/// CADisplayLink's selector target API requires NSObject. We can't use the
/// `@MainActor` MetalVideoRenderer directly because the selector handoff has
/// no isolation context. Trampoline holds a weak ref and hops to MainActor.
private final class DisplayLinkTrampoline: NSObject {
    weak var owner: MetalVideoRenderer?

    init(owner: MetalVideoRenderer) {
        self.owner = owner
        super.init()
    }

    @objc func tick() {
        // CADisplayLink fires on the main runloop, so MainActor is already
        // effectively held — but make it explicit for the type system.
        MainActor.assumeIsolated {
            owner?.displayLinkTick()
        }
    }
}

// MARK: - UIView Host

/// UIView that hosts the `CAMetalLayer` for `MetalVideoRenderer`.
final class MetalVideoRendererView: UIView {
    private let metalLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
    }

    /// Aspect-fit the content into the view bounds; return the drawable size
    /// in pixels.
    func scaledDrawableSize(forContentWidth contentWidth: Int, height contentHeight: Int) -> CGSize {
        let viewSizePoints = bounds.size
        guard contentWidth > 0, contentHeight > 0,
              viewSizePoints.width > 0, viewSizePoints.height > 0 else {
            return CGSize(width: max(1, contentWidth), height: max(1, contentHeight))
        }
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let viewSizePx = CGSize(
            width: viewSizePoints.width * scale,
            height: viewSizePoints.height * scale
        )
        let contentAspect = CGFloat(contentWidth) / CGFloat(contentHeight)
        let viewAspect = viewSizePx.width / viewSizePx.height
        if contentAspect > viewAspect {
            // Letterbox: width-bound.
            return CGSize(width: viewSizePx.width,
                          height: floor(viewSizePx.width / contentAspect))
        } else {
            // Pillarbox: height-bound.
            return CGSize(width: floor(viewSizePx.height * contentAspect),
                          height: viewSizePx.height)
        }
    }
}
