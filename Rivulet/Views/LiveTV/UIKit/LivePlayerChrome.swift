// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LivePlayerChrome.swift
//  Rivulet
//
//  What the live player asks of its chrome. The player owns playback,
//  transport and the panels; the chrome is the look around them. Two exist:
//  the glass rail the VOD player shares, and the showcase chrome of the
//  Browse layout (LiveShowcaseChromeView).
//

import UIKit

@MainActor
protocol LivePlayerChrome: UIView {
    var onSubtitles: (() -> Void)? { get set }
    var onAudio: (() -> Void)? { get set }
    var onInfo: (() -> Void)? { get set }
    /// The channel list.
    var onUpNext: (() -> Void)? { get set }
    var onGoLive: (() -> Void)? { get set }
    var onRecord: (() -> Void)? { get set }

    func setTitle(_ title: String, eyebrow: String?)
    func setMeta(rating: String?, runtime: String?, audio: String?)
    func setGoLiveAvailable(_ available: Bool)
    func setRecordState(available: Bool, isRecording: Bool)
    /// Where the picture is relative to live. The rail leaves this to the
    /// player's own badge; the showcase chrome draws it in its LIVE pill.
    func setTimeshift(behindLiveSeconds: Double, hasRewindWindow: Bool, isPaused: Bool)
    /// Forget the last focused control, so the next appearance starts fresh.
    func resetFocusMemory()
    /// What a panel (subtitles, audio, channels) rises above and lines up
    /// with on its trailing edge.
    var panelAnchor: UIView { get }
}

extension PlayerRailView: LivePlayerChrome {
    func setTimeshift(behindLiveSeconds: Double, hasRewindWindow: Bool, isPaused: Bool) {}
    var panelAnchor: UIView { self }
}
