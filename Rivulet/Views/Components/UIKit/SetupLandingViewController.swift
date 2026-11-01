// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  First-run landing: one card each for Plex, Jellyfin and Live TV, each opening
//  its own setup flow. A finished card shows a check, and Start Watching appears
//  once any source is connected.

import Combine
import UIKit

final class SetupLandingViewController: UIViewController {

    /// Plex, Jellyfin, or a Live TV source the user added (not one that follows a server).
    static var hasAnySource: Bool {
        PlexAuthManager.shared.hasCredentials || JellyfinSession.account != nil || !addedLiveTVSources.isEmpty
    }

    private static var addedLiveTVSources: [LiveTVDataStore.LiveTVSourceInfo] {
        LiveTVDataStore.shared.sources.filter { !$0.sourceType.followsServer }
    }

    var onDone: (() -> Void)?

    private let plexCard = SetupLandingViewController.makeCard(title: "Plex", symbol: "play.rectangle.fill")
    private let jellyfinCard = SetupLandingViewController.makeCard(title: "Jellyfin", symbol: "server.rack")
    private let liveTVCard = SetupLandingViewController.makeCard(title: "Live TV",
                                                                 symbol: "antenna.radiowaves.left.and.right")
    private let doneButton = UIButton(configuration: .glass())
    private var sourcesObserver: AnyCancellable?
    private let doneGuide = UIFocusGuide()

    override func viewDidLoad() {
        super.viewDidLoad()
        let glow = WelcomeGlowView(frame: view.bounds)
        glow.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(glow)

        let title = UILabel()
        title.text = "Welcome to Rivulet"
        title.font = .systemFont(ofSize: 57, weight: .bold)
        title.textColor = .white
        let subtitle = UILabel()
        subtitle.text = "Connect your media and Live TV to get started."
        subtitle.font = .systemFont(ofSize: 29)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.7)

        plexCard.addAction(UIAction { [weak self] _ in self?.connectPlex() }, for: .primaryActionTriggered)
        jellyfinCard.addAction(UIAction { [weak self] _ in self?.connectJellyfin() }, for: .primaryActionTriggered)
        liveTVCard.addAction(UIAction { [weak self] _ in self?.addLiveTV() }, for: .primaryActionTriggered)
        let cards = UIStackView(arrangedSubviews: [plexCard, jellyfinCard, liveTVCard])
        cards.spacing = 48

