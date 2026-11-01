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
        menuToggleCases(available: allCases.filter(\.isAvailable), levelsAvailable: levelsAvailable).map { adjustment in
            CardToggleConfig(title: adjustment.title, isOn: { adjustment.isOn }, onToggle: { adjustment.set($0) })
        }
    }

    /// Enhance Dialogue's level choice, when the route offers levels.
    static var menuChoices: [CardChoiceConfig] {
        guard showsLevels(available: allCases.filter(\.isAvailable), levelsAvailable: levelsAvailable) else { return [] }
        return [CardChoiceConfig(
            title: SystemAudioAdjustment.enhanceDialogue.title,
            options: DialogueLevel.allCases.map(\.title),
            selected: { dialogueLevel.rawValue },
            onSelect: { if let level = DialogueLevel(rawValue: $0) { setDialogueLevel(level) } })]
    }

    /// The level choice replaces the Enhance Dialogue toggle.
    static func menuToggleCases(available: [SystemAudioAdjustment], levelsAvailable: Bool) -> [SystemAudioAdjustment] {
        showsLevels(available: available, levelsAvailable: levelsAvailable)
            ? available.filter { $0 != .enhanceDialogue } : available
    }

    static func showsLevels(available: [SystemAudioAdjustment], levelsAvailable: Bool) -> Bool {
        levelsAvailable && available.contains(.enhanceDialogue)
    }

    // MARK: Enhance Dialogue levels

    /// AVKit's ENHANCE_DIALOGUE_LEVEL_* choices; raw values are the system's levels.
    enum DialogueLevel: Int, CaseIterable {
        case off, enhance, enhanceMore, isolate

        var title: String {
            switch self {
            case .off: "Off"
            case .enhance: "Enhance"
            case .enhanceMore: "Enhance More"
            case .isolate: "Isolate"
            }
        }
    }

    /// Enhance Dialogue's current setting for the Details pane (#356); nil when the route can't apply it.
    static var dialogueSummary: String? {
        guard enhanceDialogue.isAvailable else { return nil }
        return dialogueSummary(levelsAvailable: levelsAvailable, level: dialogueLevel)
    }

    static func dialogueSummary(levelsAvailable: Bool, level: DialogueLevel) -> String {
        levelsAvailable ? level.title : (level == .off ? "Off" : "On")
    }

    private static var levelsAvailable: Bool {
        UserDefaults(suiteName: domain)?.bool(forKey: "enhanceDialogueLevelsIsAvailable") ?? false
    }

    static var dialogueLevel: DialogueLevel {
        CFPreferencesAppSynchronize(domain as CFString)
        let raw = CFPreferencesCopyAppValue("enhancedialoguelevel" as CFString, domain as CFString) as? Int
        return effectiveLevel(enabled: SystemAudioAdjustment.enhanceDialogue.isOn, rawLevel: raw)
    }

    /// AVKit's mapping: off unless enabled; a missing or out-of-range level reads as Enhance.
    static func effectiveLevel(enabled: Bool, rawLevel: Int?) -> DialogueLevel {
        guard enabled else { return .off }
        guard let rawLevel, rawLevel <= 3 else { return .enhance }
        return DialogueLevel(rawValue: max(rawLevel, 1)) ?? .enhance
    }

    /// Any level also turns Enhance Dialogue on. The level travels as a string.
    static func setDialogueLevel(_ level: DialogueLevel) {
        guard level != .off else { return SystemAudioAdjustment.enhanceDialogue.set(false) }
        guard let center = NSClassFromString("NSDistributedNotificationCenter") as? NotificationCenter.Type else { return }
        center.default.post(name: Notification.Name("com.apple.TVPAudioVideoSettings.setEnhanceDialogueLevel"),
                            object: String(level.rawValue))
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

/// tvOS's live "show subtitles while muted" state (Accessibility > Subtitles >
/// Show When Muted). PineBoard sets `isDisplayingCaptionsOnMute` in this domain
/// while the TV is muted and the setting is on; AVKit KVO-observes the same key.
@MainActor
final class SystemCaptionsOnMute {
    private let defaults = UserDefaults(suiteName: "com.apple.preferences-sounds")
    private var observation: NSKeyValueObservation?

    var isActive: Bool { defaults?.isDisplayingCaptionsOnMute ?? false }

    init(onChange: @escaping @MainActor () -> Void) {
        observation = defaults?.observe(\.isDisplayingCaptionsOnMute, options: [.new]) { @Sendable _, _ in
            Task { @MainActor in onChange() }
        }
    }
}

private extension UserDefaults {
    // KVO needs a property named exactly as the key.
    @objc nonisolated dynamic var isDisplayingCaptionsOnMute: Bool { bool(forKey: "isDisplayingCaptionsOnMute") }
}
