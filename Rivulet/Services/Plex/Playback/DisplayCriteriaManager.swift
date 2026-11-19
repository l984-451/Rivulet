// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DisplayCriteriaManager.swift
//  Rivulet
//
//  Manages tvOS display criteria for HDR/Dolby Vision content
//  Enables Match Frame Rate and Match Dynamic Range for Rivulet playback
//

import Foundation
import AVFoundation
import AVKit


/// Manages display criteria for HDR content playback
/// This enables tvOS "Match Content" (Frame Rate and Dynamic Range) for Rivulet playback
///
/// Note: Apple doesn't provide a public API to create AVDisplayCriteria manually.
/// The only way to obtain display criteria is from AVAsset.preferredDisplayCriteria.
/// This manager creates a temporary AVURLAsset to fetch the criteria from the stream.
@MainActor
final class DisplayCriteriaManager {

    static let shared = DisplayCriteriaManager()

    private var hasSetCriteria = false
    private var lastCriteriaWasHDR = false
    private var assetForCriteria: AVURLAsset?

    private init() {}

    /// Whether the system will honor display criteria changes (Match Content enabled)
    var isDisplayCriteriaMatchingEnabled: Bool {
        getDisplayManager()?.isDisplayCriteriaMatchingEnabled ?? false
    }

    // MARK: - Public API

    /// Configure display criteria by fetching it from the stream URL
    /// This creates a temporary AVURLAsset to extract HDR/frame rate metadata
    /// Call this before starting playback to trigger Match Content
    /// - Parameters:
    ///   - url: The video stream URL
    ///   - headers: HTTP headers for authentication
    func configureFromURL(_ url: URL, headers: [String: String]? = nil) async {

        // Create asset with headers
        var options: [String: Any] = [:]
        if let headers = headers, !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }

        let asset = AVURLAsset(url: url, options: options)
        self.assetForCriteria = asset  // Keep reference to prevent deallocation

