// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreImage
import UIKit

@MainActor
final class SiloDeviceSignInViewController: UIViewController {
    var onApproved: (([SiloProfile]) -> Void)?
    private let serverURL: URL
    private var task: Task<Void, Never>?
    private var completed = false
    private let status = UILabel()
    private let code = UILabel()
    private let address = UILabel()
    private let expiry = UILabel()
    private let qr = UIImageView()
    private let restart = UIButton(type: .system)
    private var expiryTimer: Timer?
    private var deadline: Date?

    init(serverURL: URL) {
        self.serverURL = serverURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let title = UILabel()
        title.text = "Sign In with Your Phone"
        title.font = .preferredFont(forTextStyle: .title1)
        title.textAlignment = .center
        title.numberOfLines = 0
        status.text = "Requesting a sign in code…"
        status.textAlignment = .center
        status.numberOfLines = 0
        code.font = .monospacedDigitSystemFont(ofSize: 38, weight: .bold)
        code.textAlignment = .center
        address.font = .preferredFont(forTextStyle: .body)
        address.textAlignment = .center
        address.numberOfLines = 0
        expiry.font = .preferredFont(forTextStyle: .body)
        expiry.textAlignment = .center
        expiry.numberOfLines = 0
        qr.contentMode = .scaleAspectFit
        qr.backgroundColor = .white
        qr.layer.magnificationFilter = .nearest
        restart.setTitle("Request New Code", for: .normal)
        restart.addTarget(self, action: #selector(start), for: .primaryActionTriggered)
        restart.isHidden = true
        let password = UIButton(type: .system)
        password.setTitle("Use Password Instead", for: .normal)
        password.addTarget(self, action: #selector(close), for: .primaryActionTriggered)
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(close), for: .primaryActionTriggered)
        let actions = UIStackView(arrangedSubviews: [restart, password, cancel])
        actions.axis = .horizontal
        actions.alignment = .center
        actions.distribution = .equalSpacing
        actions.spacing = 30
        let stack = UIStackView(arrangedSubviews: [title, status, qr, code, address, expiry, actions])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsetAdjustmentBehavior = .never
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let safe = view.safeAreaLayoutGuide
        let preferredQRWidth = qr.widthAnchor.constraint(equalToConstant: 300)
        preferredQRWidth.priority = .defaultHigh
        let preferredContentWidth = stack.widthAnchor.constraint(equalToConstant: 900)
        preferredContentWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -100),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
            preferredContentWidth,
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            address.widthAnchor.constraint(equalTo: stack.widthAnchor),
            expiry.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            preferredQRWidth,
            qr.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, multiplier: 0.6),
            qr.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor, multiplier: 0.34),
            qr.heightAnchor.constraint(equalTo: qr.widthAnchor)
        ])
        start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !completed { stop() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) { close() }
        else { super.pressesBegan(presses, with: event) }
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func start() {
        stop()
        restart.isHidden = true
        expiryTimer?.invalidate()
        deadline = nil
        expiry.text = nil
        qr.image = nil
        code.text = nil
        address.text = nil
        status.text = "Requesting a sign in code…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let started = try await SiloSession.startDeviceSignIn(serverURL: serverURL)
                try Task.checkCancellation()
                code.text = started.userCode.replacingOccurrences(of: "-", with: " ")
                address.text = "On your phone, visit \(started.verificationUri) and enter the code."
                deadline = Date().addingTimeInterval(TimeInterval(started.expiresIn))
                updateExpiry()
                expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.updateExpiry() }
                }
                if let filter = CIFilter(name: "CIQRCodeGenerator") {
                    filter.setValue(Data(started.verificationUriComplete.utf8), forKey: "inputMessage")
                    filter.setValue("M", forKey: "inputCorrectionLevel")
                    if let output = filter.outputImage {
                        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
                        qr.image = UIImage(ciImage: scaled)
                        qr.isHidden = false
                    }
                }
                status.text = "Waiting for approval on your phone…"
                let profiles = try await SiloSession.awaitDeviceSignIn(started)
                try Task.checkCancellation()
                expiryTimer?.invalidate()
                expiryTimer = nil
                completed = true
                status.text = "Approved. Choose a profile to finish signing in."
                dismiss(animated: true) { [weak self] in self?.onApproved?(profiles) }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                status.text = SettingsContent.siloFailureCopy(for: error)
                expiryTimer?.invalidate()
                expiryTimer = nil
                deadline = nil
                expiry.text = nil
                if case SiloDeviceSignInError.unsupported = error { restart.isHidden = true }
                else { restart.isHidden = false }
                qr.image = nil
                qr.isHidden = true
                code.text = nil
                address.text = nil
                SiloSession.cancelPendingSignIn()
            }
        }
    }

    private func stop() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        deadline = nil
        task?.cancel()
        task = nil
        SiloSession.cancelPendingSignIn()
        qr.image = nil
        qr.isHidden = true
        code.text = nil
    }

    private func updateExpiry() {
        guard let deadline else { return }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        expiry.text = String(format: "Code expires in %d:%02d", remaining / 60, remaining % 60)
    }
}
