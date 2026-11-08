// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Whether the floating skip pill (Skip Intro, Skip Credits, Up Next) is still
/// up over the video while the controls are hidden (#556). With the controls
/// up the pill shows for the whole marker, and none of this applies.
///
/// It comes up when its marker starts and goes `autoHideDelay` after it
/// appears if untaken. Closing the controls shows it for another window. A
/// different key (or the same one after none) starts fresh, so seeking back
/// into a marker or reaching the next shows it. Menu's dismissal is the host's.
///
/// Time-free: the host reports whether the pill could be drawn right now
/// (`setCanAppear`), runs its timer as `syncTimer()` says, and reports a
/// finished count with `timeOut(window:held:)`.
nonisolated struct SkipPillPresence: Equatable {
    /// What the host's hide timer should do.
    enum TimerChange: Equatable {
        case none
        case start(window: Int)
        case stop
    }

    /// How long an untaken pill stays up once it is on screen.
    static let autoHideDelay: TimeInterval = 5

    /// The marker the pill belongs to; nil when there is no pill.
    private(set) var key: String?
    /// The pill's window is open for `key`: it has not timed out.
    private(set) var isShowing = false
    /// Counts windows, so a timer for an earlier one can't close a later one.
    private(set) var window = 0
    /// The host could draw the pill over the video now (video up, controls hidden).
    private(set) var canAppear = false
    /// The window the host's timer is counting; nil when none runs.
    private(set) var timedWindow: Int?

    /// The pill is on screen over the video.
    var isOnScreen: Bool { isShowing && canAppear }

    /// The pill's marker. A new key, or one after none, opens a fresh window.
    /// Returns true when a window opened.
    @discardableResult
    mutating func track(_ newKey: String?) -> Bool {
        guard newKey != key else { return false }
        key = newKey
        guard newKey != nil else {
            isShowing = false
            return false
        }
        return openWindow()
    }

    /// The controls closed, or an auto-skip countdown started or was cancelled:
    /// show the pill again for a fresh window. Returns true when one opened.
    @discardableResult
    mutating func reveal() -> Bool {
        guard key != nil else { return false }
        return openWindow()
    }

    /// Whether the host could draw the pill over the video right now. While it
    /// can't (loading, paused, controls up, dismissed), the window's time doesn't run.
    mutating func setCanAppear(_ canAppear: Bool) {
        self.canAppear = canAppear
    }

    /// Reconciles the host's hide timer. It counts only while the pill is on
    /// screen, so the 5 seconds start when the pill appears, not when its
    /// marker starts while the video is still loading. Each new window, and each
    /// return to the screen, counts afresh.
    mutating func syncTimer() -> TimerChange {
        if isOnScreen {
            guard timedWindow != window else { return .none }
            timedWindow = window
            return .start(window: window)
        }
        guard timedWindow != nil else { return .none }
        timedWindow = nil
        return .stop
    }

    /// The host's timer for `window` ran out. `held` (an auto-skip countdown
    /// is running) keeps the pill up, and the next `syncTimer()` counts again.
    mutating func timeOut(window expired: Int, held: Bool) {
        guard expired == window else { return }
        timedWindow = nil
        if !held { isShowing = false }
    }

    private mutating func openWindow() -> Bool {
        isShowing = true
        window += 1
        return true
    }
}