        doneButton.configuration?.title = "Start Watching"
        doneButton.configuration?.attributedTitle?.font = .systemFont(ofSize: 29, weight: .semibold)
        doneButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 56, bottom: 18, trailing: 56)
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [title, subtitle, cards, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(64, after: subtitle)
        stack.setCustomSpacing(64, after: cards)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        // Down from any card reaches Start Watching, not just the card above it.
        view.addLayoutGuide(doneGuide)
        doneGuide.preferredFocusEnvironments = [doneButton]
        NSLayoutConstraint.activate([
            doneGuide.topAnchor.constraint(equalTo: cards.bottomAnchor),
            doneGuide.bottomAnchor.constraint(equalTo: doneButton.topAnchor),
            doneGuide.leadingAnchor.constraint(equalTo: cards.leadingAnchor),
            doneGuide.trailingAnchor.constraint(equalTo: cards.trailingAnchor)
        ])

        // A server's own Live TV arrives after its sign-in, and the cards follow it.
        sourcesObserver = LiveTVDataStore.shared.$sources
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Arriving, focus starts on the first card; Start Watching takes it only after a flow just connected something.
    private var focusesDone = false

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        focusesDone && doneButton.isEnabled ? [doneButton] : [plexCard]
    }

    /// The guide sits between the cards and the button, so it points away from whichever side has focus:
    /// down to Start Watching, or up to the card focus came from.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === doneButton {
            doneGuide.preferredFocusEnvironments = [(context.previouslyFocusedView as? UIButton) ?? jellyfinCard]
        } else if context.nextFocusedView is UIButton {
            doneGuide.preferredFocusEnvironments = [doneButton]
        }
    }

    // MARK: - Flows

    private func connectPlex() {
        // Connected: the Settings page, with the servers and Sign Out (a wrong account).
        if PlexAuthManager.shared.isAuthenticated { presentSettingsFlow(.plex); return }
        present(PlexSignInViewController { [weak self] in self?.flowFinished() }, animated: true)
    }

    /// The Settings page signs in, or shows the server and Sign Out.
    private func connectJellyfin() {
        SettingsContent.addSourceDraft = AddSourceDraft()
        presentSettingsFlow(.jellyfin)
    }

    /// Selectable again once checked: Live TV takes more than one source.
    private func addLiveTV() {
        presentSettingsFlow(.addLiveTVSource)
    }

    /// The Settings pages themselves, standalone: their first page's Menu or finish closes them.
    private func presentSettingsFlow(_ page: SettingsPage) {
        let flow = SettingsContainerViewController(rootPage: page)
        flow.onExit = { [weak self, weak flow] in
            flow?.dismiss(animated: true) { self?.flowFinished() }
        }
        // Over the landing, dimmed and blurred, so the glow stays behind the form.
        flow.drawsBackdrop = false
        flow.modalPresentationStyle = .overFullScreen
        flow.transitioningDelegate = SetupFadeTransition.shared
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        blur.frame = flow.view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        flow.view.insertSubview(blur, at: 0)
        present(flow, animated: true)
    }

    private func flowFinished() {
        let wasEnabled = doneButton.isEnabled
        refresh()
        focusesDone = !wasEnabled && doneButton.isEnabled
        // Otherwise focus returns to the card that opened the flow.
        guard focusesDone else { return }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    // MARK: - State

    private func refresh() {
        let auth = PlexAuthManager.shared
        let plexServers = auth.isAuthenticated ? 1 + PlexExtraServers.shared.current.count : 0
        Self.setDone(plexCard, prompt: "Sign In", detail: plexServers > 1 ? "\(plexServers) Servers"
                     : plexServers == 1 ? auth.savedServerName ?? "Connected" : nil)
        Self.setDone(jellyfinCard, prompt: "Sign In", detail: JellyfinSession.account?.serverName)
        let added = Self.addedLiveTVSources
        Self.setDone(liveTVCard, prompt: "Add a Source", detail: added.isEmpty ? nil
                     : added.count == 1 ? added[0].displayName : "\(added.count) Sources")
        // Held in place while hidden, so nothing moves when it appears.
        doneButton.isEnabled = Self.hasAnySource
        doneButton.alpha = doneButton.isEnabled ? 1 : 0
        doneGuide.isEnabled = doneButton.isEnabled
    }

    private static func makeCard(title: String, symbol: String) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: symbol,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .regular))
        config.imagePlacement = .top
        config.imagePadding = 24
        config.titleAlignment = .center
        config.title = title
        config.attributedTitle?.font = .systemFont(ofSize: 34, weight: .semibold)
        config.background.cornerRadius = cardRadius
        config.cornerStyle = .fixed
        let card = UIButton(configuration: config)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 400),
            card.heightAnchor.constraint(equalToConstant: 300)
        ])
        let gradient = SetupCardGradientView()
        gradient.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        gradient.layer.cornerRadius = cardRadius
        gradient.alpha = 0
        // Under the glass, which takes its colour.
        card.insertSubview(gradient, at: 0)
        return card
    }

    private static let cardRadius: CGFloat = 32

    /// A connected card shows its gradient and names what it connected to.
    private static func setDone(_ card: UIButton, prompt: String, detail: String?) {
        guard var config = card.configuration else { return }
        var subtitle = AttributedString(detail.map { "✓ \($0)" } ?? prompt)
        subtitle.font = .systemFont(ofSize: 25, weight: .medium)
        config.attributedSubtitle = subtitle
        card.configuration = config
        let gradient = card.subviews.first { $0 is SetupCardGradientView }
        UIView.animate(withDuration: 0.4) { gradient?.alpha = detail == nil ? 0 : 1 }
    }
}

/// The welcome glow's four colours across a connected card.
private final class SetupCardGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor(red: 0.30, green: 0.85, blue: 0.95, alpha: 1),
            UIColor(red: 0.55, green: 0.42, blue: 1.00, alpha: 1),
            UIColor(red: 1.00, green: 0.45, blue: 0.72, alpha: 1),
            UIColor(red: 1.00, green: 0.78, blue: 0.42, alpha: 1)
        ].map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A slow cross-dissolve both ways, for the setup flows.
private final class SetupFadeTransition: NSObject, UIViewControllerTransitioningDelegate,
                                         UIViewControllerAnimatedTransitioning {
    static let shared = SetupFadeTransition()

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? { self }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? { self }

    func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval { 0.6 }

    func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let presenting = ctx.view(forKey: .to) != nil
        guard let view = ctx.view(forKey: presenting ? .to : .from) else {
            ctx.completeTransition(true)
            return
        }
        if presenting {
            view.frame = ctx.containerView.bounds
            view.alpha = 0
            ctx.containerView.addSubview(view)
        }
        UIView.animate(withDuration: transitionDuration(using: ctx), delay: 0, options: .curveEaseInOut) {
            view.alpha = presenting ? 1 : 0
        } completion: { _ in
            ctx.completeTransition(!ctx.transitionWasCancelled)
        }
    }
}
