// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Plex sign-in on the popup card: the plex.tv/link PIN, then the account's servers.
//  Renders `PlexAuthManager.state`; Menu cancels. `onFinish` runs after it closes.

import Combine
import CoreImage.CIFilterBuiltins
import UIKit

final class PlexSignInViewController: UIViewController {

    private let auth = PlexAuthManager.shared
    private let onFinish: () -> Void
    private let stack = UIStackView()
    private var stateObserver: AnyCancellable?
    private var shownState: PlexAuthState?
    private var focusTarget: UIView?
    private var isClosing = false

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let blur = UIVisualEffectView(effect: UIGlassEffect())
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 38
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        view.addSubview(blur)

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        let pad = PreviewCarouselGeometry.expandedChromeInset
        NSLayoutConstraint.activate([
            blur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            blur.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            blur.widthAnchor.constraint(equalToConstant: 840),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -pad),
        ])

        let menuTap = UITapGestureRecognizer(target: self, action: #selector(cancel))
        menuTap.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(menuTap)

        stateObserver = auth.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }

        if case .idle = auth.state {
            Task { await auth.startPINAuthentication() }
        } else if case .authenticated = auth.state, auth.selectedServerURL == nil {
            // Account linked but no server ever connected (#224).
            Task { await auth.resumeServerSelection() }
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [focusTarget].compactMap { $0 }
    }

    // MARK: - States

    private func render(_ state: PlexAuthState, force: Bool = false) {
        guard !isClosing, force || state != shownState else { return }
        // The manager clears an error to idle after 5s; keep it up so Try Again stays reachable.
        if case .idle = state, case .error = shownState { return }
        shownState = state

        switch state {
        case .idle:
            showLoading(String(localized: "Connecting to Plex…"))
        case .requestingPin:
            showLoading(String(localized: "Requesting PIN…"))
        case .waitingForPIN(let code, _):
            showPIN(code)
        case .selectingServer(let servers):
            showServers(servers)
        case .authenticated where auth.selectedServerURL == nil:
            showLoading(String(localized: "Loading Servers…"))
        case .authenticated:
            showConnected()
        case .error(let message):
            showError(message)
        }
    }

    private func showLoading(_ message: String) {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        setContent([spinner, label(message, size: 26, color: .secondaryText)], focus: nil)
    }

    /// Two ways in, side by side: a QR code the phone's camera opens on plex.tv/link
    /// with the code filled in, or the page's address and the code to type there.
    private func showPIN(_ code: String) {
        let scan = UIStackView(arrangedSubviews: [
            qrTile(PlexAuthManager.linkURL(code: code).absoluteString),
            label(String(localized: "Scan with your phone"), size: 22, color: .secondaryText),
        ])
        scan.axis = .vertical
        scan.alignment = .center
        scan.spacing = 14

        let boxes = UIStackView(arrangedSubviews: code.map { codeBox(String($0)) })
        boxes.axis = .horizontal
        boxes.spacing = 14
        let typed = UIStackView(arrangedSubviews: [
            label(String(localized: "or visit"), size: 26, color: .secondaryText),
            label("plex.tv/link", size: 40, weight: .bold),
            label(String(localized: "and enter this code:"), size: 26, color: .secondaryText),
            boxes,
        ])
        typed.axis = .vertical
        typed.alignment = .center
        typed.spacing = 4
        typed.setCustomSpacing(20, after: typed.arrangedSubviews[2])

        let ways = UIStackView(arrangedSubviews: [scan, typed])
        ways.axis = .horizontal
        ways.alignment = .center
        ways.spacing = 64
        let waysRow = UIStackView(arrangedSubviews: [ways])
        waysRow.axis = .vertical
        waysRow.alignment = .center

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = .white
        spinner.startAnimating()
        let waiting = UIStackView(arrangedSubviews: [spinner, label(String(localized: "Waiting for you to sign in…"), size: 22, color: .secondaryText)])
        waiting.spacing = 12
        let waitingRow = UIStackView(arrangedSubviews: [waiting])
        waitingRow.axis = .vertical
        waitingRow.alignment = .center

        let cancel = button(String(localized: "Cancel")) { [weak self] in self?.cancel() }
        setContent([waysRow, waitingRow, cancel], focus: cancel)
        stack.setCustomSpacing(36, after: waysRow)
        stack.setCustomSpacing(36, after: waitingRow)
    }

    /// Every server starts checked unless turned off before; Continue connects the first
    /// checked one and turns the unchecked ones off (`PlexExtraServers`).
    private func showServers(_ servers: [PlexDevice]) {
        let extra = PlexExtraServers.shared
        var chosen = Set(servers.compactMap(\.machineIdentifier).filter { extra.isEnabled(machineID: $0) })
        if chosen.isEmpty, let first = servers.first?.machineIdentifier { chosen.insert(first) }

        var rows: [PopupPillButton] = []
        func title(_ server: PlexDevice) -> NSAttributedString {
            let on = server.machineIdentifier.map(chosen.contains) ?? false
            let text = NSMutableAttributedString(attachment: NSTextAttachment(
                image: UIImage(systemName: on ? "checkmark.circle.fill" : "circle")!))
            let name = server.owned == false ? "\(server.name) · \(server.sourceTitle ?? String(localized: "Shared"))" : server.name
            text.append(NSAttributedString(string: "  \(name)"))
            return text
        }
        for (index, server) in servers.enumerated() {
            let row = button("") {
                guard let id = server.machineIdentifier else { return }
                if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
                rows[index].setTitle(title(server))
            }
            row.setTitle(title(server))
            rows.append(row)
        }
        let list = UIStackView(arrangedSubviews: rows)
        list.axis = .vertical
        list.spacing = 16
        list.translatesAutoresizingMaskIntoConstraints = false

        // Scrolls past four servers. Clipping only then, so a focused row's lift shows.
        let scroll = UIScrollView()
        scroll.clipsToBounds = servers.count > 4
        scroll.addSubview(list)
        let rowHeight: CGFloat = 64
        let inset: CGFloat = 12
        let visible = CGFloat(min(servers.count, 4))
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: inset),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -inset),
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: visible * rowHeight + (visible - 1) * list.spacing + inset * 2),
        ] + rows.map { $0.heightAnchor.constraint(equalToConstant: rowHeight) })

        let cancel = button(String(localized: "Cancel")) { [weak self] in self?.cancel() }
        let next = button(String(localized: "Continue")) { [weak self] in
            guard let primary = servers.first(where: { $0.machineIdentifier.map(chosen.contains) ?? false }) else { return }
            self?.connect(to: primary) {
                for id in servers.compactMap(\.machineIdentifier) where extra.isEnabled(machineID: id) != chosen.contains(id) {
                    extra.setEnabled(chosen.contains(id), machineID: id)
                }
            }
        }
        let buttons = UIStackView(arrangedSubviews: [cancel, next])
        buttons.distribution = .fillEqually
        buttons.spacing = 24
        setContent([label(String(localized: "Select Your Servers"), size: 34, weight: .bold), scroll, buttons], focus: rows.first)
        stack.setCustomSpacing(24, after: scroll)
    }

    private func showConnected() {
        var views = [label(String(localized: "Connected"), size: 34, weight: .bold)]
        if let name = auth.savedServerName {
            views.append(label(String(localized: "Connected to \(name)"), size: 24, color: .secondaryText))
        }
        if let username = auth.username {
            views.append(label(String(localized: "Signed in as \(username)"), size: 24, color: .secondaryText))
        }
        setContent(views, focus: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close() }
    }

    private func showError(_ message: String) {
        let retry = button(String(localized: "Try Again")) { [weak self] in
            // Skips the PIN step when the account is already linked.
            Task { await self?.auth.retryAfterError() }
        }
        let unlink = button(String(localized: "Unlink Account")) { [weak self] in
            self?.auth.signOut()
            Task { await self?.auth.startPINAuthentication() }
        }
        let buttons = UIStackView(arrangedSubviews: [unlink, retry])
        buttons.distribution = .fillEqually
        buttons.spacing = 24
        buttons.heightAnchor.constraint(equalToConstant: 72).isActive = true
        setContent([label(String(localized: "Connection Failed"), size: 34, weight: .bold),
                    label(message, size: 24, color: .secondaryText), buttons], focus: retry)
        stack.setCustomSpacing(36, after: stack.arrangedSubviews[1])
    }

    // MARK: - Actions

    private func connect(to server: PlexDevice, onConnected: @escaping () -> Void = {}) {
        shownState = nil
        showLoading(String(localized: "Connecting to \(server.name)…"))
        Task {
            let connected = await auth.selectServer(server)
            // A failed switch away from a working server leaves the state on the list.
            if connected { onConnected() } else { render(auth.state, force: true) }
        }
    }

    @objc private func cancel() {
        // Closing on success must not undo the sign-in.
        if !(auth.state == .authenticated && auth.selectedServerURL != nil) { auth.reset() }
        close()
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        dismiss(animated: true) { [onFinish] in onFinish() }
    }

    // MARK: - Building

    private func setContent(_ views: [UIView], focus: UIView?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(stack.addArrangedSubview)
        focusTarget = focus
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func button(_ title: String, action: @escaping () -> Void) -> PopupPillButton {
        PopupPillButton(title: title, destructive: false, onPress: action)
    }

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
                       color: UIColor = .white) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    /// Black modules on a white tile, the contrast a phone camera reads from a TV.
    private func qrTile(_ text: String) -> UIView {
        let tile = UIView()
        tile.backgroundColor = .white
        tile.layer.cornerRadius = 16
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false
        let code = UIImageView(image: QRCodeImage.make(text, side: 200, scale: traitCollection.displayScale))
        code.contentMode = .center
        code.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(code)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 232),
            tile.heightAnchor.constraint(equalToConstant: 232),
            code.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            code.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    private func codeBox(_ character: String) -> UIView {
        let box = UILabel()
        box.text = character
        box.font = .monospacedSystemFont(ofSize: 52, weight: .bold)
        box.textColor = .white
        box.textAlignment = .center
        box.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        box.layer.cornerRadius = 12
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([box.widthAnchor.constraint(equalToConstant: 64),
                                     box.heightAnchor.constraint(equalToConstant: 80)])
        return box
    }
}

private extension UIColor {
    static let secondaryText = UIColor.white.withAlphaComponent(0.7)
}

/// A QR code from CoreImage's generator, scaled by a whole number with nearest
/// sampling so every module lands on pixels. The generator's extent includes a
/// one-module quiet zone, so the image is at most `side` across.
enum QRCodeImage {
    static func make(_ text: String, side: CGFloat, scale: CGFloat) -> UIImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(text.utf8)
        generator.correctionLevel = "M"
        guard let code = generator.outputImage else { return nil }
        let factor = floor(side * scale / code.extent.width)
        let scaled = code.samplingNearest().transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}
