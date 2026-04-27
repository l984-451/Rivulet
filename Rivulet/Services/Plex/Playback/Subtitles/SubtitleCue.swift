//
//  SubtitleCue.swift
//  Rivulet
//
//  Model for a single subtitle entry with timing and text.
//

import Foundation

/// A single subtitle cue with start time, end time, and text content
struct SubtitleCue: Identifiable, Equatable, Sendable {
    let id: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    /// Check if this cue should be displayed at the given time
    func isActive(at time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }
}

/// Collection of parsed subtitle cues
struct SubtitleTrack: Sendable {
    let cues: [SubtitleCue]

    /// Find all cues that should be displayed at the given time
    /// (multiple cues can overlap)
    func activeCues(at time: TimeInterval) -> [SubtitleCue] {
        // Binary search for efficiency with large subtitle files
        // Find first cue that might be active, then collect all active ones
        guard !cues.isEmpty else { return [] }

        var result: [SubtitleCue] = []

        // Binary search to find starting point
        var low = 0
        var high = cues.count - 1

        while low < high {
            let mid = (low + high) / 2
            if cues[mid].endTime <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // Collect all active cues from this point
        for i in low..<cues.count {
            let cue = cues[i]
            if cue.startTime > time {
                break  // Past our time window
            }
            if cue.isActive(at: time) {
                result.append(cue)
            }
        }

        return result
    }

    /// Empty track
    static let empty = SubtitleTrack(cues: [])
}

// MARK: - Bitmap Subtitle Types (PGS, DVB-SUB)

/// A single rectangle of bitmap subtitle data (RGBA pixels with position)
struct BitmapSubtitleRect: Sendable {
    let imageData: Data   // RGBA pixel data
    let width: Int
    let height: Int
    let x: Int            // Position in video frame
    let y: Int
}

/// A bitmap subtitle cue containing one or more positioned image rects
struct BitmapSubtitleCue: Identifiable, Sendable {
    let id: Int
    let startTime: TimeInterval
    var endTime: TimeInterval   // var: PGS cues use .infinity sentinel, trimmed when next cue arrives
    let rects: [BitmapSubtitleRect]
    /// Reference resolution that the rect coordinates are authored against.
    /// VOBSUB ≈ 720×480 (NTSC) or 720×576 (PAL), PGS = 1920×1080, DVB-SUB ≈ 720×576.
    /// 0 means the codec didn't report it; renderers should fall back to a sensible default.
    let referenceWidth: Int
    let referenceHeight: Int

    func isActive(at time: TimeInterval) -> Bool {
        time >= startTime && time < endTime
    }
}
