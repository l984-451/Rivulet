//
//  FFmpegAudioDecoder.swift
//  Rivulet
//
//  Client-side audio decoder for codecs not natively supported by Apple TV
//  (TrueHD, DTS, DTS-HD MA). Uses libavcodec to decode compressed audio to
//  interleaved PCM, then wraps in CMSampleBuffers for AVSampleBufferAudioRenderer.
//
//  This enables true direct play for ALL content — zero Plex server involvement —
//  by decoding unsupported audio locally instead of forcing HLS transcode.
//

import Foundation
import AVFoundation
import CoreMedia
import Sentry

// MARK: - Decoded Audio Frame

/// PCM audio data decoded from a compressed packet, ready for CMSampleBuffer creation.
struct DecodedAudioFrame: Sendable {
    let data: Data              // Interleaved PCM samples
    let sampleCount: Int        // Number of audio frames (e.g., 4096)
    let sampleRate: Int         // e.g., 48000
    let channels: Int           // e.g., 8 for 7.1
    let bitsPerSample: Int      // 16, 24, or 32
    let pts: CMTime             // Presentation timestamp
}

// =============================================================================
// MARK: - FFmpeg Implementation (when libraries are available)
// =============================================================================

#if RIVULET_FFMPEG
import Libavcodec
import Libavutil
import Libswresample

/// Decodes TrueHD/DTS audio to interleaved PCM using libavcodec + libswresample.
final class FFmpegAudioDecoder: @unchecked Sendable {

    /// Audio codecs this decoder handles.
    /// Includes both non-native codecs (DTS, TrueHD) and native codecs (AAC, AC3, etc.)
    /// because compressed passthrough via AVSampleBufferAudioRenderer is silent on AirPlay —
    /// all audio must be decoded to PCM for AirPlay output.
    /// Uses prefix matching — "pcm" matches pcm_s24le, pcm_s16le, etc.
    static let supportedCodecs: Set<String> = [
        "truehd", "mlp",                   // Dolby TrueHD / MLP
        "dts", "dca",                       // DTS Core
        "dts-hd", "dtshd", "dts-hd ma",    // DTS-HD (MA and HRA)
        "pcm",                              // Raw PCM variants (pcm_s24le, pcm_s16le, etc.)
        "flac",                             // FLAC lossless
        "aac",                              // AAC (silent on AirPlay via passthrough)
        "ac3",                              // Dolby Digital
        "eac3", "ec3",                      // Dolby Digital Plus
        "mp3",                              // MP3
        "mp2",                              // MP2
        "alac",                             // Apple Lossless
    ]

    /// Whether FFmpeg audio decoding is available
    static let isAvailable = true

    // MARK: - Configuration

    /// When true, output signed 16-bit integer PCM instead of 32-bit float.
    /// AirPlay 2 natively supports S16/S24/F24 but NOT float32. Using S16
    /// avoids a system-side format conversion that can introduce crackling.
    var useSignedInt16Output = false

    /// When true, downmix multichannel audio to stereo output.
    /// Used for basic AirPlay speakers that only support 2-channel audio.
    var forceDownmixToStereo = false

    /// Target output sample rate. When set to a non-zero value, swresample
    /// resamples audio to this rate. Critical for AirPlay where the hardware
    /// runs at 44100Hz but source audio is typically 48000Hz — sending
    /// mismatched rates to AVSampleBufferAudioRenderer causes crackling.
    var targetOutputSampleRate: Int = 0

    // MARK: - Private State

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swrContext: OpaquePointer?
    private var decodedFrame: UnsafeMutablePointer<AVFrame>?
    private var isOpen = false

    // Output format info (tracks current swresample config)
    private var outputSampleRate: Int = 0
    private var outputChannels: Int = 0
    private var outputBitsPerSample: Int = 0
    /// CoreAudio channel layout tag derived from FFmpeg's channel layout.
    private var outputChannelLayoutTag: AudioChannelLayoutTag = kAudioChannelLayoutTag_Unknown
    /// Cached format description — created once, reused for all CMSampleBuffers.
    /// Recreating it per buffer can cause renderer state resets.
    private var cachedFormatDescription: CMAudioFormatDescription?
    private var cachedFDChannels: Int = 0
    private var cachedFDSampleRate: Int = 0
    private var cachedFDIsS16: Bool = false
    private var sampleBufferCount = 0

    // Batching state: accumulates tiny decoded frames (e.g., TrueHD's 40-sample frames)
    // into larger chunks to reduce CMSampleBuffer creation and enqueue overhead.
    private var batchData = Data()
    private var batchSampleCount = 0
    private var batchPTS: CMTime = .invalid
    private var batchSampleRate: Int = 0
    private var batchChannels: Int = 0
    private var batchBitsPerSample: Int = 0
    private var hasLoggedBatchConfig = false
    private var emittedBatchCount = 0
    private var lastDecodedPTS: CMTime = .invalid
    private var invalidTimestampCount = 0
    private var nonMonotonicTimestampCount = 0

