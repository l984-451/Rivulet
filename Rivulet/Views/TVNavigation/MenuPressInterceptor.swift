// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MenuPressInterceptor.swift
//  Rivulet
//

import UIKit
import os

// MARK: - Handler

/// A surface that wants first refusal on the remote's Menu press.
@MainActor
protocol MenuBackHandling: AnyObject {
    /// Return true to consume the press; false to let it reach the system.
    func handleMenuBack() -> Bool
}

// MARK: - Swallow state

/// Pairs the Menu `.began` we withhold with its matching `.ended`, so the
/// system never sees half a press. Pure logic, kept out of the swizzle so it
/// can be tested directly.
struct MenuPressSwallowState {
    /// A `.began` was withheld and its terminal phase is still due. Tracked per
    /// press, so a press whose `.ended` went to another window cannot latch on
    /// and eat the next Menu press.
    private(set) var isSwallowing = false

    /// Weak, not an `ObjectIdentifier`: a new press can reuse a freed press's
    /// address and would be taken for a repeat.
    private weak var pendingPress: AnyObject?

    /// Returns true when this event must be withheld. `handle` is asked once per
    /// press on `.began`. A nil `press` counts as new: a missed swallow is
    /// recoverable, a dead Menu button is not.
    mutating func shouldWithhold(press: AnyObject?,
                                 began: Bool,
                                 finished: Bool,
                                 handle: () -> Bool) -> Bool {
        // Only a repeat of the press being swallowed skips the handlers.
        let repeatsPendingPress = isSwallowing && press != nil && press === pendingPress
        if began, !repeatsPendingPress {
            let consumed = handle()
            // A single event carrying both phases needs no follow-up swallow.
            isSwallowing = consumed && !finished
            pendingPress = isSwallowing ? press : nil
            return consumed
        }
        guard isSwallowing else { return false }
        if finished {
            isSwallowing = false
            pendingPress = nil
        }
        return true
    }
}

// MARK: - Remote gestures

/// Counts remote gestures: a new arrow press or a new touch on the remote's
/// surface. A held arrow repeats `.began` for the same press; that is not a new one.
struct RemoteGestureCounter {
    private(set) var count = 0
    private var heldArrow: AnyObject?

    mutating func observe(arrowBegan press: AnyObject?, arrowFinished: Bool, touchBegan: Bool) {
        if let press, press !== heldArrow {
            count += 1
            heldArrow = press
        }
        if arrowFinished { heldArrow = nil }
        if touchBegan { count += 1 }
    }
}

// MARK: - Policy

/// Staged Menu ("back") navigation, stage 1 (issue #19): a Menu press from
/// below the top row returns the page to its top row instead of opening the
/// sidebar.
enum StagedMenuBack {
    /// True when the press should snap the page back to its top row rather than
    /// pass through to the system's sidebar reveal.
    static func shouldReturnToTop(focusedSection: Int?, topSection: Int) -> Bool {
        guard let focusedSection else { return false }
        return focusedSection > topSection
    }
}

// MARK: - Interceptor

/// Gives the app first refusal on the Menu button by swizzling
/// `UIWindow.sendEvent(_:)`, the only layer that sees the press before any
/// responder or recognizer; returning early withholds it from the system.
@MainActor
enum MenuPressInterceptor {
    private static var swizzledClasses = Set<ObjectIdentifier>()
    private static var handlers: [WeakHandler] = []
    private static var swallowState = MenuPressSwallowState()
    /// Counted here because this hook sees each gesture before the focus engine acts on it.
    private(set) static var remoteGestures = RemoteGestureCounter()

    private struct WeakHandler {
        weak var value: (any MenuBackHandling)?
    }

    // MARK: Registration

    static func register(_ handler: any MenuBackHandling) {
        handlers.removeAll { $0.value == nil || $0.value === handler }
        handlers.append(WeakHandler(value: handler))
    }

    /// Drop a surface as it goes away. Only home is a cached controller; every
    /// library, Discover and Search page builds a fresh one, so without this the
    /// list grows by one entry per page visited. A stale entry would still
    /// decline (it checks whether it owns focus), but it would be asked first.
    static func resign(_ handler: any MenuBackHandling) {
        handlers.removeAll { $0.value == nil || $0.value === handler }
    }

    /// Offer the press to registered surfaces, most recently registered first.
    /// Each decides for itself whether it currently owns focus, so a surface
    /// sitting under a presented player or detail page declines.
    private static func offerToHandlers() -> Bool {
        for entry in handlers.reversed() {
            guard let handler = entry.value else { continue }
            if handler.handleMenuBack() { return true }
        }
        return false
    }

    // MARK: Install

    /// Swizzles `sendEvent(_:)` on the window's own class, once per class.
    /// Matches the approach already used for the sidebar focus guard: replacing
    /// on the concrete subclass leaves plain `UIWindow` untouched.
    static func install(in window: UIWindow) {
        let cls: AnyClass = type(of: window)
        guard swizzledClasses.insert(ObjectIdentifier(cls)).inserted else { return }

        let selector = #selector(UIWindow.sendEvent(_:))
        let originalIMP = class_getMethodImplementation(cls, selector)
        typealias OriginalFunc = @convention(c) (AnyObject, Selector, UIEvent) -> Void
        let originalFunc = unsafeBitCast(originalIMP, to: OriginalFunc.self)

        let block: @convention(block) (AnyObject, UIEvent) -> Void = { obj, event in
            guard let pressesEvent = event as? UIPressesEvent else {
                if event.type == .touches, event.allTouches?.contains(where: { $0.phase == .began }) == true {
                    MainActor.assumeIsolated {
                        remoteGestures.observe(arrowBegan: nil, arrowFinished: false, touchBegan: true)
                    }
                }
                originalFunc(obj, selector, event)
                return
            }
            let withhold = MainActor.assumeIsolated { () -> Bool in
                let arrows = pressesEvent.allPresses.filter {
                    [.upArrow, .downArrow, .leftArrow, .rightArrow].contains($0.type)
                }
                remoteGestures.observe(
                    arrowBegan: arrows.first { $0.phase == .began },
                    arrowFinished: arrows.contains { $0.phase == .ended || $0.phase == .cancelled },
                    touchBegan: false)

                // This is the only layer that sees a press before a responder or
                // gesture recognizer can consume it, which is exactly what the
                // input probe needs. No-ops unless Input Diagnostics is on.
                InputProbe.record(presses: pressesEvent.allPresses)

                // Withholding drops the whole event, so a non-Menu press
                // batched into the same one goes with it. The remote delivers
                // Menu on its own in practice, and there is no way to forward
                // a partial UIPressesEvent.
                let menuPresses = pressesEvent.allPresses.filter { $0.type == .menu }
                guard !menuPresses.isEmpty else { return false }
                let began = menuPresses.contains { $0.phase == .began }
                let finished = menuPresses.contains { $0.phase == .ended || $0.phase == .cancelled }
                let press = menuPresses.first
                var asked = false
                let withhold = swallowState.shouldWithhold(
                    press: press,
                    began: began,
                    finished: finished,
                    handle: { asked = true; return offerToHandlers() }
                )
                return withhold
            }
            guard !withhold else { return }
            originalFunc(obj, selector, event)
        }

        let imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        let method = class_getInstanceMethod(UIWindow.self, selector)!
        class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method)!)
    }
}