        do {
            // Load the display criteria from the asset (tvOS 16+ API)
            let criteria = try await asset.load(.preferredDisplayCriteria)
            lastCriteriaWasHDR = false
            setDisplayCriteria(criteria)
        } catch {
            playerDebugLog("🖥️ DisplayCriteria: Failed to load display criteria: \(error.localizedDescription)")
            // Continue without display criteria - playback will still work, just without mode switching
        }
    }

    /// Configure display criteria using pre-built criteria from an AVAsset
    /// Use this if you already have an AVAsset (e.g., from preflight check)
    func configureFromAsset(_ asset: AVAsset) async {
        do {
            let criteria = try await asset.load(.preferredDisplayCriteria)
            lastCriteriaWasHDR = false
            setDisplayCriteria(criteria)
        } catch {
            playerDebugLog("🖥️ DisplayCriteria: Failed to load criteria from asset: \(error.localizedDescription)")
        }
    }

    /// Configure display criteria with known HDR type using a format description
    /// Creates a minimal format description to generate criteria
    /// - Parameters:
    ///   - frameRate: Target frame rate (e.g., 23.976, 24, 25, 29.97, 30, 50, 59.94, 60)
    ///   - width: Video width
    ///   - height: Video height
    ///   - isDolbyVision: Whether content is Dolby Vision
    ///   - isHDR10: Whether content is HDR10/HDR10+
    ///   - isHLG: Whether content is HLG
    func configureWithFormatDescription(
        frameRate: Float,
        width: Int32,
        height: Int32,
        isDolbyVision: Bool = false,
        isHDR10: Bool = false,
        isHLG: Bool = false
    ) {
        // Create a format description with HDR metadata
        var formatDescription: CMFormatDescription?

        // Determine the codec type
        // Use DV-specific codec type (dvh1) for Dolby Vision to trigger DV display mode
        // HEVC for other HDR content, H.264 for SDR
        let codecType: CMVideoCodecType
        if isDolbyVision {
            codecType = 0x64766831 // 'dvh1' — Dolby Vision HEVC
        } else if isHDR10 || isHLG {
            codecType = kCMVideoCodecType_HEVC
        } else {
            codecType = kCMVideoCodecType_H264
        }

        // Build extensions dictionary for HDR metadata
        var extensions: [CFString: Any] = [:]

        // Set color primaries and transfer function based on HDR type
        if isDolbyVision || isHDR10 || isHLG {
            // BT.2020 color primaries for all HDR types
            extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020

            // YCbCr matrix
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020

            if isDolbyVision {
                // Dolby Vision uses PQ transfer function
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                // Add Dolby Vision configuration (Profile 5 is most common for streaming)
                // Note: This is a simplified representation
            } else if isHLG {
                // HLG transfer function
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            } else if isHDR10 {
                // HDR10 uses PQ (SMPTE ST 2084)
                extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            }
        } else {
        }

        // Create the format description
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: width,
            height: height,
            extensions: extensions as CFDictionary?,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDesc = formatDescription else {
            playerDebugLog("🖥️ DisplayCriteria: Failed to create format description (status: \(status))")
            return
        }

        // Create display criteria from format description
        let criteria = AVDisplayCriteria(refreshRate: frameRate, formatDescription: formatDesc)
        lastCriteriaWasHDR = isDolbyVision || isHDR10 || isHLG
        setDisplayCriteria(criteria)
    }

    /// Wait briefly for tvOS to settle the HDMI/display-mode switch after
    /// preferredDisplayCriteria is written. AVPlayerViewController gets this
    /// internally; Rivulet's own player must avoid presenting first samples during the
    /// dynamic-range handshake.
    func waitForDisplaySwitchIfNeeded() async {
        guard hasSetCriteria, let window = getKeyWindow() else { return }

        let displayManager = window.avDisplayManager
        guard displayManager.isDisplayCriteriaMatchingEnabled else { return }

        let screen = window.screen
        if lastCriteriaWasHDR && screen.currentEDRHeadroom > 1.001 {
            return
        }

        var sawSwitchStart = false
        for _ in 0..<100 {
            if displayManager.isDisplayModeSwitchInProgress {
                sawSwitchStart = true
                break
            }
            if lastCriteriaWasHDR && screen.currentEDRHeadroom > 1.001 {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        guard sawSwitchStart else {
            if lastCriteriaWasHDR {
                playerDebugLog(
                    "🖥️ DisplayCriteria: HDR switch did not start within 1000ms " +
                    "(EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))"
                )
            }
            return
        }

        for tick in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if !displayManager.isDisplayModeSwitchInProgress {
                if lastCriteriaWasHDR && screen.currentEDRHeadroom <= 1.001 {
                    let totalMs = (tick + 1) * 100 + 1000
                    playerDebugLog(
                        "🖥️ DisplayCriteria: HDR switch settled after ~\(totalMs)ms " +
                        "but EDR headroom is still \(String(format: "%.2f", screen.currentEDRHeadroom))"
                    )
                }
                return
            }
        }

        playerDebugLog(
            "🖥️ DisplayCriteria: display-mode switch did not settle within 5s " +
            "(EDR headroom \(String(format: "%.2f", screen.currentEDRHeadroom)))"
        )
    }

    /// Resets display criteria to SDR when playback ends. Writes nil unconditionally, even
    /// when the engine set the criteria, so the HDMI handshake starts behind the exit fade (#249).
    /// Returns whether a renegotiation is incoming; the exit fade's mask is gated on it.
    @discardableResult
    func reset() -> Bool {
        hasSetCriteria = false
        lastCriteriaWasHDR = false
        assetForCriteria = nil  // Release the asset

        guard let displayManager = getDisplayManager() else {
            playerDebugLog("🖥️ DisplayCriteria: No display manager available for reset")
            return false
        }
        guard displayManager.preferredDisplayCriteria != nil else {
            playerDebugLog("🖥️ DisplayCriteria: reset — panel already at default, no handshake expected")
            return false
        }

        displayManager.preferredDisplayCriteria = nil
        playerDebugLog("🖥️ DisplayCriteria: reset — criteria released, HDMI handshake starts now")
        return true
    }

    // MARK: - Convenience Methods

    /// The first variant of an HLS master playlist, as the panel needs it.
    struct HLSVariantMode: Equatable {
        var frameRate: Float
        var width: Int32
        var height: Int32
        var isDolbyVision: Bool
        var isHDR10: Bool
        var isHLG: Bool
    }

    /// Asks for the panel mode an HLS stream's master playlist describes.
    func configure(forMasterPlaylist master: String) {
        guard let mode = HLSVariantMode(masterPlaylist: master) else { return }
        configureWithFormatDescription(frameRate: mode.frameRate, width: mode.width, height: mode.height,
                                       isDolbyVision: mode.isDolbyVision, isHDR10: mode.isHDR10, isHLG: mode.isHLG)
    }

    /// Configure display criteria from Plex video stream metadata
    /// Uses format description from Plex metadata (instant, no network request)
    /// This is the preferred method as it adds zero latency to playback start
    /// Works for ALL content - SDR gets frame rate matching, HDR/DV gets dynamic range matching too
    /// - Parameters:
    ///   - videoStream: The video stream metadata from Plex
    ///   - forceHDR10Fallback: If true, treat Dolby Vision content as HDR10 instead
    func configureForContent(videoStream: PlexStream?, forceHDR10Fallback: Bool = false) {
        guard let stream = videoStream, stream.isVideo else {
            playerDebugLog("🖥️ DisplayCriteria: No video stream metadata available")
            return
        }

        let frameRate = Float(stream.frameRate ?? 24.0)
        let width = Int32(stream.width ?? 1920)
        let height = Int32(stream.height ?? 1080)

        // Optionally strip Dolby Vision to an HDR10 fallback.
        // Check if base layer is HDR10 compatible (BL Compat ID 1 or 4)
        let blCompatID = stream.DOVIBLCompatID
        let hasHDR10Base = blCompatID == 1 || blCompatID == 4

        let isDV: Bool
        let isHDR: Bool
        let isHLG = stream.colorTrc?.lowercased().contains("hlg") == true ||
                    stream.colorTrc?.lowercased().contains("arib-std-b67") == true

        if forceHDR10Fallback && stream.isDolbyVision {
            // Use HDR10 if the base layer is compatible, otherwise SDR.
            isDV = false
            isHDR = hasHDR10Base || stream.isHDR
            playerDebugLog("🖥️ DisplayCriteria: DV fallback active - using \(isHDR ? "HDR10" : "SDR") (BL CompatID: \(blCompatID ?? -1))")
        } else {
            isDV = stream.isDolbyVision
            isHDR = stream.isHDR && !isDV
        }

        // Log what we're configuring
        let dynamicRange = isDV ? "Dolby Vision" : isHLG ? "HLG" : isHDR ? "HDR10" : "SDR"
        playerDebugLog("🖥️ DisplayCriteria: Configuring for \(dynamicRange) @ \(frameRate)fps (\(width)x\(height))")

        configureWithFormatDescription(
            frameRate: frameRate,
            width: width,
            height: height,
            isDolbyVision: isDV,
            isHDR10: isHDR,
            isHLG: isHLG
        )
    }

    /// Configure display criteria by fetching from stream URL
    /// Note: This adds latency as it requires a network request - use configureForContent(videoStream:) instead
    func configureForContentFromURL(
        url: URL,
        headers: [String: String]?,
        videoStream: PlexStream?
    ) async {
        // Try to get criteria from URL (most accurate but slow)
        await configureFromURL(url, headers: headers)

        // If URL-based approach failed, fall back to metadata
        if !hasSetCriteria {
            configureForContent(videoStream: videoStream)
        }
    }

    // MARK: - Private Helpers

    /// Set display criteria on the display manager
    private func setDisplayCriteria(_ criteria: AVDisplayCriteria) {
        guard let displayManager = getDisplayManager() else {
            playerDebugLog("🖥️ DisplayCriteria: No display manager available")
            return
        }

        displayManager.preferredDisplayCriteria = criteria
        hasSetCriteria = true

        // Log the display manager state
        if displayManager.isDisplayCriteriaMatchingEnabled {
        } else {
            playerDebugLog("🖥️ DisplayCriteria: ⚠️ Display criteria matching is DISABLED in system settings")
            playerDebugLog("🖥️ DisplayCriteria: User should enable 'Match Content' in Settings > Video and Audio")
        }
    }

    /// Get the display manager from the key window
    private func getDisplayManager() -> AVDisplayManager? {
        getKeyWindow()?.avDisplayManager
    }

    private func getKeyWindow() -> UIWindow? {
        // On tvOS, get the key window's display manager
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            playerDebugLog("🖥️ DisplayCriteria: Could not find window")
            return nil
        }

        #if targetEnvironment(simulator)
        // avDisplayManager category may not load on the simulator (no real display hardware)
        guard window.responds(to: Selector(("avDisplayManager"))) else {
            playerDebugLog("🖥️ DisplayCriteria: avDisplayManager not available on simulator")
            return nil
        }
        #endif

        return window
    }
}

