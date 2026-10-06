// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// One rung of the transcode ladder; matches the steps PMS advertises.
nonisolated struct QualityStep: Hashable, Sendable {
    let kbps: Int
    /// Plex `videoResolution` query value.
    let videoResolution: String

    var height: Int { Int(videoResolution.split(separator: "x").last ?? "") ?? 0 }
    /// The `VersionRanking` tier a transcode at this step produces.
    var tier: Int { VersionRanking.tier(label: nil, height: height) }

    var label: String {
        guard kbps >= 1000 else { return "\(kbps) kbps" }
        let mbps = Double(kbps) / 1000
        let rate = mbps == mbps.rounded() ? "\(Int(mbps)) Mbps" : "\(mbps) Mbps"
        return kbps >= 1500 ? "\(rate) \(height)p" : rate
    }

    static let ladder: [QualityStep] = [
        QualityStep(kbps: 20000, videoResolution: "1920x1080"),
        QualityStep(kbps: 12000, videoResolution: "1920x1080"),
        QualityStep(kbps: 8000, videoResolution: "1920x1080"),
        QualityStep(kbps: 4000, videoResolution: "1280x720"),
        QualityStep(kbps: 2000, videoResolution: "1280x720"),
        QualityStep(kbps: 1500, videoResolution: "720x480"),
        QualityStep(kbps: 720, videoResolution: "576x320"),
    ]

    /// What a Plex Relay connection can sustain.
    static let relay = QualityStep(kbps: 1500, videoResolution: "720x480")

    static func step(kbps: Int) -> QualityStep? { ladder.first { $0.kbps == kbps } }
}

/// A Home or Away streaming quality setting, or a per-title choice in the player.
nonisolated enum StreamingQuality: Hashable, Sendable, RawRepresentable {
    case original
    case auto
    case step(QualityStep)

    static let homeKey = "homeStreamingQuality"
    static let awayKey = "awayStreamingQuality"
    static let homeDefault: StreamingQuality = .original
    static let awayDefault: StreamingQuality = .auto

    /// Every choice a picker offers, in display order.
    static let allChoices: [StreamingQuality] = [.original, .auto] + QualityStep.ladder.map { .step($0) }

    var label: String {
        switch self {
        case .original: "Original"
        case .auto: "Auto"
        case .step(let step): step.label
        }
    }

    /// The stored setting; a missing or unknown value falls back to the default.
    static func setting(home: Bool, defaults: UserDefaults = .standard) -> StreamingQuality {
        defaults.string(forKey: home ? homeKey : awayKey).flatMap(StreamingQuality.init(rawValue:))
            ?? (home ? homeDefault : awayDefault)
    }

    init?(rawValue: String) {
        switch rawValue {
        case "original": self = .original
        case "auto": self = .auto
        default:
            guard let kbps = Int(rawValue), let step = QualityStep.step(kbps: kbps) else { return nil }
            self = .step(step)
        }
    }

    var rawValue: String {
        switch self {
        case .original: "original"
        case .auto: "auto"
        case .step(let step): "\(step.kbps)"
        }
    }
}