    /// Continuous output PTS tracker — eliminates micro-gaps caused by resampling.
    /// When resampling (e.g., 48kHz→44.1kHz), the output sample count doesn't exactly
    /// match the source PTS spacing, creating tiny silence gaps that cause crackling.
    /// By tracking a running PTS based on actual output samples, each buffer starts
    /// exactly where the previous one ended.
    private var continuousOutputPTS: CMTime = .invalid
    private var continuousOutputTimescale: Int32 = 44100

    /// Minimum samples to accumulate before emitting a batch.
    /// Default is ~20ms for local/native routes; AirPlay-shaped PCM output uses
    /// larger batches to reduce CMSampleBuffer churn and pull-callback frequency.
    private let baseMinBatchSamples = 960

    // MARK: - Init

    /// Open a decoder for the given codec parameters.
    /// - Parameters:
    ///   - codecpar: Codec parameters from the demuxer stream
    ///   - codecNameHint: Demuxer-reported codec name (e.g., "truehd"). Used to find the
    ///     correct decoder by name, since TrueHD streams report AV_CODEC_ID_AC3 at the
    ///     codecpar level (TrueHD embeds an AC3 core for compatibility).
    init(codecpar: UnsafePointer<AVCodecParameters>, codecNameHint: String? = nil) throws {
        let codecId = codecpar.pointee.codec_id

        // Prefer name-based lookup when a hint is provided.
        // This is critical for TrueHD: the demuxer knows it's TrueHD from the container
        // metadata, but codecpar.codec_id reports AC3 (the embedded compatibility core).
        let codec: UnsafePointer<AVCodec>?
        let lookupMethod: String

        if let hint = codecNameHint {
            // Map common Plex/container names to FFmpeg decoder names
            let ffmpegName: String
            switch hint.lowercased() {
            case "truehd", "mlp":
                ffmpegName = "truehd"
            case "dts", "dca", "dts-hd", "dtshd", "dts-hd ma":
                ffmpegName = "dca"
            default:
                ffmpegName = hint.lowercased()
            }

            if let byName = avcodec_find_decoder_by_name(ffmpegName) {
                codec = byName
                lookupMethod = "by-name(\(ffmpegName))"
            } else {
                // Fall back to ID-based if name lookup fails
                codec = avcodec_find_decoder(codecId)
                lookupMethod = "by-id(name \(ffmpegName) not found)"
            }
        } else {
            codec = avcodec_find_decoder(codecId)
            lookupMethod = "by-id"
        }

        guard let codec else {
            let name = String(cString: avcodec_get_name(codecId))
            playerDebugLog("[AudioDecoder] No decoder found for codec: \(name)")
            throw FFmpegError.unsupportedCodec(name)
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw FFmpegError.allocationFailed
        }

        var mutableCtx: UnsafeMutablePointer<AVCodecContext>? = ctx

        var ret = avcodec_parameters_to_context(ctx, codecpar)
        guard ret >= 0 else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.openFailed(averror: ret)
        }

        // Log if there's a codec_id mismatch (indicates wrong stream was selected)
        if ctx.pointee.codec_id != codec.pointee.id {
            playerDebugLog("[AudioDecoder] ⚠️ codec_id mismatch: context=\(ctx.pointee.codec_id.rawValue) " +
                  "decoder=\(codec.pointee.id.rawValue) — ensure correct stream is selected")
        }