extension DisplayCriteriaManager.HLSVariantMode {
    /// Nil without FRAME-RATE: a guessed rate would switch the panel wrongly.
    init?(masterPlaylist: String) {
        guard let line = masterPlaylist.split(separator: "\n").first(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
              let frameRate = Self.attribute("FRAME-RATE", in: line).flatMap(Float.init) else { return nil }
        let size = Self.attribute("RESOLUTION", in: line)?.split(separator: "x").compactMap { Int32($0) } ?? []
        let range = Self.attribute("VIDEO-RANGE", in: line)
        let codecs = (Self.attribute("CODECS", in: line) ?? "") + "," + (Self.attribute("SUPPLEMENTAL-CODECS", in: line) ?? "")
        let dolbyVision = codecs.contains("dvh1") || codecs.contains("dvhe")
        self.frameRate = frameRate
        width = size.first ?? 1920
        height = size.count == 2 ? size[1] : 1080
        isDolbyVision = range == "PQ" && dolbyVision
        isHDR10 = range == "PQ" && !dolbyVision
        isHLG = range == "HLG"
    }

    private static func attribute(_ name: String, in line: Substring) -> String? {
        let pattern = "(?<![A-Z-])\(name)=(\"([^\"]*)\"|[^,]*)"
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[match].dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}
