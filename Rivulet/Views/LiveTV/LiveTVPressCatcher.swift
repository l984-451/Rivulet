// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVPressCatcher.swift
//  Rivulet
//
//  UIKit press-catcher used as a fallback path for IR directional remotes.
//

import SwiftUI

import UIKit

struct LiveTVPressCatcher: UIViewControllerRepresentable {
    var onAction: (PlaybackInputAction) -> Void

    func makeUIViewController(context: Context) -> LiveTVPressCatcherController {
        let controller = LiveTVPressCatcherController()
        controller.onAction = onAction
        return controller
    }

    func updateUIViewController(_ uiViewController: LiveTVPressCatcherController, context: Context) {
        uiViewController.onAction = onAction
    }
}

final class LiveTVPressCatcherController: UIViewController {
    var onAction: ((PlaybackInputAction) -> Void)?

    private var leftTap: UITapGestureRecognizer?
    private var rightTap: UITapGestureRecognizer?
    private var leftLong: UILongPressGestureRecognizer?
    private var rightLong: UILongPressGestureRecognizer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        setupDirectionalGestures()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            onAction?(.back)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private func setupDirectionalGestures() {
        let leftTap = UITapGestureRecognizer(target: self, action: #selector(handleLeftTap))
        leftTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        view.addGestureRecognizer(leftTap)
        self.leftTap = leftTap

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleRightTap))
        rightTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        view.addGestureRecognizer(rightTap)
        self.rightTap = rightTap

        let leftLong = UILongPressGestureRecognizer(target: self, action: #selector(handleLeftLong(_:)))
        leftLong.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        leftLong.minimumPressDuration = InputConfig.holdThreshold
        view.addGestureRecognizer(leftLong)
        self.leftLong = leftLong

        let rightLong = UILongPressGestureRecognizer(target: self, action: #selector(handleRightLong(_:)))
        rightLong.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        rightLong.minimumPressDuration = InputConfig.holdThreshold
        view.addGestureRecognizer(rightLong)
        self.rightLong = rightLong

        leftTap.require(toFail: leftLong)
        rightTap.require(toFail: rightLong)
    }

    @objc private func handleLeftTap() {
        onAction?(.stepSeek(forward: false))
    }

    @objc private func handleRightTap() {
        onAction?(.stepSeek(forward: true))
    }

    @objc private func handleLeftLong(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            onAction?(.scrubNudge(forward: false))
        }
    }

    @objc private func handleRightLong(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            onAction?(.scrubNudge(forward: true))
        }
    }
}
