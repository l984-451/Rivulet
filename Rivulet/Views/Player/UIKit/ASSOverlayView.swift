// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ASSOverlayView.swift
//  Rivulet
//
//  Draws an ASS/SSA track through libass: one layer over the picture rect,
//  re-rendered each display frame while a track is set. Lives inside
//  CaptionOverlayView, which decides whether a track renders here or as
//  plain captions.
//
//  Events come from the model's FULL cue list, not the active set: libass
//  schedules them itself, and a `\fad` or `\move` needs the whole event.
//  Each line is handed over once. The engine re-decodes the window after a
//  seek and re-emits the same lines, and libass's own ReadOrder dedupe is off
//  (see LibassRenderer).
//

import Combine
import QuartzCore
import UIKit

final class ASSOverlayView: UIView {

    /// The track to render, or nil to render nothing.
    var track: ASSTrackSource? {
        didSet {
            guard track !== oldValue else { return }
            rebuildRenderer()
        }
    }

    /// Cue-axis time at a host time. nil (or a nil answer) falls back to the
    /// model's `sourceTime`.
    var sourceClock: ((CFTimeInterval) -> Double?)?

    /// libass line position: lifts unpositioned dialogue by this percent of
    /// the picture. Signs placed with `\pos` stay put.
    var linePosition: Double = 0 {
        didSet { if linePosition != oldValue { configureRenderer() } }
    }

    /// The video's own size, for libass's aspect and blur scale.
    var storageSize: CGSize = .zero {
        didSet { if storageSize != oldValue { configureRenderer() } }
    }

    /// True when libass is up for the current track. False when there is no
    /// track or libass failed to start, in which case the caller draws plain
    /// captions instead.
    var isRendering: Bool { renderer != nil }

    /// Events handed to libass for the current track. For tests.
    var renderedEventCount: Int { renderer?.eventCount() ?? 0 }

    private let model: SubtitleModel
    private var renderer: LibassRenderer?
    private var fedKeys = Set<String>()
    private var displayLink: CADisplayLink?
    private var renderInFlight = false
    private var generation = 0
    private let imageLayer = CALayer()
    private var cancellables = Set<AnyCancellable>()

    init(model: SubtitleModel) {
        self.model = model
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
        model.$cues
            .sink { [weak self] cues in self?.feed(cues) }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureRenderer()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    // MARK: Renderer

    private var scale: CGFloat { max(1, traitCollection.displayScale) }

    private func rebuildRenderer() {
        generation += 1
        renderer = track.flatMap { LibassRenderer(header: $0.header, fonts: $0.fonts) }
        fedKeys.removeAll()
        imageLayer.contents = nil
        configureRenderer()
        feed(model.cues)
        updateDisplayLink()
    }

    private func configureRenderer() {
        guard let renderer else { return }
        // ponytail: renders at the display's pixel scale (2x on a 4K TV); drop to 1x if Task 8 shows dense frames over budget.
        renderer.configure(frameWidth: Int((bounds.width * scale).rounded()),
                           frameHeight: Int((bounds.height * scale).rounded()),
                           storageWidth: Int(storageSize.width.rounded()),
                           storageHeight: Int(storageSize.height.rounded()),
                           linePosition: linePosition)
    }

    private func feed(_ cues: [AetherSubtitleCue]) {
        guard let renderer else { return }
        var events: [LibassRenderer.Event] = []
        for cue in cues {
            guard case .assEvents(let body) = cue.body else { continue }
            let startMs = Int64((cue.startTime * 1000).rounded())
            let durationMs = Int64(((cue.endTime - cue.startTime) * 1000).rounded())
            for line in body.split(separator: "\n") {
                // Keyed without the end: the engine trims an open-ended cue's
                // end on a later drain tick and republishes it (alignCueEnds),
                // and libass must not get that line a second time. The line
                // carries ReadOrder and Layer, so distinct events still differ.
                guard fedKeys.insert("\(startMs)|\(line)").inserted else { continue }
                events.append(.init(line: String(line), startMs: startMs, durationMs: durationMs))
            }
        }
        if !events.isEmpty { renderer.add(events) }
    }

    // MARK: Display link

    private func updateDisplayLink() {
        let wanted = renderer != nil && window != nil
        if wanted, displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkTarget(self),
                                     selector: #selector(DisplayLinkTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !wanted {
            displayLink?.invalidate()
            displayLink = nil
            renderInFlight = false
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        // A render still running means libass is behind the display; skip
        // this frame rather than queue work that lands late.
        guard let renderer, !renderInFlight else { return }
        let shown = sourceClock?(link.targetTimestamp) ?? model.sourceTime
        let ms = Int64(((shown - model.delaySeconds) * 1000).rounded())
        renderInFlight = true
        let generation = self.generation
        Task { [weak self] in
            let output = await renderer.render(atMs: ms)
            guard let self else { return }
            self.renderInFlight = false
            guard generation == self.generation else { return }
            self.apply(output)
        }
    }

    private func apply(_ output: LibassRenderer.Output) {
        guard case .changed(let frame) = output else { return }
        guard let frame else {
            imageLayer.contents = nil
            return
        }
        imageLayer.contentsScale = scale
        imageLayer.frame = CGRect(x: frame.rect.minX / scale, y: frame.rect.minY / scale,
                                  width: frame.rect.width / scale, height: frame.rect.height / scale)
        imageLayer.contents = frame.image
    }
}

/// CADisplayLink retains its target; this holds the view weakly.
private final class DisplayLinkTarget: NSObject {
    private weak var owner: ASSOverlayView?

    init(_ owner: ASSOverlayView) { self.owner = owner }

    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}
