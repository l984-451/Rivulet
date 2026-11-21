// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

/// Trims what the poster-to-detail zoom draws while it runs, for the page it is attached to.
///
/// The zoom morphs through a window-level container that puts a full-screen Liquid Glass layer
/// and a 40 pt shadow with no path behind the moving card. The card is opaque, so neither
/// shows (checked frame by frame in light and dark), yet each is a full-screen offscreen pass
/// on every frame. On an iPad Pro (M2) a zoom-in took about 26 ms of GPU per frame with them
/// and 9.5 ms without, against the 8.3 ms a 120 Hz frame allows. UIKit has no option for
/// either, so this hides both from the start of the page's push or pop until the morph is
/// gone, the edge swipe included. It also blocks taps while the morph is up. The class names
/// are private: if iOS renames them, this finds nothing and the zoom draws as before.
struct IOSZoomMorphTrimmer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private weak var session: MorphTrimSession?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            trimTransition(pushing: true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            trimTransition(pushing: false)
        }

        /// The page's controller in the navigation stack.
        private var page: UIViewController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController, controller.parent is UINavigationController {
                    return controller
                }
                responder = current.next
            }
            return nil
        }

        /// Only this page's own push or pop, the other side a page of the same stack: a sheet or
        /// the player has its own animation. (NavigationStack leaves `isMovingToParent` false.)
        private func trimTransition(pushing: Bool) {
            guard session == nil, let window = view.window, let page, let navigation = page.navigationController,
                  let coordinator = page.transitionCoordinator,
                  coordinator.viewController(forKey: pushing ? .to : .from) === page,
                  coordinator.viewController(forKey: pushing ? .from : .to)?.navigationController === navigation
            else { return }
            let session = MorphTrimSession(window: window)
            self.session = session
            // Also inside the transition's own animation block, so the first frame is drawn trimmed.
            coordinator.animate(alongsideTransition: { _ in session.trimMorphs() }) { _ in session.transitionEnded() }
        }
    }
}

/// Trims every frame from the start of a transition until the window has no morph left. A
/// released swipe can end the transition before the card has flown back to its tile, so a
/// session outlives both the transition and the page; its display link holds it until then.
@MainActor
private final class MorphTrimSession: NSObject {
    private weak var window: UIWindow?
    private var link: CADisplayLink?
    private let started = CACurrentMediaTime()
    private var ended: CFTimeInterval?
    private var framesWithoutMorph = 0
    /// Over the window while a morph is up: the morph lets taps through to the pages under it,
    /// so a tap during the zoom opened a tile or pressed a button mid-flight. A drag already
    /// under way is unaffected; its touches stay with the view they began on.
    private var shield: UIView?

    init(window: UIWindow) {
        self.window = window
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func transitionEnded() {
        ended = CACurrentMediaTime()
    }

    /// Trims every morph in the window; false when there is none.
    @discardableResult
    func trimMorphs() -> Bool {
        var found = false
        for container in window?.subviews ?? [] where Self.role(of: container) == .container {
            found = true
            Self.trim(container.layer)
        }
        return found
    }

    @objc private func tick() {
        framesWithoutMorph = trimMorphs() ? 0 : framesWithoutMorph + 1
        if framesWithoutMorph == 0, shield == nil, let window {
            let shield = UIView(frame: window.bounds)
            shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(shield)
            self.shield = shield
        } else if framesWithoutMorph > 0 {
            removeShield()
        }
        let now = CACurrentMediaTime()
        // Half a second past the transition with no morph for a few frames: the card has landed.
        let landed = ended.map { now - $0 > 0.5 && framesWithoutMorph > 6 } ?? false
        if landed || now - started > 3 || window == nil {
            removeShield()
            link?.invalidate()
            link = nil
        }
    }

    private func removeShield() {
        shield?.removeFromSuperview()
        shield = nil
    }

    private static func trim(_ layer: CALayer) {
        if let owner = layer.delegate {
            switch role(of: owner) {
            case .glass: layer.isHidden = true
            case .morph where layer.shadowOpacity > 0: layer.shadowOpacity = 0
            default: break
            }
        }
        for sublayer in layer.sublayers ?? [] { trim(sublayer) }
    }

    private enum Role { case container, glass, morph, other }

    /// Each class is named once, then looked up: this runs for every layer on every frame.
    private static var roles: [ObjectIdentifier: Role] = [:]

    private static func role(of object: AnyObject) -> Role {
        let type = ObjectIdentifier(Swift.type(of: object))
        if let known = roles[type] { return known }
        let name = String(describing: Swift.type(of: object))
        let role: Role = name.contains("MorphAnimationContainer") ? .container
            : name.contains("GlassGroupView") ? .glass
            : name.contains("MagicMorphView") ? .morph
            : .other
        roles[type] = role
        return role
    }
}
