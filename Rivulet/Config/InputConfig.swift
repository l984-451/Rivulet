// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InputConfig.swift
//  Rivulet
//
//  Shared constants for remote/controller/keyboard input behavior.
//

import Foundation

enum InputConfig {
    static let holdThreshold: TimeInterval = 0.4
    static let seekCoalesceInterval: TimeInterval = 0.05
    static let actionDedupeWindow: TimeInterval = 0.08
    static let transportDedupeWindow: TimeInterval = 0.35
    /// A single directional press-and-hold is observed by TWO independent
    /// detectors at the same ~0.4s threshold — the GameController hold timer
    /// (.siriMicroGamepad, via an async hop) and the UIKit long-press
    /// recognizer (.irPress, synchronous). Both emit `.scrubNudge`, and the
    /// async skew routinely pushes them >0.08s apart, so each was bumping the
    /// shuttle a level (a single hold jumping 2x→4x on its own). This wider
    /// CROSS-SOURCE window coalesces the two into one hold entry, while
    /// deliberate same-source re-clicks (which bump on purpose) are never
    /// deduped because they share a source. Sized above the observed skew but
    /// below a human's fastest deliberate double-click.
    static let scrubNudgeDedupeWindow: TimeInterval = 0.25
    static let blockDismissTimeout: TimeInterval = 0.3

    /// Single-press Left/Right skip. Applied uniformly across every remote and
    /// focus state (content-focused, IR d-pad, keyboard, and the focused
    /// scrubber). User-configurable via Settings → Playback → Skip Length.
    static var tapSeekSeconds: TimeInterval {
        TimeInterval(SettingsStore.int(SkipInterval.storageKey, default: SkipInterval.defaultValue.rawValue))
    }
    static let jumpSeekSeconds: TimeInterval = 30

    static let dpadThreshold: Float = 0.3
    static let joystickDeadzone: Float = 0.2

    static let wheelRotationThreshold: Float = 0.3
    static let wheelRadiusThreshold: Float = 0.7
    static let wheelSecondsPerRadian: TimeInterval = 10
}
