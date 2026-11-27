// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import CoreGraphics

/// Where a letterboxed picture sits on the screen. Centred is the default; Top and
/// Bottom move a wide film to that edge instead of centring it between black bars,
/// so it lines up with that edge of the screen (a projector's, without moving the
/// lens). Per device: it follows the screen, so it does not sync.
enum PicturePosition: String, CaseIterable, Sendable {
    case center, top, bottom

    static let key = "picturePosition"

    static var current: PicturePosition {
        get { UserDefaults.standard.string(forKey: key).flatMap(PicturePosition.init(rawValue:)) ?? .center }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Whether the player's controls offer the Picture Position menu. Off by default:
    /// it is for projector setups, and Settings has the same choice.
    static let showsInPlayerKey = "picturePositionInPlayer"

    static var showsInPlayer: Bool {
        UserDefaults.standard.object(forKey: showsInPlayerKey) as? Bool ?? false
    }

    var title: String {
        switch self {
        case .center: String(localized: "picturePosition.center", defaultValue: "Center")
        case .top: String(localized: "picturePosition.top", defaultValue: "Top")
        case .bottom: String(localized: "picturePosition.bottom", defaultValue: "Bottom")
        }
    }

    var next: PicturePosition {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// A title's own nudge on top of its Picture Position, in stepper steps (positive is
/// up). For the film whose bars were read a little off, or could not be read at all.
enum PictureNudge {
    /// One step, as a fraction of the screen's height: 3 points of 1080.
    static let step: CGFloat = 1.0 / 360
    /// The most steps either way: 192 points of 1080, one bar of a 2.76:1 film.
    static let maxSteps = 64

    private static let mapKey = "pictureNudgeByMedia"

    /// Stored steps for a media key ("plex:<ratingKey>"). 0 when never adjusted.
    static func steps(forKey key: String) -> Int {
        let map = UserDefaults.standard.dictionary(forKey: mapKey) as? [String: Int]
        return clamped(map?[key] ?? 0)
    }

    /// Persists `steps` for `key`. 0 removes the entry, so the map holds only the
    /// titles that were adjusted.
    static func setSteps(_ steps: Int, forKey key: String) {
        var map = (UserDefaults.standard.dictionary(forKey: mapKey) as? [String: Int]) ?? [:]
        map[key] = steps == 0 ? nil : clamped(steps)
        UserDefaults.standard.set(map, forKey: mapKey)
    }

    static func clamped(_ steps: Int) -> Int { min(max(steps, -maxSteps), maxSteps) }

    /// "0", "+12", "-3": the stepper's centre label.
    static func formatted(_ steps: Int) -> String { steps == 0 ? "0" : String(format: "%+d", steps) }
}

/// The part of a video frame that is picture rather than black bar, as fractions of
/// the frame's height (0 is the top). A UHD remux codes a 2.39:1 film as a 16:9 frame
/// with the bars in it, so the frame's size alone cannot tell where the picture is.
struct LetterboxReading: Equatable, Sendable {
    /// Width over height of the whole frame the reading was taken from.
    var frameAspect: CGFloat
    /// The picture's rows, top and bottom, as fractions of the frame height.
    var picture: ClosedRange<CGFloat>
}

/// Readings kept between launches, so a film played before is placed from its first
/// frame. Derived data: it lives in Caches, where the system may clear it, and the
/// next play measures again.
final class LetterboxReadingStore {
    static let shared = LetterboxReadingStore(
        file: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LetterboxReadings.json"))

    /// The most films remembered; the oldest go first.
    static let limit = 500
    /// Bump when the detector's rules change, so old answers are measured again.
    static let version = 1

    /// One film's answer. `top` and `bottom` are nil for a frame with no bars.
    private struct Entry: Codable {
        var aspect: Double
        var top: Double?
        var bottom: Double?
        var saved: Date
    }

    private let file: URL?
    private var entries: [String: Entry]?

    init(file: URL?) {
        self.file = file
    }

    /// nil when the film has not been measured; a nil reading when it has no bars.
    func reading(for key: String) -> LetterboxReading?? {
        guard let entry = loaded()[Self.versioned(key)] else { return nil }
        guard let top = entry.top, let bottom = entry.bottom, top < bottom else { return .some(nil) }
        return LetterboxReading(frameAspect: entry.aspect, picture: top...bottom)
    }

    func save(_ reading: LetterboxReading?, for key: String) {
        var all = loaded()
        all[Self.versioned(key)] = Entry(aspect: reading.map { Double($0.frameAspect) } ?? 0,
                                         top: reading.map { Double($0.picture.lowerBound) },
                                         bottom: reading.map { Double($0.picture.upperBound) },
                                         saved: Date())
        if all.count > Self.limit {
            for (key, _) in all.sorted(by: { $0.value.saved < $1.value.saved }).prefix(all.count - Self.limit) {
                all.removeValue(forKey: key)
            }
        }
        entries = all
        guard let file, let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Forgets every reading (Settings, Clear All Cache).
    func clear() {
        entries = [:]
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private static func versioned(_ key: String) -> String {
        "\(key)#v\(version)"
    }

    private func loaded() -> [String: Entry] {
        if let entries { return entries }
        let read = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = read
        return read
    }
}

/// Finds a frame's black bars from a few small stills (scrub thumbnails).
enum LetterboxDetector {

    /// A per-still result: the share of the height each bar takes, assuming the
    /// bars are equal (the smaller of the two measured), plus the still's aspect.
    struct Sample: Equatable, Sendable {
        var bar: CGFloat
        var aspect: CGFloat
    }

    /// Ratios a reading snaps to when it is close, so a soft edge in a scaled
    /// thumbnail does not leave a sliver of bar on screen.
    static let knownRatios: [CGFloat] = [1.85, 1.90, 2.00, 2.20, 2.35, 2.39, 2.40, 2.55, 2.76]
    /// Readings closer than this to a known ratio (relative) snap to it.
    static let snapTolerance: CGFloat = 0.03
    /// Bars thinner than this share of the height are not worth moving the picture for.
    static let minimumBar: CGFloat = 0.02
    /// A still whose bars measure more than this is mostly dark, not letterboxed.
    static let maximumBar: CGFloat = 0.22
    /// Stills needed before a reading is trusted.
    static let minimumSamples = 3
    /// Two stills whose bars differ by no more than this show the same shape.
    static let agreement: CGFloat = 0.012
    /// Stills taken when each one is a decode.
    static let sparseSampleCount = 16

    /// Stills taken when they are cheap: one every half minute, so a film's taller
    /// scenes are seen.
    static func denseSampleCount(duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return sparseSampleCount }
        return min(400, max(sparseSampleCount, Int(duration / 30)))
    }

    /// Luma (0-255) a pixel must exceed to count as picture. Well above 16: a server's
    /// stills can keep video-range black, which is 16, not 0.
    static let brightLevel: UInt8 = 56
    /// A row whose mean is above this is picture, however few bright pixels it has.
    static let rowMeanLevel = 28

    /// Where in the runtime to take stills: spread through the film, clear of
    /// logos at the start and credits at the end.
    static func sampleTimes(duration: TimeInterval, count: Int = sparseSampleCount) -> [TimeInterval] {
        guard duration.isFinite, duration > 60, count > 0 else { return [] }
        return (0..<count).map { i in duration * (0.03 + 0.89 * Double(i) / Double(max(1, count - 1))) }
    }

    /// Measures one still. nil for a still that is all dark or has no rows.
    static func sample(_ image: CGImage) -> Sample? {
        let width = min(image.width, 480)
        guard width > 0, image.width > 0 else { return nil }
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return sample(luma: pixels, width: width, height: height)
    }

    /// Measures one still from 8-bit luma, row-major from the top.
    static func sample(luma: [UInt8], width: Int, height: Int) -> Sample? {
        guard width > 0, height > 0, luma.count >= width * height else { return nil }
        let brightNeeded = max(2, width / 50)
        func isPicture(_ row: Int) -> Bool {
            var sum = 0, bright = 0
            let start = row * width
            for x in 0..<width {
                let value = luma[start + x]
                sum += Int(value)
                if value > brightLevel { bright += 1 }
            }
            return bright >= brightNeeded || sum / width > rowMeanLevel
        }
        guard let first = (0..<height).first(where: isPicture),
              let last = (0..<height).reversed().first(where: isPicture) else { return nil }
        let top = CGFloat(first) / CGFloat(height)
        let bottom = CGFloat(height - 1 - last) / CGFloat(height)
        return Sample(bar: min(top, bottom), aspect: CGFloat(width) / CGFloat(height))
    }

    /// Combines stills into one reading. nil when there are too few usable stills or
    /// no bars worth moving for.
    ///
    /// Dark scenes make the bars look taller and never shorter, so the reading is the
    /// tallest picture that two stills agree on. A film that changes shape (IMAX scenes
    /// in a scope film) is placed by its tallest scenes, so none of them is cut off.
    static func reading(from samples: [Sample]) -> LetterboxReading? {
        let usable = samples.filter { $0.bar <= maximumBar }.sorted { $0.bar < $1.bar }
        guard usable.count >= minimumSamples else { return nil }
        let pick: Sample
        if let second = usable.indices.dropFirst().first(where: { usable[$0].bar - usable[$0 - 1].bar <= agreement }) {
            // The stills of that shape, and the middle of them: one soft edge does not set it.
            let first = second - 1
            let same = usable[first...].prefix { $0.bar - usable[first].bar <= agreement }
            pick = same[first + (same.count - 1) / 2]
        } else {
            // No two agree: lean to the smaller bars.
            pick = usable[usable.count / 3]
        }
        guard pick.bar >= minimumBar, pick.aspect > 0 else { return nil }
        var share = 1 - 2 * pick.bar
        let ratio = pick.aspect / share
        if let known = knownRatios.min(by: { abs($0 - ratio) < abs($1 - ratio) }),
           abs(known - ratio) / known <= snapTolerance {
            share = pick.aspect / known
        }
        guard share > 0, share < 1 else { return nil }
        let top = (1 - share) / 2
        return LetterboxReading(frameAspect: pick.aspect, picture: top...(top + share))
    }
}

/// Where the video frame and its picture land in a container, after the Picture
/// Position shift. The video surface moves by `shift`; captions place against `picture`.
struct PictureLayout: Equatable, Sendable {
    /// The whole video frame (bars it codes included), shifted.
    var frame: CGRect
    /// The picture inside it, shifted.
    var picture: CGRect
    /// How far the frame moves down from centred (negative is up), nudge included.
    var shift: CGFloat

    static func make(container: CGSize,
                     videoSize: CGSize,
                     fillsScreen: Bool,
                     position: PicturePosition,
                     letterbox: LetterboxReading?,
                     nudge: Int = 0) -> PictureLayout {
        guard container.width > 0, container.height > 0 else {
            return PictureLayout(frame: .zero, picture: .zero, shift: 0)
        }
        // The frame's shape: the item's own size, else the stills', else the container's.
        let aspect: CGFloat
        if videoSize.width > 0, videoSize.height > 0 {
            aspect = videoSize.width / videoSize.height
        } else if let letterbox, letterbox.frameAspect > 0 {
            aspect = letterbox.frameAspect
        } else {
            aspect = container.width / container.height
        }
        let fitWidth = container.width, fitHeight = container.width / aspect
        let scale = fillsScreen
            ? max(1, container.height / fitHeight)
            : min(1, container.height / fitHeight)
        let width = fitWidth * scale, height = fitHeight * scale
        var frame = CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2,
                           width: width, height: height)
        var picture = frame
        // Only a letterboxed reading that agrees with the frame's shape is trusted:
        // one taken from a cropped file's stills measures no bars and is nil anyway.
        if let letterbox, abs(letterbox.frameAspect - aspect) / aspect < 0.05 {
            picture = CGRect(x: frame.minX, y: frame.minY + letterbox.picture.lowerBound * height,
                             width: width,
                             height: (letterbox.picture.upperBound - letterbox.picture.lowerBound) * height)
        }
        var shift: CGFloat = 0
        if !fillsScreen, picture.height < container.height - 1 {
            switch position {
            case .center: shift = 0
            case .top: shift = -picture.minY
            case .bottom: shift = container.height - picture.maxY
            }
        }
        // The title's own nudge goes on top, and may pass the edge the reading found:
        // it is there for when the reading is wrong.
        if !fillsScreen { shift -= CGFloat(PictureNudge.clamped(nudge)) * PictureNudge.step * container.height }
        shift = shift.rounded()
        frame.origin.y += shift
        picture.origin.y += shift
        return PictureLayout(frame: frame, picture: picture, shift: shift)
    }
}
