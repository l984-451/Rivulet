// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Gives a focusless surface both remote transports for directional input:
// arrow-press taps (and optional holds) plus `.indirect` swipes, funneled into one callback.
// Focusless surfaces only: a swipe that begins cancels the focus engine's move.
// See CLAUDE.md, "Remote Input".

import UIKit

@MainActor
final class DirectionalInputBinding: NSObject {

    enum Direction: CaseIterable {
        case up, down, left, right

        var pressType: UIPress.PressType {
            switch self {
            case .up: return .upArrow
            case .down: return .downArrow
            case .left: return .leftArrow
            case .right: return .rightArrow
            }
        }

        var swipeDirection: UISwipeGestureRecognizer.Direction {
            switch self {
            case .up: return .up
            case .down: return .down
            case .left: return .left
            case .right: return .right
            }
        }
    }

    /// Arrow-press tap OR indirect-touch swipe in this direction.
    private let onTap: (Direction) -> Void
    /// Takes the swipes from `onTap` when set, for a surface whose swipe means
    /// something other than its click. Reachable only from a touch remote, so
    /// whatever it opens needs another way in for press-only remotes.
    private let onSwipe: ((Direction) -> Void)?
    /// Arrow press held past `InputConfig.holdThreshold` (press path only —
    /// a touch surface expresses "hold" as repeated swipes instead).
    private let onHold: ((Direction) -> Void)?
    /// A held arrow press let go, or cancelled.
    private let onHoldEnd: ((Direction) -> Void)?
    /// Gate for the swipes, consulted in `gestureRecognizerShouldBegin`. nil on
    /// a focusless binding without a `swipeGate`, whose swipes are claimed
    /// unconditionally.
    private let shouldHandle: ((Direction) -> Bool)?

    private var directionByRecognizer: [ObjectIdentifier: Direction] = [:]

    /// Directions in `holds` also get a long press (`onHold`, `onHoldEnd`); their taps
    /// fire only on a release before the threshold. Keep the binding alive with the view.
    init(
        view: UIView,
        directions: [Direction],
        holds: [Direction] = [],
        onTap: @escaping (Direction) -> Void,
        onHold: ((Direction) -> Void)? = nil,
        onHoldEnd: ((Direction) -> Void)? = nil,
        swipeGate: ((Direction) -> Bool)? = nil,
        onSwipe: ((Direction) -> Void)? = nil
    ) {
        self.onTap = onTap
        self.onSwipe = onSwipe
        self.onHold = onHold
        self.onHoldEnd = onHoldEnd
        self.shouldHandle = swipeGate
        super.init()

        for direction in directions {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.allowedPressTypes = [NSNumber(value: direction.pressType.rawValue)]
            view.addGestureRecognizer(tap)
            directionByRecognizer[ObjectIdentifier(tap)] = direction

            if holds.contains(direction) {
                let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLong(_:)))
                long.allowedPressTypes = [NSNumber(value: direction.pressType.rawValue)]
                long.minimumPressDuration = InputConfig.holdThreshold
                view.addGestureRecognizer(long)
                directionByRecognizer[ObjectIdentifier(long)] = direction
                tap.require(toFail: long)
            }

            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction.swipeDirection
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            swipe.allowedPressTypes = []
            if swipeGate != nil { swipe.delegate = self }
            view.addGestureRecognizer(swipe)
            directionByRecognizer[ObjectIdentifier(swipe)] = direction
        }
    }

    /// Swipe-only variant for a focusable surface whose presses go through a
    /// `pressesBegan` override. `shouldHandle` runs before the swipe begins and must
    /// claim only the moves the focus engine cannot make (reuse the press predicate).
    init(
        gatedSwipesOn view: UIView,
        directions: [Direction],
        shouldHandle: @escaping (Direction) -> Bool,
        onSwipe: @escaping (Direction) -> Void
    ) {
        self.onTap = onSwipe
        self.onSwipe = nil
        self.onHold = nil
        self.onHoldEnd = nil
        self.shouldHandle = shouldHandle
        super.init()

        for direction in directions {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction.swipeDirection
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            swipe.allowedPressTypes = []
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
            directionByRecognizer[ObjectIdentifier(swipe)] = direction
        }
    }

    /// The direction a recognizer installed by this binding serves.
    func direction(of recognizer: UIGestureRecognizer) -> Direction? {
        directionByRecognizer[ObjectIdentifier(recognizer)]
    }

    @objc func handleTap(_ recognizer: UIGestureRecognizer) {
        guard let direction = direction(of: recognizer) else { return }
        onTap(direction)
    }

    @objc func handleSwipe(_ recognizer: UIGestureRecognizer) {
        guard let direction = direction(of: recognizer) else { return }
        (onSwipe ?? onTap)(direction)
    }

    @objc func handleLong(_ recognizer: UIGestureRecognizer) {
        guard let direction = direction(of: recognizer) else { return }
        hold(direction, recognizer.state)
    }

    /// A held arrow at `state`: begun, or let go.
    func hold(_ direction: Direction, _ state: UIGestureRecognizer.State) {
        switch state {
        case .began: onHold?(direction)
        case .ended, .cancelled: onHoldEnd?(direction)
        default: break
        }
    }
}

extension DirectionalInputBinding: UIGestureRecognizerDelegate {
    /// Gated swipes only (an ungated focusless binding sets no delegate).
    /// Declining here, before the recognizer begins, is what leaves the
    /// swipe to the focus engine — bailing in the handler would be too late.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let shouldHandle, let direction = direction(of: gestureRecognizer) else { return true }
        return shouldHandle(direction)
    }
}
