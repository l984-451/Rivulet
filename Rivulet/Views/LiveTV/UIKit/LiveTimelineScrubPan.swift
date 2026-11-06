// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTimelineScrubPan.swift
//  Rivulet
//
//  The remote's touch surface while the live timeline holds focus. The
//  recognizer sits on the window and only observes: it never cancels touches
//  and recognizes alongside everything else, so the focus engine still moves
//  on a vertical swipe and every other surface keeps its input. The gate runs
//  in `gestureRecognizerShouldBegin`, so a pan begun while disabled never
//  reaches the host.
//

import UIKit

@MainActor
final class LiveTimelineScrubPan: NSObject, UIGestureRecognizerDelegate {

    /// Asked when a pan begins: the timeline must hold focus with a window to scrub.
    var isEnabled: () -> Bool = { false }
    var began: (() -> Void)?
    /// Translation and horizontal speed (points/sec), from the pan's start.
    var changed: ((CGPoint, Double) -> Void)?
    /// `committed` is false for a cancelled or failed pan.
    var ended: ((Bool) -> Void)?

    private var recognizer: UIPanGestureRecognizer?

    func attach(to window: UIWindow) {
        detach()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delegate = self
        window.addGestureRecognizer(pan)
        recognizer = pan
    }

    func detach() {
        recognizer.map { $0.view?.removeGestureRecognizer($0) }
        recognizer = nil
    }

    /// Ends a pan in flight (focus left the timeline): it reports as cancelled.
    func interrupt() {
        guard let recognizer, recognizer.state == .began || recognizer.state == .changed else { return }
        recognizer.isEnabled = false
        recognizer.isEnabled = true
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            began?()
        case .changed:
            changed?(gesture.translation(in: gesture.view), Double(abs(gesture.velocity(in: gesture.view).x)))
        case .ended:
            changed?(gesture.translation(in: gesture.view), Double(abs(gesture.velocity(in: gesture.view).x)))
            ended?(true)
        case .cancelled, .failed:
            ended?(false)
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { isEnabled() }
}
