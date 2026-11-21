// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveStreamQuality.swift
//  Rivulet
//
//  A channel's picture and sound as last played ("1080p", "5.1"). An IPTV
//  lineup does not say, and asking every stream would load the provider, so
//  the player notes it while a channel plays and the channel lists show it
//  from then on. Kept on this device.
//

import Foundation
import Combine

nonisolated struct LiveStreamQuality: Codable, Equatable, Sendable {
    /// Picture height in pixels, nil when the player could not tell.
    var height: Int?
    /// The playing audio track's channel count.
    var audioChannels: Int?

    /// "4K", "1080p", "720p" or "SD".
    var resolutionLabel: String? {
        guard let height, height > 0 else { return nil }
        switch height {
        case 1800...: return "4K"
        case 1300..<1800: return "1440p"
        case 900..<1300: return "1080p"
        case 650..<900: return "720p"
        default: return "SD"
        }
    }

    /// "Mono", "Stereo", "5.1", "7.1", or a plain count.
    var audioLabel: String? {
        guard let audioChannels, audioChannels > 0 else { return nil }
        switch audioChannels {
        case 1: return String(localized: "Mono")
        case 2: return String(localized: "Stereo")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return String(localized: "\(audioChannels) channels")
        }
    }

    /// The labels that are known, picture first.
    var labels: [String] { [resolutionLabel, audioLabel].compactMap { $0 } }
}

@MainActor
final class LiveStreamQualityStore: ObservableObject {
    static let shared = LiveStreamQualityStore()

    /// By channel id.
    @Published private(set) var byChannel: [String: LiveStreamQuality] = [:]

    private let defaults: UserDefaults
    static let defaultsKey = "liveTVStreamQuality"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: LiveStreamQuality].self, from: data) {
            byChannel = saved
        }
    }

    func quality(for channelId: String) -> LiveStreamQuality? { byChannel[channelId] }

    /// What the player reports. A part it cannot tell keeps the value from before.
    func record(channelId: String, height: Int?, audioChannels: Int?) {
        var quality = byChannel[channelId] ?? LiveStreamQuality()
        if let height, height > 0 { quality.height = height }
        if let audioChannels, audioChannels > 0 { quality.audioChannels = audioChannels }
        guard quality != byChannel[channelId], !quality.labels.isEmpty else { return }
        byChannel[channelId] = quality
        if let data = try? JSONEncoder().encode(byChannel) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