        ret = avcodec_open2(ctx, codec, nil)
        guard ret >= 0 else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.openFailed(averror: ret)
        }

        guard let frame = av_frame_alloc() else {
            avcodec_free_context(&mutableCtx)
            throw FFmpegError.allocationFailed
        }

        self.codecContext = ctx
        self.decodedFrame = frame
        self.isOpen = true

        let decoderName = String(cString: codec.pointee.name)
        let channels = codecpar.pointee.ch_layout.nb_channels
        let sampleRate = codecpar.pointee.sample_rate
        playerDebugLog("[AudioDecoder] Opened \(decoderName) decoder: \(channels)ch \(sampleRate)Hz (\(lookupMethod))")
    }

    deinit { close() }

    // MARK: - Decode

    /// Decode a compressed audio packet into PCM frames.
    /// One packet may produce zero or more output frames.
    func decode(_ packet: DemuxedPacket) -> [DecodedAudioFrame] {
        guard let ctx = codecContext, let frame = decodedFrame, isOpen else { return [] }

        var avPacket = av_packet_alloc()
        guard let pkt = avPacket else { return [] }
        defer { av_packet_free(&avPacket) }

        // Fill AVPacket from DemuxedPacket data
        packet.data.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            av_new_packet(pkt, Int32(packet.data.count))
            pkt.pointee.data.update(from: baseAddress.assumingMemoryBound(to: UInt8.self),
                                     count: packet.data.count)
            pkt.pointee.pts = packet.pts
            pkt.pointee.dts = packet.dts
            pkt.pointee.duration = packet.duration
        }

        var ret = avcodec_send_packet(ctx, pkt)
        guard ret >= 0 || ret == kAudioDecoderEAGAIN else {
            playerDebugLog("[AudioDecoder] send_packet error: \(ret)")
            return []
        }

        var frames: [DecodedAudioFrame] = []

        while true {
            av_frame_unref(frame)
            ret = avcodec_receive_frame(ctx, frame)

            if ret == kAudioDecoderEAGAIN || ret == kAudioDecoderEOF {
                break
            }
            guard ret >= 0 else {
                playerDebugLog("[AudioDecoder] receive_frame error: \(ret)")
                break
            }

            if let decoded = convertToInterleaved(
                frame: frame,
                packetTimebase: packet.timebase,
                packetPTS: packet.cmPTS.isValid ? packet.cmPTS : packet.cmDTS,
                packetDuration: packet.cmDuration
            ) {
                frames.append(decoded)
            }
        }

        return frames
    }

    // MARK: - Batched Decode

    /// Decode a packet and accumulate the PCM output into batches.
    /// Returns completed batches (≥960 samples each ≈ 20ms at 48kHz).
    /// TrueHD produces ~40 samples per packet (0.83ms), so batching reduces
    /// the CMSampleBuffer creation rate from ~1200/sec to ~50/sec.
    func decodeAndBatch(_ packet: DemuxedPacket) -> [DecodedAudioFrame] {
        let frames = decode(packet)
        var output: [DecodedAudioFrame] = []

        for frame in frames {
            let minBatchSamples = minimumBatchSamples(for: frame.sampleRate)
            maybeLogBatchConfig(sampleRate: frame.sampleRate, minBatchSamples: minBatchSamples)

            // Start new batch if empty
            if batchSampleCount == 0 {
                batchPTS = frame.pts
                batchSampleRate = frame.sampleRate
                batchChannels = frame.channels
                batchBitsPerSample = frame.bitsPerSample
            }

            batchData.append(frame.data)
            batchSampleCount += frame.sampleCount

            if batchSampleCount >= minBatchSamples {
                output.append(DecodedAudioFrame(
                    data: batchData,
                    sampleCount: batchSampleCount,
                    sampleRate: batchSampleRate,
                    channels: batchChannels,
                    bitsPerSample: batchBitsPerSample,
                    pts: batchPTS
                ))
                emittedBatchCount += 1
                if emittedBatchCount <= 4 {
                    let batchDurationMs = (Double(batchSampleCount) / Double(max(batchSampleRate, 1))) * 1000
                    playerDebugLog(
                        "[AudioDecoder] Emitting PCM batch #\(emittedBatchCount): " +
                        "samples=\(batchSampleCount) rate=\(batchSampleRate)Hz " +
                        "duration=\(String(format: "%.1f", batchDurationMs))ms ch=\(batchChannels)"
                    )
                }
                batchData = Data()
                batchSampleCount = 0
                batchPTS = .invalid
            }
        }

        return output
    }

    /// Flush any remaining accumulated samples (call on seek/stop/EOS).
    func flushBatch() -> DecodedAudioFrame? {
        guard batchSampleCount > 0 else { return nil }
        let frame = DecodedAudioFrame(
            data: batchData,
            sampleCount: batchSampleCount,
            sampleRate: batchSampleRate,
            channels: batchChannels,
            bitsPerSample: batchBitsPerSample,
            pts: batchPTS
        )
        batchData = Data()
        batchSampleCount = 0
        batchPTS = .invalid
        return frame
    }

    /// Reset decoder-side timestamp tracking after timeline discontinuities (seek/recover).
    func resetTimestampTracking(reason: String) {
        lastDecodedPTS = .invalid
        continuousOutputPTS = .invalid
        invalidTimestampCount = 0
        nonMonotonicTimestampCount = 0
        hasLoggedBatchConfig = false
        emittedBatchCount = 0
        playerDebugLog("[AudioDecoder] Timestamp tracking reset (\(reason))")
    }

    // MARK: - CMSampleBuffer Creation

    /// Create a CMSampleBuffer containing LPCM audio data from a decoded frame.
    func createPCMSampleBuffer(from frame: DecodedAudioFrame) throws -> CMSampleBuffer {
        let bytesPerSample = frame.bitsPerSample / 8
        let bytesPerFrame = bytesPerSample * frame.channels

        // Cache format description — recreating per-buffer can cause renderer resets.
        let fd = try getOrCreateFormatDescription(
            sampleRate: frame.sampleRate, channels: frame.channels,
            bitsPerSample: frame.bitsPerSample, bytesPerFrame: bytesPerFrame
        )

        // Validate PCM data on first buffer
        sampleBufferCount += 1
        if sampleBufferCount <= 1 {
            let expectedSize = frame.sampleCount * frame.channels * bytesPerSample
            frame.data.withUnsafeBytes { rawBuf in
                if useSignedInt16Output {
                    let samples = rawBuf.bindMemory(to: Int16.self)
                    var minVal: Int16 = .max
                    var maxVal: Int16 = .min
                    for i in 0..<min(samples.count, frame.sampleCount * frame.channels) {
                        minVal = min(minVal, samples[i])
                        maxVal = max(maxVal, samples[i])
                    }
                    let first4 = (0..<min(4, samples.count)).map { "\(samples[$0])" }.joined(separator: ", ")
                    playerDebugLog("[AudioDecoder] PCM validate #\(sampleBufferCount): " +
                          "samples=\(frame.sampleCount) ch=\(frame.channels) fmt=s16 " +
                          "dataSize=\(frame.data.count) expected=\(expectedSize) " +
                          "range=[\(minVal),\(maxVal)] first4=[\(first4)]")
                } else {
                    let floats = rawBuf.bindMemory(to: Float.self)
                    var minVal: Float = .infinity
                    var maxVal: Float = -.infinity
                    var nanCount = 0
                    var infCount = 0
                    for i in 0..<min(floats.count, frame.sampleCount * frame.channels) {
                        let v = floats[i]
                        if v.isNaN { nanCount += 1 }
                        else if v.isInfinite { infCount += 1 }
                        else {
                            minVal = min(minVal, v)
                            maxVal = max(maxVal, v)
                        }
                    }
                    let first4 = (0..<min(4, floats.count)).map { String(format: "%.6f", floats[$0]) }.joined(separator: ", ")
                    playerDebugLog("[AudioDecoder] PCM validate #\(sampleBufferCount): " +
                          "samples=\(frame.sampleCount) ch=\(frame.channels) fmt=f32 " +
                          "dataSize=\(frame.data.count) expected=\(expectedSize) " +
                          "range=[\(String(format: "%.4f", minVal)),\(String(format: "%.4f", maxVal))] " +
                          "nan=\(nanCount) inf=\(infCount) first4=[\(first4)]")
                }
            }
        }

        var blockBuffer: CMBlockBuffer?
        let dataCount = frame.data.count

        var status = frame.data.withUnsafeBytes { rawBuf -> OSStatus in
            guard let baseAddress = rawBuf.baseAddress else { return -1 }
            var buffer: CMBlockBuffer?
            let s1 = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: dataCount, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: dataCount,
                flags: 0, blockBufferOut: &buffer
            )
            guard s1 == noErr, let buf = buffer else { return s1 }
            let s2 = CMBlockBufferReplaceDataBytes(
                with: baseAddress, blockBuffer: buf,
                offsetIntoDestination: 0, dataLength: dataCount
            )
            blockBuffer = buf
            return s2
        }

        guard status == noErr, let block = blockBuffer else {
            throw FFmpegError.sampleBufferCreationFailed(status: status)
        }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: fd,
            sampleCount: frame.sampleCount,
            presentationTimeStamp: frame.pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let buffer = sampleBuffer else {
            throw FFmpegError.sampleBufferCreationFailed(status: status)
        }

        return buffer
    }

    // MARK: - Close

    func close() {
        guard isOpen else { return }
        isOpen = false
        resetTimestampTracking(reason: "close")

        if swrContext != nil {
            swr_free(&swrContext)
            swrContext = nil
        }

        if decodedFrame != nil {
            av_frame_free(&decodedFrame)
            decodedFrame = nil
        }

        if codecContext != nil {
            avcodec_free_context(&codecContext)
            codecContext = nil
        }

        playerDebugLog("[AudioDecoder] Closed")
    }

    // MARK: - Private: Format Description Cache

    /// Get or create a cached CMAudioFormatDescription.
    /// Recreating it per buffer may cause renderer glitches.
    private func getOrCreateFormatDescription(
        sampleRate: Int, channels: Int, bitsPerSample: Int, bytesPerFrame: Int
    ) throws -> CMAudioFormatDescription {
        if let cached = cachedFormatDescription,
           cachedFDChannels == channels,
           cachedFDSampleRate == sampleRate,
           cachedFDIsS16 == useSignedInt16Output {
            return cached
        }

        let formatFlags: AudioFormatFlags
        if useSignedInt16Output {
            formatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        } else {
            formatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bitsPerSample),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let status: OSStatus
        let hasLayout = outputChannelLayoutTag != kAudioChannelLayoutTag_Unknown

        if hasLayout {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = outputChannelLayoutTag
            layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
            layout.mNumberChannelDescriptions = 0
            let layoutSize = MemoryLayout<AudioChannelLayout>.size
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: layoutSize,
                layout: &layout,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }

        guard status == noErr, let fd = formatDescription else {
            throw FFmpegError.formatDescriptionFailed(status: status)
        }

        cachedFormatDescription = fd
        cachedFDChannels = channels
        cachedFDSampleRate = sampleRate
        cachedFDIsS16 = useSignedInt16Output

        let formatName = useSignedInt16Output ? "s16" : "float32"
        playerDebugLog("[AudioDecoder] Created format description: \(channels)ch \(sampleRate)Hz " +
              "\(formatName) layout=\(outputChannelLayoutTag) flags=\(asbd.mFormatFlags)")

        return fd
    }

    // MARK: - Private: Planar → Interleaved Conversion

    /// Convert a decoded AVFrame to interleaved PCM using libswresample.
    private func convertToInterleaved(frame: UnsafeMutablePointer<AVFrame>,
                                      packetTimebase: CMTime,
                                      packetPTS: CMTime,
                                      packetDuration: CMTime) -> DecodedAudioFrame? {
        let sampleFormat = AVSampleFormat(rawValue: frame.pointee.format)
        let inputChannels = frame.pointee.ch_layout.nb_channels
        let sampleRate = frame.pointee.sample_rate
        let nbSamples = frame.pointee.nb_samples

        guard inputChannels > 0, sampleRate > 0, nbSamples > 0 else { return nil }

        // Output format: float32 by default, S16 for AirPlay compatibility.
        // AirPlay 2 natively supports S16/S24/F24 but NOT float32.
        let outputFormat: AVSampleFormat
        let bitsPerSample: Int
        if useSignedInt16Output {
            outputFormat = AV_SAMPLE_FMT_S16
            bitsPerSample = 16
        } else {
            outputFormat = AV_SAMPLE_FMT_FLT
            bitsPerSample = 32
        }

        let needsDownmix = forceDownmixToStereo && inputChannels > 2
        let outChannels = needsDownmix ? Int32(2) : inputChannels
        let needsResample = targetOutputSampleRate > 0 && targetOutputSampleRate != Int(sampleRate)
        let effectiveOutputRate = needsResample ? Int32(targetOutputSampleRate) : sampleRate

        let bytesPerSample = bitsPerSample / 8

        // Fast path: already interleaved in the target format, no downmix, no resample
        if !needsDownmix && !needsResample && sampleFormat == outputFormat, let data = frame.pointee.data.0 {
            if outputChannelLayoutTag == kAudioChannelLayoutTag_Unknown {
                outputChannelLayoutTag = Self.channelLayoutTag(for: Int(inputChannels))
            }
            let outputBufferSize = Int(nbSamples) * Int(outChannels) * bytesPerSample
            let pcmData = Data(bytes: data, count: outputBufferSize)
            return buildDecodedFrame(
                data: pcmData, sampleCount: Int(nbSamples),
                sampleRate: Int(sampleRate), channels: Int(outChannels),
                bitsPerSample: bitsPerSample, framePTS: frame.pointee.pts,
                packetTimebase: packetTimebase,
                packetPTS: packetPTS,
                packetDuration: packetDuration
            )
        }

        // Need conversion: set up or reconfigure swresample
        if swrContext == nil || outputSampleRate != Int(effectiveOutputRate) ||
           outputChannels != Int(outChannels) || outputBitsPerSample != bitsPerSample {
            setupSwresample(frame: frame, outputFormat: outputFormat)
        }

        guard let swrCtx = swrContext else {
            playerDebugLog("[AudioDecoder] No swresample context available")
            return nil
        }

        // When resampling, output sample count differs from input.
        // swr_get_out_samples gives the upper bound for the output.
        let maxOutSamples = needsResample
            ? swr_get_out_samples(swrCtx, nbSamples)
            : nbSamples

        // Allocate output buffer
        var outputBuffer: UnsafeMutablePointer<UInt8>?
        av_samples_alloc(&outputBuffer, nil, outChannels, maxOutSamples, outputFormat, 0)
        guard let outBuf = outputBuffer else { return nil }
        defer { av_freep(&outputBuffer) }

        // Bridge AVFrame.data tuple → pointer array for swr_convert input
        let convertedSamples: Int32 = withUnsafePointer(to: frame.pointee.data) { dataPtr in
            let inputPtr = UnsafeRawPointer(dataPtr)
                .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            var outPtr: UnsafeMutablePointer<UInt8>? = outBuf
            return swr_convert(
                swrCtx,
                &outPtr, maxOutSamples,
                UnsafeMutablePointer(mutating: inputPtr), nbSamples
            )
        }

        guard convertedSamples > 0 else {
            playerDebugLog("[AudioDecoder] swr_convert returned \(convertedSamples)")
            return nil
        }

        let actualSize = Int(convertedSamples) * Int(outChannels) * bytesPerSample
        let pcmData = Data(bytes: outBuf, count: actualSize)

        // When resampling, use continuous PTS tracking to eliminate micro-gaps.
        // The resampler output sample count doesn't exactly match source PTS spacing,
        // creating ~0.37ms gaps per batch that cause audible crackling. By tracking
        // a running PTS based on actual output samples, each buffer starts exactly
        // where the previous one ended.
        var overridePTS: CMTime?
        if needsResample {
            let timescale = Int32(effectiveOutputRate)
            if continuousOutputPTS.isValid {
                overridePTS = continuousOutputPTS
            }
            // Advance continuous PTS by actual output sample count
            let outputDuration = CMTime(value: CMTimeValue(convertedSamples), timescale: timescale)
            if continuousOutputPTS.isValid {
                continuousOutputPTS = CMTimeAdd(continuousOutputPTS, outputDuration)
            }
            // Will be anchored on first valid PTS from buildDecodedFrame
        }

        return buildDecodedFrame(
            data: pcmData, sampleCount: Int(convertedSamples),
            sampleRate: Int(effectiveOutputRate), channels: Int(outChannels),
            bitsPerSample: bitsPerSample, framePTS: frame.pointee.pts,
            packetTimebase: packetTimebase,
            packetPTS: packetPTS,
            packetDuration: packetDuration,
            continuousPTSOverride: overridePTS
        )
    }

    private func buildDecodedFrame(data: Data, sampleCount: Int, sampleRate: Int,
                                   channels: Int, bitsPerSample: Int,
                                   framePTS: Int64,
                                   packetTimebase: CMTime,
                                   packetPTS: CMTime,
                                   packetDuration: CMTime,
                                   continuousPTSOverride: CMTime? = nil) -> DecodedAudioFrame {
        let frameDuration = CMTime(
            seconds: Double(sampleCount) / Double(max(sampleRate, 1)),
            preferredTimescale: 90_000
        )
        let durationForFallback: CMTime = {
            if packetDuration.isValid && packetDuration.isNumeric && packetDuration > .zero {
                return packetDuration
            }
            return frameDuration
        }()

        // If continuous PTS override is provided (from resampling), use it directly
        // to eliminate micro-gaps between resampled buffers.
        if let override = continuousPTSOverride {
            lastDecodedPTS = override
            return DecodedAudioFrame(
                data: data, sampleCount: sampleCount, sampleRate: sampleRate,
                channels: channels, bitsPerSample: bitsPerSample, pts: override
            )
        }

        let framePTSScaled = cmTimeFromFFmpegTimestamp(framePTS, timebase: packetTimebase)
        let packetPTSValid = packetPTS.isValid && packetPTS.isNumeric ? packetPTS : nil

        var pts = framePTSScaled ?? packetPTSValid ?? .invalid
        if !pts.isValid || !pts.isNumeric {
            if lastDecodedPTS.isValid && lastDecodedPTS.isNumeric {
                pts = CMTimeAdd(lastDecodedPTS, durationForFallback)
            } else {
                pts = .zero
            }

            invalidTimestampCount += 1
            if invalidTimestampCount <= 5 || invalidTimestampCount % 100 == 0 {
                let ptsSeconds = CMTimeGetSeconds(pts)
                playerDebugLog(
                    "[AudioDecoder] Invalid decoded PTS fallback (count=\(invalidTimestampCount), " +
                    "resolved=\(String(format: "%.3f", ptsSeconds)))"
                )
            }
            if invalidTimestampCount <= 5 || invalidTimestampCount % 250 == 0 {
                let breadcrumb = Breadcrumb(level: .warning, category: "audio.timestamps")
                breadcrumb.message = "Decoder PTS fallback to monotonic timestamp"
                breadcrumb.data = [
                    "count": invalidTimestampCount,
                    "sample_count": sampleCount,
                    "sample_rate": sampleRate,
                    "channels": channels
                ]
                SentrySDK.addBreadcrumb(breadcrumb)
            }
        }

        if lastDecodedPTS.isValid && lastDecodedPTS.isNumeric {
            let lastSeconds = CMTimeGetSeconds(lastDecodedPTS)
            let currentSeconds = CMTimeGetSeconds(pts)
            if currentSeconds.isFinite, lastSeconds.isFinite, currentSeconds + 0.001 < lastSeconds {
                nonMonotonicTimestampCount += 1
                if nonMonotonicTimestampCount <= 5 || nonMonotonicTimestampCount % 100 == 0 {
                    playerDebugLog(
                        "[AudioDecoder] Non-monotonic decoded PTS (count=\(nonMonotonicTimestampCount)) " +
                        "current=\(String(format: "%.3f", currentSeconds)) last=\(String(format: "%.3f", lastSeconds))"
                    )
                }
                if nonMonotonicTimestampCount <= 5 || nonMonotonicTimestampCount % 250 == 0 {
                    let breadcrumb = Breadcrumb(level: .warning, category: "audio.timestamps")
                    breadcrumb.message = "Decoder produced non-monotonic PTS"
                    breadcrumb.data = [
                        "count": nonMonotonicTimestampCount,
                        "current_pts": currentSeconds,
                        "last_pts": lastSeconds
                    ]
                    SentrySDK.addBreadcrumb(breadcrumb)
                }

                pts = CMTimeAdd(lastDecodedPTS, durationForFallback)
            }
        }

        lastDecodedPTS = pts

        // Anchor continuous PTS tracking on the first valid resolved PTS.
        // This is the starting point for gapless resampled output.
        if !continuousOutputPTS.isValid && pts.isValid && pts.isNumeric {
            let timescale = Int32(sampleRate)
            continuousOutputPTS = CMTime(
                seconds: CMTimeGetSeconds(pts),
                preferredTimescale: timescale
            )
            continuousOutputTimescale = timescale
            // Advance past this frame's duration so the next resampled buffer
            // starts right after this one
            let frameDur = CMTime(value: CMTimeValue(sampleCount), timescale: timescale)
            continuousOutputPTS = CMTimeAdd(continuousOutputPTS, frameDur)
        }

        return DecodedAudioFrame(
            data: data,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            pts: pts
        )
    }

    private func cmTimeFromFFmpegTimestamp(_ rawPTS: Int64, timebase: CMTime) -> CMTime? {
        guard rawPTS != Int64.min, rawPTS >= 0 else { return nil }
        guard timebase.timescale != 0, timebase.value != 0 else { return nil }
        if timebase.value == 1 {
            return CMTime(value: rawPTS, timescale: timebase.timescale)
        }
        let (scaled, overflow) = rawPTS.multipliedReportingOverflow(by: timebase.value)
        guard !overflow else { return nil }
        return CMTime(value: scaled, timescale: timebase.timescale)
    }

    // MARK: - Channel Layout Mapping

    /// Map channel count to a standard CoreAudio channel layout tag.
    /// Based on MPEG standard layouts matching FFmpeg's default channel orders.
    private static func channelLayoutTag(for channels: Int) -> AudioChannelLayoutTag {
        switch channels {
        case 1:  return kAudioChannelLayoutTag_Mono              // C
        case 2:  return kAudioChannelLayoutTag_Stereo            // L R
        case 3:  return kAudioChannelLayoutTag_MPEG_3_0_A        // L R C
        case 4:  return kAudioChannelLayoutTag_MPEG_4_0_A        // L R C Cs
        case 5:  return kAudioChannelLayoutTag_MPEG_5_0_A        // L R C Ls Rs
        case 6:  return kAudioChannelLayoutTag_MPEG_5_1_A        // L R C LFE Ls Rs
        case 7:  return kAudioChannelLayoutTag_MPEG_6_1_A        // L R C LFE Ls Rs Cs
        case 8:  return kAudioChannelLayoutTag_MPEG_7_1_A        // L R C LFE Ls Rs Lc Rc
        default:
            playerDebugLog("[AudioDecoder] No standard layout for \(channels) channels")
            return kAudioChannelLayoutTag_Unknown
        }
    }

    /// Set up libswresample for format/layout conversion.
    private func setupSwresample(frame: UnsafeMutablePointer<AVFrame>,
                                 outputFormat: AVSampleFormat) {
        if swrContext != nil {
            swr_free(&swrContext)
            swrContext = nil
        }

        let inputChannels = frame.pointee.ch_layout.nb_channels
        let inputRate = frame.pointee.sample_rate
        let needsDownmix = forceDownmixToStereo && inputChannels > 2

        // Use target rate if set (e.g. 44100 for AirPlay), otherwise pass through source rate
        let outRate = (targetOutputSampleRate > 0) ? Int32(targetOutputSampleRate) : inputRate

        swrContext = swr_alloc()
        guard swrContext != nil else {
            playerDebugLog("[AudioDecoder] Failed to allocate SwrContext")
            return
        }

        var inLayout = frame.pointee.ch_layout
        // Raw PCM streams arrive without channel-layout metadata
        // (order=AV_CHANNEL_ORDER_UNSPEC, mask=0). swresample needs a concrete
        // layout to know the channel ordering — synthesize a default from the
        // channel count, which gives us the standard MPEG layouts (mono/stereo/
        // 5.1/7.1) that match channelLayoutTag(for:) on the output side.
        if inLayout.order == AV_CHANNEL_ORDER_UNSPEC {
            playerDebugLog(
                "[AudioDecoder] Input ch_layout was UNSPEC; defaulting to standard " +
                "\(inputChannels)ch layout for swresample"
            )
            av_channel_layout_default(&inLayout, inputChannels)
        }
        var outLayout: AVChannelLayout
        if needsDownmix {
            outLayout = AVChannelLayout()
            av_channel_layout_default(&outLayout, 2)
        } else {
            outLayout = inLayout
        }

        swr_alloc_set_opts2(
            &swrContext,
            &outLayout, outputFormat, outRate,       // output
            &inLayout, AVSampleFormat(rawValue: frame.pointee.format), inputRate,  // input
            0, nil
        )

        let ret = swr_init(swrContext)
        guard ret >= 0 else {
            swr_free(&swrContext)
            swrContext = nil
            playerDebugLog("[AudioDecoder] swr_init failed: \(ret)")
            return
        }

        let outChannels = needsDownmix ? Int32(2) : inputChannels
        self.outputSampleRate = Int(outRate)
        self.outputChannels = Int(outChannels)
        self.outputBitsPerSample = Int(av_get_bytes_per_sample(outputFormat)) * 8
        self.outputChannelLayoutTag = Self.channelLayoutTag(for: Int(outChannels))
        // Invalidate cached format description when format changes
        self.cachedFormatDescription = nil

        let downmixLabel = needsDownmix ? " (downmixed from \(inputChannels)ch)" : ""
        let resampleLabel = (outRate != inputRate) ? " (resampled from \(inputRate)Hz)" : ""
        playerDebugLog("[AudioDecoder] SwrContext initialized: \(outChannels)ch \(outRate)Hz \(outputBitsPerSample)-bit layout=\(outputChannelLayoutTag)\(downmixLabel)\(resampleLabel)")
    }

    private func minimumBatchSamples(for sampleRate: Int) -> Int {
        guard sampleRate > 0 else { return baseMinBatchSamples }

        // AirPlay-shaped PCM output is the fragile case: keep fewer, larger buffers
        // on the renderer boundary instead of many ~20ms chunks. HomePod routes in
        // particular need noticeably fatter batches so steady-state pull restarts can
        // rebuild a cushion in a small number of deliveries.
        if targetOutputSampleRate > 0 || forceDownmixToStereo || useSignedInt16Output {
            let durationSamples = Int((Double(sampleRate) * 0.16).rounded())
            return max(baseMinBatchSamples, durationSamples)
        }

        return baseMinBatchSamples
    }

    private func maybeLogBatchConfig(sampleRate: Int, minBatchSamples: Int) {
        guard !hasLoggedBatchConfig else { return }
        hasLoggedBatchConfig = true

        let durationMs = (Double(minBatchSamples) / Double(max(sampleRate, 1))) * 1000
        let batchReason: String
        if targetOutputSampleRate > 0 || forceDownmixToStereo || useSignedInt16Output {
            batchReason = "airplay_pcm_shaping"
        } else {
            batchReason = "default"
        }

        playerDebugLog(
            "[AudioDecoder] Batch config: minSamples=\(minBatchSamples) " +
            "duration=\(String(format: "%.1f", durationMs))ms reason=\(batchReason) " +
            "targetRate=\(targetOutputSampleRate > 0 ? "\(targetOutputSampleRate)" : "native") " +
            "downmix=\(forceDownmixToStereo) s16=\(useSignedInt16Output)"
        )
    }
}

