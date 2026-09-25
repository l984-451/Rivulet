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
    /// A single directional press-and-hold can be observed by TWO independent
    /// detectors at the same ~0.4s threshold — a GameController hold timer
    /// (.siriMicroGamepad, via an async hop) and a UIKit press path (.irPress).
    /// Both emit `.scrubNudge`, and the async skew routinely pushes them >0.08s
    /// apart, so each was bumping the shuttle a level (a single hold jumping
    /// 2x→4x on its own). This wider CROSS-SOURCE window coalesces the two into
    /// one hold entry, while deliberate same-source re-clicks (which bump on
    /// purpose) are never deduped because they share a source. Sized above the
    /// observed skew but below a human's fastest deliberate double-click.
    ///
    /// The VOD player no longer has two detectors (its GameController mirrors
    /// are off, see `RemoteInputHandler.uikitOwnsPresses`); Live TV's Channels
    /// layout still does, and an MPRemoteCommand seek can still pair with a
    /// press.
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
    /// How far out a touch must rest for a clickpad `.select` to count as a
    /// Left/Right EDGE click (1st-generation Siri Remote, whose clicks all
    /// arrive as `.select`). Stricter than `dpadThreshold` because a wrong yes
    /// skips the video instead of showing the controls. Kept inside the ring
    /// that `wheelRadiusThreshold` treats as the outer edge.
    static let edgeClickThreshold: Float = 0.6
    static let joystickDeadzone: Float = 0.2

    /// Left/right region of a Siri Remote clickpad touch in absolute dpad
    /// coordinates: true = right, false = left, nil = anything else.
    ///
    /// Horizontal must DOMINATE, not just clear the threshold. An x-only test
    /// read every Up or Down click made slightly off the vertical axis (say
    /// x 0.35, y 0.9) as a Right click, so one press both raised the rail and
    /// queued a skip.
    static func clickpadHorizontalDirection(x: Float, y: Float, threshold: Float = dpadThreshold) -> Bool? {
        guard abs(x) > threshold, abs(x) > abs(y) else { return nil }
        return x > 0
    }

    static let wheelRotationThreshold: Float = 0.3
    static let wheelRadiusThreshold: Float = 0.7
    static let wheelSecondsPerRadian: TimeInterval = 10
}
