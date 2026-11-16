// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibassRenderer.swift
//  Rivulet
//
//  libass for ASS/SSA subtitles. The library, renderer and track are confined
//  to one serial queue: libass has no internal locking.
//

import CoreGraphics
import Foundation
import Libass
import Synchronization

nonisolated final class LibassRenderer: @unchecked Sendable {

    /// An embedded font (MKV attachment) for libass's memory font list.
    struct Font: Sendable {
        let name: String
        let data: Data
    }

    /// One raw event line with its timing on the cue axis.
    struct Event: Sendable {
        let line: String
        let startMs: Int64
        let durationMs: Int64
    }

    /// The rendered subtitles as up to four region images, rects in frame
    /// pixels. CGImage is immutable, so crossing back to the main actor is safe.
    struct Frame: @unchecked Sendable {
        struct Region {
            let image: CGImage
            let rect: CGRect
        }
        let regions: [Region]
    }

    enum Output: @unchecked Sendable {
        /// Identical to the previous render; keep what is on screen.
        case unchanged
        /// New content, or nil for nothing to show.
        case changed(Frame?)
    }

    /// The linked libass version, `LIBASS_VERSION` of the build (0x01705000 is 0.17.5).
    static var libraryVersion: Int32 { ass_library_version() }

    private struct Configuration: Equatable {
        var frameWidth = 0, frameHeight = 0, storageWidth = 0, storageHeight = 0
        var linePosition = 0.0
    }

    /// The libass handles, carried to `queue` for teardown. Only ever touched
    /// there, which is the confinement that makes the unchecked conformance hold.
    private struct Handles: @unchecked Sendable {
        let library: OpaquePointer
        let renderer: OpaquePointer
        let track: UnsafeMutablePointer<ASS_Track>
    }

    private let queue = DispatchQueue(label: "com.rivulet.libass", qos: .userInitiated)
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let track: UnsafeMutablePointer<ASS_Track>
    private var configuration = Configuration()
    private var renderCalls = 0
    private let currentGeneration = Atomic<Int>(0)
    /// The time last handed to libass, and whether anything changed since.
    /// A paused frame repeats its time on every display tick, and
    /// `ass_render_frame` lays out every active event before it can report
    /// "unchanged".
    private var lastRenderedMs: Int64?
    private var needsRender = true
    /// Subtitle Brightness, applied while compositing. A change forces the
    /// next render out even when libass reports no change.
    private var brightness = 1.0
    private var restyled = false

    /// One library per renderer, so a track's memory fonts are never shared
    /// with another track (libass guards none of its state with locks).
    init?(header: String, fonts: [Font]) {
        guard let library = ass_library_init() else { return nil }
        // Font lookup logs at info level for every face; keep the console quiet.
        ass_set_message_cb(library, { _, _, _, _ in }, nil)
        // Memory fonts must be in place before `ass_set_fonts` builds the font list.
        for font in fonts {
            font.data.withUnsafeBytes { bytes in
                ass_add_font(library, font.name,
                             bytes.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count))
            }
        }
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            return nil
        }
        // CoreText answers for every face a script names and for glyph
        // fallback (CJK); the embedded fonts added above take part in the same lookup.
        ass_set_fonts(renderer, nil, nil, Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 0)
        guard let track = ass_new_track(library) else {
            ass_renderer_done(renderer)
            ass_library_done(library)
            return nil
        }
        header.withCString { ass_process_codec_private(track, $0, Int32(strlen($0))) }
        // Real files ship ReadOrder hardcoded to 0, so libass's ReadOrder
        // dedupe would keep a single event. ASSOverlayView dedupes instead.
        ass_set_check_readorder(track, 0)
        self.library = library
        self.renderer = renderer
        self.track = track
    }

    deinit {
        // Async: the last reference can drop inside a render closure running
        // on `queue`, where a sync hop would deadlock.
        let handles = Handles(library: library, renderer: renderer, track: track)
        queue.async {
            ass_free_track(handles.track)
            ass_renderer_done(handles.renderer)
            ass_library_done(handles.library)
        }
    }

    func add(_ events: [Event]) {
        queue.async { [self] in
            for event in events {
                event.line.withCString {
                    ass_process_chunk(track, $0, Int32(strlen($0)), event.startMs, event.durationMs)
                }
            }
            needsRender = true
        }
    }

    /// Subtitle Brightness (0.4...1) for the composited pixels.
    func setBrightness(_ value: Double) {
        queue.async { [self] in
            guard value != brightness else { return }
            brightness = value
            needsRender = true
            restyled = true
        }
    }

    /// Frame = the on-screen picture in pixels. Storage = the video's size,
    /// which libass uses for aspect and blur scale. Line position lifts
    /// unpositioned dialogue only (0 to 100, percent of the frame).
    func configure(frameWidth: Int, frameHeight: Int,
                   storageWidth: Int, storageHeight: Int, linePosition: Double) {
        let next = Configuration(frameWidth: frameWidth, frameHeight: frameHeight,
                                 storageWidth: storageWidth > 0 ? storageWidth : frameWidth,
                                 storageHeight: storageHeight > 0 ? storageHeight : frameHeight,
                                 linePosition: min(max(linePosition, 0), 100))
        queue.async { [self] in
            guard next != configuration else { return }
            configuration = next
            needsRender = true
            guard next.frameWidth > 0, next.frameHeight > 0 else { return }
            ass_set_frame_size(renderer, Int32(next.frameWidth), Int32(next.frameHeight))
            ass_set_storage_size(renderer, Int32(next.storageWidth), Int32(next.storageHeight))
            ass_set_line_position(renderer, next.linePosition)
        }
    }

    /// Renders a job's frames on the libass queue and resumes the caller with them.
    /// A continuation, never a completion closure: a closure formed on the
    /// main actor inherits its isolation under this target's default
    /// MainActor isolation, and running it on `queue` trips the executor check.
    func render(_ job: ASSRenderJob) async -> [Output] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: renderLocked(job)) }
        }
    }

    /// Jobs older than `generation` stop at their next frame instead of
    /// rendering frames nobody will show.
    func cancelJobs(before generation: Int) {
        currentGeneration.store(generation, ordering: .relaxed)
    }

    /// Synchronous job render for tests.
    func renderNow(_ job: ASSRenderJob) -> [Output] {
        queue.sync { renderLocked(job) }
    }

    private func renderLocked(_ job: ASSRenderJob) -> [Output] {
        var outputs: [Output] = []
        for index in 0..<job.count {
            guard job.generation >= currentGeneration.load(ordering: .relaxed) else { break }
            outputs.append(renderLocked(atMs: job.sampleMs(index), force: job.force && index == 0))
        }
        return outputs
    }

    /// Synchronous render for tests. Never call on the main thread in
    /// production: a dense frame costs milliseconds.
    func renderNow(atMs ms: Int64, force: Bool = false) -> Output {
        queue.sync { renderLocked(atMs: ms, force: force) }
    }

    func eventCount() -> Int {
        queue.sync { Int(track.pointee.n_events) }
    }

    /// Calls into `ass_render_frame` so far. For tests.
    func libassRenderCount() -> Int {
        queue.sync { renderCalls }
    }

    /// `force` returns the frame even when libass reports no change.
    private func renderLocked(atMs ms: Int64, force: Bool) -> Output {
        guard configuration.frameWidth > 0, configuration.frameHeight > 0 else { return .unchanged }
        guard force || needsRender || ms != lastRenderedMs else { return .unchanged }
        lastRenderedMs = ms
        needsRender = false
        var change: Int32 = 0
        renderCalls += 1
        let images = ass_render_frame(renderer, track, ms, &change)
        guard change != 0 || force || restyled else { return .unchanged }
        restyled = false

        var bitmaps: [ASSCompositor.Bitmap] = []
        var node = images
        while let current = node {
            let image = current.pointee
            if let pixels = image.bitmap, image.w > 0, image.h > 0 {
                bitmaps.append(ASSCompositor.Bitmap(
                    width: Int(image.w), height: Int(image.h), stride: Int(image.stride),
                    pixels: UnsafePointer(pixels), color: image.color,
                    x: Int(image.dst_x), y: Int(image.dst_y)))
            }
            node = image.next
        }
        let regions = ASSCompositor.composite(bitmaps, brightness: brightness).map { Frame.Region(image: $0.image, rect: $0.rect) }
        return .changed(regions.isEmpty ? nil : Frame(regions: regions))
    }
}
