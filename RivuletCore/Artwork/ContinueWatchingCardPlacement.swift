// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContinueWatchingCardPlacement.swift
//  Rivulet
//
//  Apple's editors place each Up Next title by hand, clear of faces and busy
//  artwork. This picks the title's edge and height from the still itself
//  (faces, subjects, brightness, saliency).
//

import CoreGraphics
import CoreML
import Vision

nonisolated extension ContinueWatchingCardCompositor {

    /// Row-major samples in 0...1 covering a whole image, top row first.
    struct Grid: Equatable, Sendable, Codable {
        let columns: Int
        let rows: Int
        let values: [Float]

        /// Mean, standard deviation and detail (mean step to the next sample
        /// right and down) of the samples under a unit rect.
        func stats(in rect: CGRect) -> (mean: Double, deviation: Double, detail: Double)? {
            let x0 = max(0, Int((rect.minX * CGFloat(columns)).rounded()))
            let x1 = min(columns, Int((rect.maxX * CGFloat(columns)).rounded()))
            let y0 = max(0, Int((rect.minY * CGFloat(rows)).rounded()))
            let y1 = min(rows, Int((rect.maxY * CGFloat(rows)).rounded()))
            guard x0 < x1, y0 < y1 else { return nil }
            var sum = 0.0, squares = 0.0, steps = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let value = Double(values[y * columns + x])
                    sum += value
                    squares += value * value
                    steps += abs(value - Double(values[y * columns + min(x + 1, columns - 1)]))
                        + abs(value - Double(values[min(y + 1, rows - 1) * columns + x]))
                }
            }
            let count = Double((x1 - x0) * (y1 - y0)), mean = sum / count
            return (mean, max(0, squares / count - mean * mean).squareRoot(), steps / count)
        }
    }

    /// What the analysis read off a still, in unit image coordinates, top-left origin.
    struct Signals: Equatable, Sendable, Codable {
        /// Source pixel size.
        var size: CGSize
        /// Nil when face detection could not run: the title then stays put.
        var faces: [CGRect]?
        var luma: Grid?
        var saliency: Grid?
        /// How much of each spot is a foreground subject, face or not.
        var subject: Grid?

        static let none = Signals(size: .zero, faces: nil, luma: nil, saliency: nil)
    }

    struct Placement: Equatable, Sendable {
        var side = Side.leading
        /// The title box's shift down from its centred place, in points.
        var offset: CGFloat = 0
        var strongShadow = false
        /// The logo's size next to its fit in the title box, kept on its edge.
        var scale: CGFloat = 1
    }

    // MARK: - Scoring

    /// What covering a subject, or a face's surroundings, costs next to
    /// brightness, and what moving the title a still's height costs.
    static let subjectWeight = 1.0, faceWeight = 1.5, travelWeight = 0.5
    /// A light title reads on anything darker than this.
    static let comfortableLuma = 0.35
    /// What the trailing edge costs: the title crosses only off a clearly worse leading edge.
    static let trailingCost = 0.45
    /// A logo that hides a face wherever it goes is tried again this much smaller.
    static let smallTitleScale: CGFloat = 0.7
    /// The default spot stands while it costs no more than this: a title that
    /// reads there stays put, so a row of cards keeps one look.
    static let goodEnoughCost = 0.6
    /// Leaving the default must save at least this much.
    static let moveMargin = 0.3

    /// How badly a light title reads on `rect`: bright, busy (tonal spread, and
    /// detail, which finds a mid-tone cartoon cast that spread misses), eye-catching,
    /// on a subject, or crowding a face (the share it covers of each face's box tripled).
    static func cost(of rect: CGRect, faces: [CGRect] = [], luma: Grid, saliency: Grid?, subject: Grid?) -> Double {
        guard let stats = luma.stats(in: rect) else { return .infinity }
        let crowding = faces.reduce(0.0) { sum, face in
            let around = face.insetBy(dx: -face.width, dy: -face.height), overlap = around.intersection(rect)
            return sum + (overlap.isNull ? 0 : overlap.width * overlap.height / (around.width * around.height))
        }
        return max(0, stats.mean - comfortableLuma) + 2 * (stats.deviation + stats.detail)
            + (saliency?.stats(in: rect)?.mean ?? 0) + subjectWeight * (subject?.stats(in: rect)?.mean ?? 0) + faceWeight * crowding
    }

    /// Whether a title on `rect` hides more of `face` than a sliver.
    static func hides(_ rect: CGRect, _ face: CGRect) -> Bool {
        let overlap = face.intersection(rect)
        return !overlap.isNull && overlap.width * overlap.height > 0.05 * face.width * face.height
    }

    /// The candidate a light title reads best on: never over a face unless all
    /// are, then the one covering the least face. Among clear ones the cheapest,
    /// counting its distance from the first candidate (`travelScale` converts a
    /// unit of image height to still heights) and its `surcharge`, if any.
    /// Rects are unit image coordinates.
    static func chooseSlot(candidates: [CGRect], faces: [CGRect], luma: Grid, saliency: Grid?,
                           subject: Grid? = nil, travelScale: Double = 1, surcharge: [Double] = []) -> Int {
        func cost(_ index: Int) -> Double {
            Self.cost(of: candidates[index], faces: faces, luma: luma, saliency: saliency, subject: subject)
                + travelWeight * travelScale * abs(candidates[index].midY - candidates[0].midY)
                + (index < surcharge.count ? surcharge[index] : 0)
        }
        let open = candidates.indices.filter { index in !faces.contains { hides(candidates[index], $0) } }
        // Every candidate covers a face: take the one covering the least.
        func covered(_ index: Int) -> CGFloat {
            faces.reduce(0) { sum, face in
                let overlap = face.intersection(candidates[index])
                return sum + (overlap.isNull ? 0 : overlap.width * overlap.height)
            }
        }
        guard let best = open.min(by: { cost($0) < cost($1) }), cost(best).isFinite else {
            return candidates.indices.min {
                abs(covered($0) - covered($1)) > 1e-9 ? covered($0) < covered($1) : cost($0) < cost($1)
            } ?? 0
        }
        // The default keeps its place unless it reads poorly and another reads clearly better.
        func raw(_ index: Int) -> Double {
            Self.cost(of: candidates[index], faces: faces, luma: luma, saliency: saliency, subject: subject)
        }
        if open.contains(0), raw(0) <= goodEnoughCost || raw(0) - raw(best) < moveMargin { return 0 }
        return best
    }

    /// Whether a light title on this part of the still needs the stronger shadow.
    static func needsStrongShadow(under rect: CGRect, luma: Grid) -> Bool {
        guard let stats = luma.stats(in: rect) else { return false }
        return stats.mean > 0.6 || stats.deviation > 0.22
    }

    // MARK: - Card space

    /// The title's edge, height, shadow and size for a still. `logoSize` narrows the
    /// scored area to what the logo will cover, `textSize` to the fallback title's line.
    static func placement(signals: Signals, logoSize: CGSize?, textSize: CGSize? = nil,
                          geometry: Geometry) -> Placement {
        let title = geometry.titleFootprint(logoSize: logoSize, textSize: textSize)
        let rest = restingPlacement(for: title, geometry: geometry)
        guard let luma = signals.luma else { return rest }
        let frame = aspectFill(signals.size, in: geometry.still)
        guard let faces = signals.faces else {
            let resting = geometry.titleRect(title, side: .leading, offset: rest.offset)
            return Placement(offset: rest.offset, strongShadow: needsStrongShadow(under: unit(resting, in: frame), luma: luma))
        }
        func place(_ scale: CGFloat) -> (Placement, hidesFace: Bool) {
            // Lowest first: the lowest leading spot is the default.
            let offsets = geometry.titleOffsets(forHeight: title.height * scale).sorted(by: >)
            let slots = [Side.leading, .trailing].flatMap { side in offsets.map { (side: side, offset: $0) } }
            let candidates = slots.map {
                unit(geometry.titleRect(title, side: $0.side, offset: $0.offset, scale: scale), in: frame)
            }
            let index = chooseSlot(candidates: candidates, faces: faces, luma: luma, saliency: signals.saliency,
                                   subject: signals.subject, travelScale: frame.height / (geometry.card.width / 1.7778),
                                   surcharge: slots.map { $0.side == .trailing ? trailingCost : 0 })
            return (Placement(side: slots[index].side, offset: slots[index].offset,
                              strongShadow: needsStrongShadow(under: candidates[index], luma: luma), scale: scale),
                    faces.contains { hides(candidates[index], $0) })
        }
        // Smaller only once neither edge clears the faces at full size.
        let full = place(1)
        guard full.hidesFace, logoSize != nil else { return full.0 }
        let small = place(smallTitleScale)
        return small.hidesFace ? full.0 : small.0
    }

    /// Where a title rests before, or without, any analysis: on the leading edge, on the floor.
    static func restingPlacement(for title: CGRect, geometry: Geometry) -> Placement {
        Placement(offset: geometry.titleOffsets(forHeight: title.height).max() ?? 0)
    }

    /// Which of `candidates`, in the points of a `canvas` the still fills, a light
    /// title reads best on, and whether it needs the stronger shadow there. The
    /// first is the default: it stands when the still gave nothing to read.
    static func choose(among candidates: [CGRect], on canvas: CGRect, signals: Signals,
                       surcharge: [Double] = []) -> (index: Int, strongShadow: Bool) {
        guard let luma = signals.luma, !candidates.isEmpty else { return (0, false) }
        let frame = aspectFill(signals.size, in: canvas)
        let rects = candidates.map { unit($0, in: frame) }
        let index = signals.faces.map {
            chooseSlot(candidates: rects, faces: $0, luma: luma, saliency: signals.saliency, subject: signals.subject,
                       travelScale: frame.height / canvas.height, surcharge: surcharge)
        } ?? 0
        return (index, needsStrongShadow(under: rects[index], luma: luma))
    }

    /// `rect`, in card points, as unit coordinates of the still drawn in `frame`.
    private static func unit(_ rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: (rect.minX - frame.minX) / frame.width, y: (rect.minY - frame.minY) / frame.height,
               width: rect.width / frame.width, height: rect.height / frame.height)
    }

    // MARK: - Analysis

    /// Reads a still's signals from a small copy. Call off the main thread.
    static func analyse(_ still: CGImage) -> Signals {
        let size = CGSize(width: still.width, height: still.height)
        guard still.width > 0, still.height > 0 else { return .none }
        let aspect = size.height / size.width
        func small(_ width: Int, gray: Bool) -> CGContext? {
            let height = max(1, Int((CGFloat(width) * aspect).rounded()))
            let context = gray
                ? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                : bitmap(width: width, height: height)
            context?.interpolationQuality = .medium
            context?.draw(still, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context
        }
        var luma: Grid?
        if let gray = small(64, gray: true), let data = gray.data {
            let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                            count: gray.bytesPerRow * gray.height)
            luma = Grid(columns: gray.width, rows: gray.height, values: (0..<gray.width * gray.height).map {
                Float(bytes[($0 / gray.width) * gray.bytesPerRow + $0 % gray.width]) / 255
            })
        }
        let seen = small(384, gray: false)?.makeImage().flatMap(vision)
        return Signals(size: size, faces: seen?.faces, luma: luma, saliency: seen?.saliency, subject: seen?.subject)
    }

    /// Vision's read of an image: face boxes, the attention map and the
    /// objectness map. Nil when face detection fails; a failed map is only dropped.
    static func vision(_ image: CGImage) -> (faces: [CGRect], saliency: Grid?, subject: Grid?)? {
        let handler = VNImageRequestHandler(cgImage: image)
        let faceRequest = VNDetectFaceRectanglesRequest()
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let subjectRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        #if targetEnvironment(simulator)
        // The simulator can only build Vision's models on the CPU.
        for request in [faceRequest, saliencyRequest, subjectRequest] as [VNRequest] {
            for (stage, devices) in (try? request.supportedComputeStageDevices) ?? [:] {
                if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                    request.setComputeDevice(cpu, for: stage)
                }
            }
        }
        #endif
        guard (try? handler.perform([faceRequest])) != nil, let found = faceRequest.results else { return nil }
        // Vision's origin is bottom-left.
        let faces = found.map { $0.boundingBox }.map {
            CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height)
        }
        func map(_ request: VNImageBasedRequest) -> Grid? {
            guard (try? handler.perform([request])) != nil,
                  let buffer = (request.results?.first as? VNSaliencyImageObservation)?.pixelBuffer,
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
            else { return nil }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let columns = CVPixelBufferGetWidth(buffer), rows = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let values = (0..<rows).flatMap { row in
                UnsafeBufferPointer(start: (base + row * rowBytes).assumingMemoryBound(to: Float.self), count: columns)
            }
            return Grid(columns: columns, rows: rows, values: values)
        }
        return (faces, map(saliencyRequest), map(subjectRequest))
    }
}
