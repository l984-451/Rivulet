// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MenuPressInterceptor.swift
//  Rivulet
//

import UIKit

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
    private(set) var isSwallowing = false

    /// - Parameters:
    ///   - began: the event carries a Menu press in the `.began` phase.
    ///   - finished: the event carries a Menu press in `.ended` or `.cancelled`.
    ///   - handle: asked once per press, on `.began`. True means consumed.
    /// - Returns: true when this event must be withheld from the system.
    mutating func shouldWithhold(began: Bool, finished: Bool, handle: () -> Bool) -> Bool {
        // A second `.began` arriving before the first press ends must not
        // re-ask the handler or overwrite the pending press — the press being
        // swallowed owns the state until its own terminal phase.
        if began, !isSwallowing {
            let consumed = handle()
            // A single event carrying both phases needs no follow-up swallow.
            isSwallowing = consumed && !finished
            return consumed
        }
        guard isSwallowing else { return false }
        if finished { isSwallowing = false }
        return true
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

/// Gives the app first refusal on the Menu button.
///
/// While focus is in the content area, a Menu press is **not** delivered
/// through the responder chain: there is no `pressesBegan` on the window or the
/// focused view controller, no `shouldUpdateFocus`, no `.onExitCommand`, and no
/// menu-press gesture recognizer anywhere in the hierarchy to intercept — the
/// `.sidebarAdaptable` sidebar reveal happens above all of it. The one layer
/// that sees the press first is `UIWindow.sendEvent(_:)`; returning early there
/// withholds it from the system entirely. (Measured on tvOS 26.5; once focus is
/// in the sidebar the press does reach the responder chain and `.onExitCommand`,
/// which is how stage 3 works — see `TVSidebarView.onExitCommand`.)
@MainActor
enum MenuPressInterceptor {
    private static var swizzledClasses = Set<ObjectIdentifier>()
    private static var handlers: [WeakHandler] = []
    private static var swallowState = MenuPressSwallowState()

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
            if entry.value?.handleMenuBack() == true { return true }
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
                originalFunc(obj, selector, event)
                return
            }
            let withhold = MainActor.assumeIsolated { () -> Bool in
                // Withholding drops the whole event, so a non-Menu press
                // batched into the same one goes with it. The remote delivers
                // Menu on its own in practice, and there is no way to forward
                // a partial UIPressesEvent.
                let menuPresses = pressesEvent.allPresses.filter { $0.type == .menu }
                guard !menuPresses.isEmpty else { return false }
                return swallowState.shouldWithhold(
                    began: menuPresses.contains { $0.phase == .began },
                    finished: menuPresses.contains { $0.phase == .ended || $0.phase == .cancelled },
                    handle: offerToHandlers
                )
            }
            guard !withhold else { return }
            originalFunc(obj, selector, event)
        }

        let imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
        let method = class_getInstanceMethod(UIWindow.self, selector)!
        class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method)!)
    }
}
