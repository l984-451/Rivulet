// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SystemAudioAdjustments.swift
//  Rivulet
//
//  tvOS's Enhance Dialogue and Reduce Loud Sounds, as AVKit's audio menu drives
//  them (#330). No public API: AVKit reads com.apple.preferences-sounds and asks
//  the system to flip a setting with a distributed notification. Both settings
//  are system-wide, exactly as when changed from AVKit or Settings.
//

import Foundation

enum SystemAudioAdjustment: CaseIterable {
    case enhanceDialogue
    case reduceLoudSounds

    private static let domain = "com.apple.preferences-sounds"

    var title: String {
        switch self {
        case .enhanceDialogue: "Enhance Dialogue"
        case .reduceLoudSounds: "Reduce Loud Sounds"
        }
    }

    /// False when the current output route can't apply it (the system publishes this).
    var isAvailable: Bool {
        UserDefaults(suiteName: Self.domain)?.bool(forKey: availabilityKey) ?? false
    }

    var isOn: Bool {
        CFPreferencesAppSynchronize(Self.domain as CFString)
        return CFPreferencesGetAppBooleanValue(stateKey as CFString, Self.domain as CFString, nil)
    }

    func set(_ on: Bool) {
        guard let center = NSClassFromString("NSDistributedNotificationCenter") as? NotificationCenter.Type else { return }
        center.default.post(name: Notification.Name(on ? enableNotification : disableNotification), object: nil)
    }

    /// The audio popup's toggle rows, for the adjustments the route supports.
    static var menuToggles: [CardToggleConfig] {
        allCases.filter(\.isAvailable).map { adjustment in
            CardToggleConfig(title: adjustment.title, isOn: { adjustment.isOn }, onToggle: { adjustment.set($0) })
        }
    }

    private var availabilityKey: String {
        switch self {
        case .enhanceDialogue: "enhanceDialogIsAvailable"
        case .reduceLoudSounds: "lateNightModeIsAvailable"
        }
    }

    private var stateKey: String {
        switch self {
        case .enhanceDialogue: "enhancedialog"
        case .reduceLoudSounds: "latenightmode"
        }
    }

    private var enableNotification: String {
        switch self {
        case .enhanceDialogue: "com.apple.TVPAudioVideoSettings.enableEnhanceDialog"
        case .reduceLoudSounds: "com.apple.TVPAudioVideoSettings.enableLateNightMode"
        }
    }

    private var disableNotification: String {
        switch self {
        case .enhanceDialogue: "com.apple.TVPAudioVideoSettings.disableEnhanceDialog"
        case .reduceLoudSounds: "com.apple.TVPAudioVideoSettings.disableLateNightMode"
        }
    }
}
