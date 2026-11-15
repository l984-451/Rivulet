// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ArtworkTitleCheck.swift
//  Rivulet
//
//  Some libraries use artwork with the title already on it (fanart.tv thumbs).
//  Continue Watching then draws no title of its own (#450, #453). Two reads
//  decide: the clear logo found in the still, or the title read off it.
//

import CoreGraphics
import CryptoKit
import Foundation
import Vision

nonisolated enum ArtworkTitleCheck {

    // MARK: - Cached answers

    private static let answers = NSCache<NSString, NSNumber>()
    /// One serial queue, so checks never crowd out image loads and drawing.
    private static let queue = DispatchQueue(label: "rivulet.artwork-title-check", qos: .utility)
    // ponytail: pruned by age (30 days since checked) at first use, as the card cache is.
    private static let directory: URL? = {
        let files = FileManager.default
        guard let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("ArtworkTitleCheck", isDirectory: true)
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        let listed = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        for file in listed ?? [] {
            let checked = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (checked ?? .distantPast) < cutoff { try? files.removeItem(at: file) }
        }
        return directory
    }()

    /// One answer per still and title. Not the logo: its URL is not always known
    /// when a card first draws, and a Plex still's URL changes with the artwork.
    /// The suffix is the detector's version: bump it when the rules change, so old "no title" answers are checked again.
    static func key(still: URL, title: String) -> String {
        "\(still.absoluteString)#\(title)#v2"
    }

    /// Forgets every answer (Settings, Clear All Cache).
    static func clearDisk() {
        answers.removeAllObjects()
        HeroTextlessBackdrop.clear()
        guard let directory else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func file(_ key: String) -> URL? {
        directory?.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// A finished check, from memory or disk; nil when it has not run.
    static func known(_ key: String) -> Bool? {
        if let known = answers.object(forKey: key as NSString) { return known.boolValue }
        guard let url = file(key), let byte = (try? Data(contentsOf: url))?.first else { return nil }
        answers.setObject(NSNumber(value: byte == 1), forKey: key as NSString)
        return byte == 1
    }

    /// Runs `stillShowsTitle` once per key and keeps the answer. `load` returns nil
    /// when an image failed to load; that is not kept, so the next display tries again.
    static func answer(_ key: String, title: String,
                       load: () async -> (still: CGImage, logo: CGImage?)?) async -> Bool {
        if let known = known(key) { return known }
        guard let images = await load() else { return false }
        let shows = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: stillShowsTitle(images.still, logo: images.logo, title: title)) }
        }
        answers.setObject(NSNumber(value: shows), forKey: key as NSString)
        if let url = file(key) { try? Data([shows ? 1 : 0]).write(to: url, options: .atomic) }
        return shows
    }

    private static func bitmap(width: Int, height: Int, alpha: CGImageAlphaInfo = .noneSkipLast) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue)
    }

    // MARK: - Check

    /// Whether the still already shows the title, as the logo or as text. Call off the main thread.
    static func stillShowsTitle(_ still: CGImage, logo: CGImage?, title: String) -> Bool {
        if let logo, stillContainsLogo(still, logo: logo) { return true }
        // Vision reads stylised lettering differently at each size, so ask at three and stop at the first yes.
        return readingWidths.contains { textShowsTitle(recognizedLines(in: still, width: $0), title: title) }
    }

    static let readingWidths = [512, 768, 1536]

    // MARK: - Logo

    /// Image pixels for template matching: RGB in 0...1 with colour un-premultiplied, plus alpha.
    struct Pixels {
        let width: Int
        let height: Int
        let values: [Float]

        init?(_ image: CGImage, width: Int) {
            let height = Int((CGFloat(width) * CGFloat(image.height) / CGFloat(image.width)).rounded())
            guard width > 0, height > 0,
                  let context = bitmap(width: width, height: height, alpha: .premultipliedLast),
                  let data = context.data else { return nil }
            context.interpolationQuality = .high
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                            count: context.bytesPerRow * height)
            var values = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let source = y * context.bytesPerRow + x * 4, target = (y * width + x) * 4
                    let alpha = Float(bytes[source + 3]) / 255
                    values[target + 3] = alpha
                    guard alpha > 0 else { continue }
                    for channel in 0..<3 { values[target + channel] = min(1, Float(bytes[source + channel]) / 255 / alpha) }
                }
            }
            self.width = width
            self.height = height
            self.values = values
        }
    }

    /// A logo at one size: its opaque pixels with their colour, and the pixels around
    /// it, each paired with the colour of the logo pixel it faces.
    struct LogoTemplate {
        struct Sample { let x: Int, y: Int, r: Float, g: Float, b: Float }
        let width: Int
        let height: Int
        let inside: [Sample]
        let ring: [Sample]

        init?(_ logo: CGImage, width: Int, maxSamples: Int = .max) {
            guard width >= 6, let pixels = Pixels(logo, width: width), pixels.height >= 3 else { return nil }
            func alpha(_ x: Int, _ y: Int) -> Float {
                x < 0 || y < 0 || x >= pixels.width || y >= pixels.height ? 0 : pixels.values[(y * pixels.width + x) * 4 + 3]
            }
            func sample(_ x: Int, _ y: Int, colourAt cx: Int, _ cy: Int) -> Sample {
                let i = (cy * pixels.width + cx) * 4
                return Sample(x: x, y: y, r: pixels.values[i], g: pixels.values[i + 1], b: pixels.values[i + 2])
            }
            var inside: [Sample] = [], ring: [Sample] = []
            // The ring sits two pixels out, clear of the resampled edge.
            for y in -2...(pixels.height + 1) {
                for x in -2...(pixels.width + 1) {
                    let a = alpha(x, y)
                    if a > 0.9 {
                        inside.append(sample(x, y, colourAt: x, y))
                    } else if a < 0.1, let (dx, dy) = [(2, 0), (-2, 0), (0, 2), (0, -2)]
                        .first(where: { alpha(x + $0.0, y + $0.1) > 0.6 }) {
                        ring.append(sample(x, y, colourAt: x + dx, y + dy))
                    }
                }
            }
            guard inside.count >= 12, ring.count >= 12 else { return nil }
            func thinned(_ samples: [Sample]) -> [Sample] {
                let step = max(1, samples.count / maxSamples)
                return stride(from: 0, to: samples.count, by: step).map { samples[$0] }
            }
            self.width = pixels.width
            self.height = pixels.height
            self.inside = thinned(inside)
            self.ring = thinned(ring)
        }
    }

    /// Low when the logo sits at this spot: the share of the logo's pixels whose colour
    /// the still misses, plus the share of the pixels around it that look like the logo.
    /// Counting pixels, not averaging them, keeps a flat white logo from fitting any white patch.
    static func logoScore(_ still: Pixels, _ logo: LogoTemplate, x: Int, y: Int) -> Float {
        func shareDiffering(_ samples: [LogoTemplate.Sample]) -> Float? {
            var differing = 0, count = 0
            for s in samples {
                let px = x + s.x, py = y + s.y
                guard px >= 0, py >= 0, px < still.width, py < still.height else { continue }
                let i = (py * still.width + px) * 4
                let difference = abs(still.values[i] - s.r) + abs(still.values[i + 1] - s.g) + abs(still.values[i + 2] - s.b)
                if difference > 0.3 { differing += 1 }
                count += 1
            }
            return count > 0 ? Float(differing) / Float(count) : nil
        }
        guard let missed = shareDiffering(logo.inside), let ring = shareDiffering(logo.ring) else { return 9 }
        return missed + 1 - ring
    }

    static let logoMatchThreshold: Float = 0.4

    static func stillContainsLogo(_ still: CGImage, logo: CGImage) -> Bool {
        bestLogoScore(still, logo: logo) < logoMatchThreshold
    }

    /// A thin, widely spaced wordmark leaves no usable template at the small size, so it gets a second pass at twice the resolution.
    static func bestLogoScore(_ still: CGImage, logo: CGImage) -> Float {
        let score = bestLogoScore(still, logo: logo, coarseWidth: 160, fineWidth: 384)
        return score < 9 ? score : bestLogoScore(still, logo: logo, coarseWidth: 320, fineWidth: 640)
    }

    /// Searches every size from 12% to 80% of the still's width on a small copy,
    /// then refines the best few spots on a larger one.
    private static func bestLogoScore(_ still: CGImage, logo: CGImage, coarseWidth: Int, fineWidth: Int) -> Float {
        guard let coarse = Pixels(still, width: coarseWidth), let fine = Pixels(still, width: fineWidth) else { return 9 }
        var spots: [(score: Float, fraction: CGFloat, x: Int, y: Int)] = []
        var fraction: CGFloat = 0.12
        while fraction <= 0.8 {
            if let template = LogoTemplate(logo, width: Int(CGFloat(coarseWidth) * fraction), maxSamples: 200),
               template.height < coarse.height {
                var best: (score: Float, fraction: CGFloat, x: Int, y: Int) = (9, fraction, 0, 0)
                for y in 0...(coarse.height - template.height) {
                    for x in 0...(coarse.width - template.width) {
                        let score = logoScore(coarse, template, x: x, y: y)
                        if score < best.score { best = (score, fraction, x, y) }
                    }
                }
                spots.append(best)
            }
            fraction *= 1.08
        }
        let ratio = CGFloat(fineWidth) / CGFloat(coarseWidth)
        var best: Float = 9
        for spot in spots.sorted(by: { $0.score < $1.score }).prefix(4) {
            let cx = Int(CGFloat(spot.x) * ratio), cy = Int(CGFloat(spot.y) * ratio)
            var size = spot.fraction / 1.08
            while size <= spot.fraction * 1.08 {
                if let template = LogoTemplate(logo, width: Int(CGFloat(fineWidth) * size)), template.height < fine.height {
                    for y in (cy - 4)...(cy + 4) {
                        for x in (cx - 4)...(cx + 4) { best = min(best, logoScore(fine, template, x: x, y: y)) }
                    }
                }
                size *= 1.015
            }
        }
        return best
    }

    // MARK: - Text

    /// A line of text Vision read, with its height as a fraction of the still's.
    struct RecognizedLine: Equatable {
        let text: String
        let height: CGFloat
    }

    static func recognizedLines(in still: CGImage, width: Int = 768) -> [RecognizedLine] {
        let height = Int((CGFloat(width) * CGFloat(still.height) / CGFloat(max(1, still.width))).rounded())
        guard height > 0, let context = bitmap(width: width, height: height) else { return [] }
        context.interpolationQuality = .medium
        context.draw(still, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let copy = context.makeImage() else { return [] }
        let request = VNRecognizeTextRequest()
        request.usesLanguageCorrection = false
        #if targetEnvironment(simulator)
        // The simulator can only build Vision's models on the CPU.
        for (stage, devices) in (try? request.supportedComputeStageDevices) ?? [:] {
            if let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
        guard (try? VNImageRequestHandler(cgImage: copy).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, height: observation.boundingBox.height) }
        }
    }

    /// Letters and digits only, lowercased and without accents.
    static func compact(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The spellings of a title that artwork commonly shows: the full title, without a
    /// leading article ("Matrix" for "The Matrix"), and its part before a colon or dash
    /// ("Avengers" for "Avengers: Infinity War"). A short part is too generic to count.
    static func titleForms(_ title: String) -> [[Character]] {
        func stripped(_ text: String) -> String {
            let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
            for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) { return String(lowered.dropFirst(article.count)) }
            return lowered
        }
        let main = title.components(separatedBy: CharacterSet(charactersIn: ":\u{2013}\u{2014}")).first ?? title
        var forms: [[Character]] = []
        for text in [title, stripped(title), main, stripped(main)] {
            let form = Array(compact(text))
            if form.count >= (text == title ? 1 : 6), !forms.contains(form) { forms.append(form) }
        }
        return forms
    }

    /// Whether the title can be read in the still's large text, allowing a misread
    /// letter in four (logos are stylised). A short title must fill a line on its own,
    /// and a four-letter one must read exactly.
    static func textShowsTitle(_ lines: [RecognizedLine], title: String) -> Bool {
        let large = lines.filter { $0.height >= 0.03 }
        // Lines in reading order, so a title split over two lines still reads through.
        let text = Array(large.map { compact($0.text) }.joined())
        return titleForms(title).contains { target in
            if target.count <= 3 {
                return large.contains { $0.height >= 0.1 && Array(compact($0.text)) == target }
            }
            return substringDistance(target, in: text) <= (target.count <= 4 ? 0 : target.count / 4)
        }
    }

    /// Fewest edits turning `pattern` into some substring of `text`.
    static func substringDistance(_ pattern: [Character], in text: [Character]) -> Int {
        var previous = Array(0...pattern.count)
        var best = previous[pattern.count]
        for character in text {
            var current = [0]
            for (i, p) in pattern.enumerated() {
                current.append(min(previous[i] + (p == character ? 0 : 1), previous[i + 1] + 1, current[i] + 1))
            }
            best = min(best, current[pattern.count])
            previous = current
        }
        return best
    }
}
