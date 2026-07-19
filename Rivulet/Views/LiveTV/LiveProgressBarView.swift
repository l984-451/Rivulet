// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveProgressBarView.swift
//  Rivulet
//
//  Non-seekable progress bar for the Live TV OSD. Represents the CURRENT
//  programme's air window: the track spans [programme start, programme end],
//  the fill + knob sit at `now` proportionally, and the flanking labels show
//  the start and end times. Purely visual — Live TV has no scrub target, this
//  just orients the viewer within the show (e.g. a show 12:00–1:30 with now at
//  1:00 fills two-thirds).
//

import UIKit

final class LiveProgressBarView: UIView {

    // MARK: Metrics
    private enum Metrics {
        static let trackHeight: CGFloat = 6
        static let knobDiameter: CGFloat = 14
        static let labelGap: CGFloat = 14      // between a time label and the track
        static let labelWidth: CGFloat = 74    // reserved for each "12:30 PM" label
    }

    // MARK: Subviews
    private let startLabel = UILabel()
    private let endLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let knob = UIView()

    /// 0…1 position of `now` within the programme window. Applied in layout.
    private var progress: CGFloat = 0
    /// Hidden (no fill/knob) when there is no programme window to represent.
    private var hasProgramme = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        for label in [startLabel, endLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.7)
            addSubview(label)
        }
        startLabel.textAlignment = .left
        endLabel.textAlignment = .right

        track.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        track.layer.cornerRadius = Metrics.trackHeight / 2
        addSubview(track)

        fill.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        fill.layer.cornerRadius = Metrics.trackHeight / 2
        track.addSubview(fill)

        knob.backgroundColor = .white
        knob.layer.cornerRadius = Metrics.knobDiameter / 2
        knob.layer.shadowColor = UIColor.black.cgColor
        knob.layer.shadowOpacity = 0.35
        knob.layer.shadowRadius = 3
        knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(knob)
    }

    // MARK: Update

    /// Point the bar at a programme window. Pass `start`/`end`/`now`; when they
    /// don't form a valid window (no EPG, or zero-length) the bar renders empty.
    func update(start: Date?, end: Date?, now: Date = Date()) {
        if let start, let end, end > start {
            hasProgramme = true
            let total = end.timeIntervalSince(start)
            let elapsed = now.timeIntervalSince(start)
            progress = CGFloat(min(1, max(0, elapsed / total)))
            let fmt = DateFormatter()
            fmt.timeStyle = .short
            fmt.dateStyle = .none
            startLabel.text = fmt.string(from: start)
            endLabel.text = fmt.string(from: end)
        } else {
            hasProgramme = false
            progress = 0
            startLabel.text = nil
            endLabel.text = nil
        }
        setNeedsLayout()
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let midY = bounds.midY
        startLabel.frame = CGRect(x: 0, y: 0, width: Metrics.labelWidth, height: bounds.height)
        startLabel.center.y = midY
        startLabel.frame.origin.x = 0
        endLabel.frame = CGRect(x: bounds.width - Metrics.labelWidth, y: 0,
                                width: Metrics.labelWidth, height: bounds.height)
        endLabel.center.y = midY

        let trackX = Metrics.labelWidth + Metrics.labelGap
        let trackW = max(0, bounds.width - 2 * (Metrics.labelWidth + Metrics.labelGap))
        track.frame = CGRect(x: trackX, y: midY - Metrics.trackHeight / 2,
                             width: trackW, height: Metrics.trackHeight)

        let fillW = hasProgramme ? trackW * progress : 0
        fill.frame = CGRect(x: 0, y: 0, width: fillW, height: Metrics.trackHeight)

        knob.frame = CGRect(x: 0, y: 0, width: Metrics.knobDiameter, height: Metrics.knobDiameter)
        knob.center = CGPoint(x: trackX + fillW, y: midY)
        knob.isHidden = !hasProgramme
    }
}
