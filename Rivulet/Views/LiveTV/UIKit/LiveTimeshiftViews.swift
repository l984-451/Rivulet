// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTimeshiftViews.swift
//  Rivulet
//
//  The small pieces the live player's timeline needs beyond the shared
//  progress bar: a badge that says where the picture is relative to live, a
//  scrim so the timeline reads over video when the rail is not behind it, and
//  a passing notice for what the engine did on its own.
//

import UIKit

/// "● LIVE" at the live edge, "−2:15" behind it, a pause glyph while paused.
///
/// Non-interactive on purpose. It sits over the lower rail area, and the
/// focus engine's occlusion test is geometric: a non-hidden view above a
/// button can make that button unfocusable. It is laid out clear of the rail
/// buttons and hidden, not just transparent, whenever the timeline is.
final class LiveTimeshiftBadgeView: UIView {

    private let dot = UIView()
    private let glyph = UIImageView()
    private let label = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.35)
        layer.cornerRadius = 17
        layer.cornerCurve = .continuous

        dot.backgroundColor = UIColor.systemRed
        dot.layer.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        glyph.tintColor = .white
        glyph.contentMode = .scaleAspectFit
        glyph.image = UIImage(systemName: "pause.fill")
        glyph.translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white

        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        [glyph, dot, label].forEach { stack.addArrangedSubview($0) }
        addSubview(stack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            glyph.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
        update(behindLiveSeconds: 0, hasRewindWindow: false, isPaused: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Anything under a few seconds behind still reads as live: a live
    /// session always trails the edge by its holdback, and a badge that
    /// flickered "−0:03" at rest would be noise.
    static let liveToleranceSeconds: Double = 5

    func update(behindLiveSeconds: Double, hasRewindWindow: Bool, isPaused: Bool) {
        let isLive = !hasRewindWindow || behindLiveSeconds < Self.liveToleranceSeconds
        glyph.isHidden = !isPaused
        dot.isHidden = !isLive || isPaused
        if isLive && !isPaused {
            label.text = "LIVE"
        } else if isLive {
            label.text = "Paused"
        } else {
            label.text = "−" + Self.clock(behindLiveSeconds)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Bottom-up dark gradient behind the timeline while the rail's glass is not
/// there to carry it. Never interactive; hidden whenever it is invisible.
final class LiveBottomScrimView: UIView {

    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.55).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A one-line note that fades in at the top of the picture and goes again,
/// for something the viewer did not ask for but should know happened (the
/// engine jumping a long pause forward). Never interactive, and hidden while
/// invisible.
final class LiveNoticeView: UIView {

    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = .white
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(lessThanOrEqualToConstant: 760),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ text: String, for seconds: TimeInterval = 4) {
        label.text = text
        hideWork?.cancel()
        isHidden = false
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.3, animations: { self.alpha = 0 }, completion: { _ in
                if self.alpha == 0 { self.isHidden = true }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