// MARK: - AVERROR Constants

/// AVERROR(EAGAIN) on Darwin: -(EAGAIN) = -35
private let kAudioDecoderEAGAIN: Int32 = -35

/// AVERROR_EOF: FFERRTAG('E','O','F',' ')
private let kAudioDecoderEOF: Int32 = {
    let tag = Int32(bitPattern:
        (UInt32(Character("E").asciiValue!) |
        (UInt32(Character("O").asciiValue!) << 8) |
        (UInt32(Character("F").asciiValue!) << 16) |
        (UInt32(Character(" ").asciiValue!) << 24)))
    return -tag
}()

#else

// =============================================================================
// MARK: - Stub Implementation (FFmpeg not available)
// =============================================================================

/// Stub audio decoder when FFmpeg libraries are not linked.
final class FFmpegAudioDecoder: @unchecked Sendable {

    static let supportedCodecs: Set<String> = []
    static let isAvailable = false

    init(codecpar: UnsafeRawPointer, codecNameHint: String? = nil) throws {
        throw FFmpegError.notAvailable
    }

    func decode(_ packet: DemuxedPacket) -> [DecodedAudioFrame] { [] }
    func decodeAndBatch(_ packet: DemuxedPacket) -> [DecodedAudioFrame] { [] }
    func flushBatch() -> DecodedAudioFrame? { nil }
    func resetTimestampTracking(reason: String) {}

    func createPCMSampleBuffer(from frame: DecodedAudioFrame) throws -> CMSampleBuffer {
        throw FFmpegError.notAvailable
    }

    func close() {}
}

#endif
