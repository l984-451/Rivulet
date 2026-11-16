// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ASSOverlayView.swift
//  Rivulet
//
//  Draws an ASS/SSA track through libass into up to four region layers over the
//  picture. libass renders ahead on its own queue; the display tick only picks a unit.
//  Fed the full cue list, not the active set (`\fad` and `\move` need whole
//  events), each cue once, since libass's ReadOrder dedupe is off.
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

    /// Subtitle Brightness (0.4...1). Dims every libass colour's RGB, alpha
    /// kept; a change re-renders the queued frames.
    var brightness: Double = 1 {
        didSet {
            guard brightness != oldValue, let renderer else { return }
            renderer.setBrightness(brightness)
            resetSchedule(blank: false)
        }
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
    private var fedIDs = Set<Int>()
    private var fedKeys = Set<String>()
    private var configuration: [Double] = []
    private var displayLink: CADisplayLink?
    private var schedule = ASSRenderQueue()
    private var shownUnitID: Int?
    private var lastPlayheadMs: Double?
    /// Recent libass + composite cost per frame, in ms.
    private var renderCostMs = 0.0
    private let regionLayers = (0..<ASSCompositor.maxRegions).map { _ in CALayer() }
    private var cancellables = Set<AnyCancellable>()

    init(model: SubtitleModel) {
        self.model = model
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for region in regionLayers {
            region.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer.addSublayer(region)
        }
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
        renderer = track.flatMap { LibassRenderer(header: $0.header, fonts: $0.fonts) }
        renderer?.setBrightness(brightness)
        fedIDs.removeAll()
        fedKeys.removeAll()
        configuration = []
        resetSchedule()
        configureRenderer()
        feed(model.cues)
        updateDisplayLink()
    }

    private func configureRenderer() {
        guard let renderer else { return }
        let next = [(bounds.width * scale).rounded(), (bounds.height * scale).rounded(),
                    storageSize.width.rounded(), storageSize.height.rounded(), linePosition]
        guard next != configuration else { return }
        configuration = next
        // ponytail: renders at the display's pixel scale (2x on a 4K TV); drop to 1x if dense frames fall behind on device.
        renderer.configure(frameWidth: Int(next[0]), frameHeight: Int(next[1]),
                           storageWidth: Int(next[2]), storageHeight: Int(next[3]),
                           linePosition: linePosition)
        // Keeps the old image up until the new geometry's first frame lands.
        resetSchedule(blank: false)
    }

    /// Drops every rendered unit and every job in flight.
    private func resetSchedule(blank: Bool = true) {
        schedule.reset()
        renderer?.cancelJobs(before: schedule.generation)
        if blank { show(nil) }
    }

    private func feed(_ cues: [AetherSubtitleCue]) {
        guard let renderer else { return }
        var events: [LibassRenderer.Event] = []
        for cue in cues {
            // The engine stamps a cue's id once per session and keeps it across
            // end trims and re-decodes. Id 0 is also what an unstamped source
            // sends, so it falls through to the line key.
            if cue.id != 0 {
                guard fedIDs.insert(cue.id).inserted else { continue }
            }
            guard case .assEvents(let body) = cue.body else { continue }
            // Cue times come from the file or server; out-of-range values trap Int64(_:).
            guard cue.startTime.isFinite, cue.endTime.isFinite,
                  abs(cue.startTime) < 1e7, abs(cue.endTime) < 1e7 else { continue }
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
        guard !events.isEmpty else { return }
        renderer.add(events)
        schedule.eventsAdded(events.map { Double($0.startMs)..<Double($0.startMs + max($0.durationMs, 1)) })
        renderer.cancelJobs(before: schedule.generation)
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
            lastPlayheadMs = nil
            resetSchedule()
        }
    }

    /// No libass work here: picks the unit for the frame on screen and starts
    /// the next render batch when the queue runs low.
    fileprivate func tick(_ link: CADisplayLink) {
        guard let renderer else { return }
        let shown = sourceClock?(link.targetTimestamp) ?? model.sourceTime
        let playhead = (shown - model.delaySeconds) * 1000
        let playing = lastPlayheadMs.map { $0 != playhead } ?? false
        lastPlayheadMs = playhead
        // One unit per display frame, or fewer when libass can't keep that pace.
        let stepMs = max(max(link.targetTimestamp - link.timestamp, 1.0 / 120) * 1000, renderCostMs * 2)

        if let job = schedule.nextJob(playheadMs: playhead, stepMs: stepMs, playing: playing) {
            renderer.cancelJobs(before: job.generation)
            Task { [weak self] in
                let t0 = CACurrentMediaTime()
                let outputs = await renderer.render(job)
                let dt = (CACurrentMediaTime() - t0) * 1000
                guard let self, self.renderer === renderer else { return }
                if !outputs.isEmpty { self.renderCostMs += (dt / Double(outputs.count) - self.renderCostMs) * 0.2 }
                self.schedule.complete(job, outputs: outputs)
            }
        }
        // Until a seek's first frame lands nothing covers the playhead; keep
        // what is on screen rather than blink.
        if let unit = schedule.unit(at: playhead), unit.id != shownUnitID {
            show(unit.frame)
            shownUnitID = unit.id
        }
    }

    private func show(_ frame: LibassRenderer.Frame?) {
        shownUnitID = nil
        let regions = frame?.regions ?? []
        for (index, layer) in regionLayers.enumerated() {
            guard index < regions.count else {
                layer.contents = nil
                layer.isHidden = true
                continue
            }
            let region = regions[index]
            layer.contentsScale = scale
            layer.frame = CGRect(x: region.rect.minX / scale, y: region.rect.minY / scale,
                                 width: region.rect.width / scale, height: region.rect.height / scale)
            layer.contents = region.image
            layer.isHidden = false
        }
    }
}

/// CADisplayLink retains its target; this holds the view weakly.
private final class DisplayLinkTarget: NSObject {
    private weak var owner: ASSOverlayView?

    init(_ owner: ASSOverlayView) { self.owner = owner }

    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

