// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What a title plays as: the untouched file, or a server transcode at a step.
nonisolated enum StreamPlan: Equatable, Sendable {
    case original
    case transcode(QualityStep)

    var step: QualityStep? {
        if case .transcode(let step) = self { step } else { nil }
    }
}

/// Original vs transcode for one title. Pure; callers supply the measurements.
nonisolated enum QualityDecision {
    /// Auto plays a file whose bitrate fits in this share of the measured throughput.
    static let headroom = 0.75
    /// Auto's step when the throughput probe fails.
    static let probeFailureStep = QualityStep(kbps: 4000, videoResolution: "1280x720")

    static func needsProbe(setting: StreamingQuality, isRelay: Bool) -> Bool {
        setting == .auto && !isRelay
    }

    /// The bitrate ceiling a version should fit under, or nil for no ceiling.
    static func capKbps(setting: StreamingQuality, measuredKbps: Int?, isRelay: Bool) -> Int? {
        let cap: Int? = switch setting {
        case .original: nil
        case .step(let step): step.kbps
        case .auto: measuredKbps.map { Int(Double($0) * headroom) } ?? probeFailureStep.kbps
        }
        guard isRelay else { return cap }
        return min(cap ?? QualityStep.relay.kbps, QualityStep.relay.kbps)
    }

    static func decide(setting: StreamingQuality, sourceKbps: Int?, measuredKbps: Int?, isRelay: Bool) -> StreamPlan {
        let plan: StreamPlan = switch setting {
        case .original: .original
        case .step(let step): sourceKbps.map { $0 <= step.kbps } == true ? .original : .transcode(step)
        case .auto: autoPlan(sourceKbps: sourceKbps, measuredKbps: measuredKbps)
        }
        guard isRelay else { return plan }
        if let step = plan.step, step.kbps <= QualityStep.relay.kbps { return plan }
        return .transcode(.relay)
    }

    /// The best step at or under `kbps`; the lowest step when none is.
    static func highestStep(atMost kbps: Int) -> QualityStep {
        QualityStep.ladder.first { $0.kbps <= kbps } ?? QualityStep.ladder[QualityStep.ladder.count - 1]
    }

    /// One step below what is playing, or nil at the bottom.
    static func stepDown(from plan: StreamPlan, sourceKbps: Int?) -> QualityStep? {
        let ceiling = plan.step?.kbps ?? sourceKbps ?? Int.max
        return QualityStep.ladder.first { $0.kbps < ceiling }
    }

    private static func autoPlan(sourceKbps: Int?, measuredKbps: Int?) -> StreamPlan {
        guard let sourceKbps else { return .original }
        guard let measuredKbps else {
            return sourceKbps <= probeFailureStep.kbps ? .original : .transcode(probeFailureStep)
        }
        let budget = Int(Double(measuredKbps) * headroom)
        return sourceKbps <= budget ? .original : .transcode(highestStep(atMost: budget))
    }
}

extension PlexMedia {
    /// Container bitrate in kbps, or size over duration when Plex omits it.
    nonisolated var sourceKbps: Int? {
        if let bitrate, bitrate > 0 { return bitrate }
        guard let part = Part?.first, let size = part.size, let ms = part.duration ?? duration, ms > 0 else { return nil }
        return Int(Int64(size) * 8 / Int64(ms))
    }
}
