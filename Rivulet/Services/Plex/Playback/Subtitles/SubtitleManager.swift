//
//  SubtitleManager.swift
//  Rivulet
//
//  Manages subtitle loading, parsing, and current cue selection.
//

import Foundation
import Combine

/// Manages subtitle loading and provides current cues based on playback time
@MainActor
final class SubtitleManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentCues: [SubtitleCue] = []
    @Published private(set) var currentBitmapCues: [BitmapSubtitleCue] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published var diagnosticsEnabled = true

    // MARK: - Private State

    private var currentTrack: ParsedSubtitleTrack = .empty
    private var lastUpdateTime: TimeInterval = -1
    private let updateThreshold: TimeInterval = 0.05  // 50ms threshold to avoid excessive updates

    // MARK: - Loading

    /// Load subtitles from a URL with authentication headers
    func load(url: URL, headers: [String: String], format: SubtitleFormat? = nil) async {
        isLoading = true
        error = nil
        currentTrack = .empty
        currentCues = []

        do {
            let content = try await fetchSubtitleContent(url: url, headers: headers)
            let detectedFormat = format ?? SubtitleFormat(fromURL: url)

            let track: ParsedSubtitleTrack
            if let parser = detectedFormat.parser {
                track = try parser.parse(content)
            } else {
                // Try to auto-detect from content
                track = try parseWithAutoDetect(content)
            }

            guard !track.cues.isEmpty else {
                throw SubtitleLoadError.noCues
            }

            currentTrack = track
            if diagnosticsEnabled {
                playerDebugLog("🎬 [Subtitles] Loaded \(track.cues.count) cues (\(detectedFormat)) from \(url.lastPathComponent)")
            }
        } catch {
            self.error = error
            playerDebugLog("🎬 [Subtitles] ❌ Failed to load: \(error.localizedDescription)")
        }

        isLoading = false
    }

    /// Load subtitles from raw content string
    func load(content: String, format: SubtitleFormat) {
        error = nil
        currentTrack = .empty
        currentCues = []

        guard let parser = format.parser else {
            playerDebugLog("🎬 [Subtitles] ❌ No parser for format")
            return
        }

        do {
            let track = try parser.parse(content)
            currentTrack = track
            if diagnosticsEnabled {
                playerDebugLog("🎬 [Subtitles] Loaded \(track.cues.count) cues (\(format)) from content")
            }
        } catch {
            self.error = error
            playerDebugLog("🎬 [Subtitles] ❌ Parse error: \(error.localizedDescription)")
        }
    }

    /// Clear current subtitles
    func clear() {
        currentTrack = .empty
        currentCues = []
        accumulatedCues = []
        currentBitmapCues = []
        accumulatedBitmapCues = []
        error = nil
        lastUpdateTime = -1
    }

    // MARK: - Progressive Cue Addition (for embedded subtitle extraction)

    /// Accumulated cues from inline extraction, sorted on insertion
    private var accumulatedCues: [SubtitleCue] = []

    /// Accumulated bitmap cues from PGS/DVB-SUB subtitle streams
    private var accumulatedBitmapCues: [BitmapSubtitleCue] = []

    /// Add a single subtitle cue from an embedded stream (delivered by FFmpeg read loop).
    /// Rebuilds the subtitle track incrementally. Thread-safe: call from MainActor.
    func addCue(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        // Strip HTML tags (<i>, <b>, <font>, etc.) and ASS overrides ({\tag})
        let cleaned = text
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return }

        let cue = SubtitleCue(
            id: accumulatedCues.count,
            startTime: startTime,
            endTime: endTime,
            text: cleaned
        )
        accumulatedCues.append(cue)

        // Rebuild track — cues arrive in PTS order from the demuxer, so they're already sorted
        currentTrack = ParsedSubtitleTrack(cues: accumulatedCues)
    }

    /// Add a bitmap subtitle cue from an embedded PGS/DVB-SUB stream.
    ///
    /// PGS subtitles use "display set" semantics: each new cue replaces the previous one.
    /// Cues with `.infinity` end time are auto-closed when the next cue arrives.
    /// Cues with empty rects represent "clear screen" events — they close the previous cue
    /// without adding a new visible entry.
    func addBitmapCue(_ cue: BitmapSubtitleCue) {
        // Close any previous open-ended cue (PGS: .infinity sentinel means "until next display set")
        if let lastIndex = accumulatedBitmapCues.indices.last,
           accumulatedBitmapCues[lastIndex].endTime.isInfinite {
            accumulatedBitmapCues[lastIndex].endTime = cue.startTime
        }

        // Empty rects = PGS "clear screen" — previous cue closed above, nothing more to add
        guard !cue.rects.isEmpty else {
            if diagnosticsEnabled {
                playerDebugLog("🎬 [Subtitles] Bitmap clear at \(String(format: "%.3f", cue.startTime))")
            }
            return
        }

        accumulatedBitmapCues.append(cue)
        if diagnosticsEnabled {
            playerDebugLog("🎬 [Subtitles] Bitmap cue \(cue.id): \(cue.rects.count) rect(s) " +
                  "start=\(String(format: "%.3f", cue.startTime)) end=\(String(format: "%.3f", cue.endTime))")
        }
    }

    // MARK: - Time Updates

    /// User subtitle delay in seconds (positive = subtitles appear later).
    /// Mirrors SubtitleModel.delaySeconds on the aether route so the OSD
    /// delay stepper works identically on the HLS route.
    var delaySeconds: Double = 0

    /// Update current cues based on playback time
    /// Call this from your time observer (typically 4-10 times per second)
    func update(time rawTime: TimeInterval) {
        let time = rawTime - delaySeconds
        // Skip if time hasn't changed significantly
        guard abs(time - lastUpdateTime) > updateThreshold else { return }
        lastUpdateTime = time

        // Text cues
        let newCues = currentTrack.activeCues(at: time)

        // Only update if cues actually changed
        if newCues.map(\.id) != currentCues.map(\.id) {
            let previousCues = currentCues
            currentCues = newCues
            if diagnosticsEnabled {
                logCueTransition(time: time, from: previousCues, to: newCues)
            }
        }

        // Bitmap cues
        if !accumulatedBitmapCues.isEmpty {
            let activeBitmap = accumulatedBitmapCues.filter { $0.isActive(at: time) }
            if activeBitmap.map(\.id) != currentBitmapCues.map(\.id) {
                currentBitmapCues = activeBitmap
            }
            // Prune old bitmap cues that ended more than 30s ago to avoid unbounded growth
            accumulatedBitmapCues.removeAll { $0.endTime < time - 30 }
        } else if !currentBitmapCues.isEmpty {
            currentBitmapCues = []
        }
    }

    /// Seek occurred - force update on next time update
    func didSeek() {
        lastUpdateTime = -1
    }

    // MARK: - Private

    private func fetchSubtitleContent(url: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw SubtitleLoadError.httpError(httpResponse.statusCode)
        }

        // Try UTF-8 first, then Latin-1 as fallback (common for older SRT files)
        if let content = String(data: data, encoding: .utf8) {
            return stripUTF8BOMIfPresent(content)
        }
        if let content = String(data: data, encoding: .isoLatin1) {
            return stripUTF8BOMIfPresent(content)
        }
        if let content = String(data: data, encoding: .windowsCP1252) {
            return stripUTF8BOMIfPresent(content)
        }

        throw SubtitleLoadError.invalidEncoding
    }

    private func parseWithAutoDetect(_ content: String) throws -> ParsedSubtitleTrack {
        // Try ASS/SSA first when script sections are present.
        if content.contains("[Script Info]") || content.contains("[Events]") || content.contains("Dialogue:") {
            if let assTrack = try? ASSParser().parse(content), !assTrack.cues.isEmpty {
                return assTrack
            }
        }

        // Try VTT first (has explicit header)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") {
            return try VTTParser().parse(content)
        }

        // Try SRT
        do {
            return try SRTParser().parse(content)
        } catch {
            throw SubtitleLoadError.unsupportedFormat
        }
    }

    private func logCueTransition(time: TimeInterval, from previous: [SubtitleCue], to current: [SubtitleCue]) {
        let previousIDs = previous.map(\.id)
        let currentIDs = current.map(\.id)
        let added = current.filter { !previousIDs.contains($0.id) }
        let removed = previous.filter { !currentIDs.contains($0.id) }

        if !added.isEmpty {
            // for cue in added {
            //     playerDebugLog(
            //         "🎬 [Subtitles] SHOW t=\(String(format: "%.3f", time))s " +
            //         "cue=\(cue.id) start=\(String(format: "%.3f", cue.startTime)) " +
            //         "end=\(String(format: "%.3f", cue.endTime)) text=\"\(cue.logPreview)\""
            //     )
            // }
        }

        if !removed.isEmpty {
            // for cue in removed {
            //     playerDebugLog(
            //         "🎬 [Subtitles] HIDE t=\(String(format: "%.3f", time))s " +
            //         "cue=\(cue.id) start=\(String(format: "%.3f", cue.startTime)) " +
            //         "end=\(String(format: "%.3f", cue.endTime))"
            //     )
            // }
        }
    }

    private func stripUTF8BOMIfPresent(_ content: String) -> String {
        if content.hasPrefix("\u{FEFF}") {
            return String(content.dropFirst())
        }
        return content
    }
}

// MARK: - Errors

enum SubtitleLoadError: Error, LocalizedError {
    case httpError(Int)
    case invalidEncoding
    case unsupportedFormat
    case noCues

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP error \(code)"
        case .invalidEncoding: return "Could not decode subtitle file"
        case .unsupportedFormat: return "Unsupported subtitle format"
        case .noCues: return "Subtitle file contained no cues"
        }
    }
}

private extension SubtitleCue {
    var logPreview: String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if singleLine.count <= 80 { return singleLine }
        return String(singleLine.prefix(77)) + "..."
    }
}
