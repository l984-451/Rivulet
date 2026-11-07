// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import UIKit

extension HostPlatform {
    /// UIKit's answers for the shared stores; call first thing at launch.
    static func installUIKit() {
        willEnterForeground = UIApplication.willEnterForegroundNotification
        appearanceChangeNotifications = [
            UIAccessibility.videoAutoplayStatusDidChangeNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification
        ]
        isForeground = { UIApplication.shared.applicationState == .active }
        allowsVideoPreviews = { UIAccessibility.isVideoAutoplayEnabled && !UIAccessibility.isReduceMotionEnabled }
        alternateIconName = { UIApplication.shared.alternateIconName }
        setAlternateIconName = { UIApplication.shared.setAlternateIconName($0) }
    }
}

extension ThemeBackdrop {
    /// True when `host`, or any controller above it, has something presented over it.
    static func isCovered(_ host: UIViewController?) -> Bool {
        var controller = host
        while let current = controller {
            if current.presentedViewController != nil || current.isBeingDismissed { return true }
            controller = current.parent
        }
        return false
    }
}

extension CaptionStyle {
    /// The default style keeps UIKit's own medium system face; a user font descriptor goes through CoreText.
    func uiFont(ofSize size: CGFloat) -> UIFont {
        fontDescriptor == nil ? .systemFont(ofSize: size, weight: .medium) : font(ofSize: size) as UIFont
    }
}
