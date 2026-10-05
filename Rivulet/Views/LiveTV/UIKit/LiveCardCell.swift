// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveCardCell.swift
//  Rivulet
//
//  The 16:9 card of the Browse layout and multiview's "Add More" row: the
//  programme's landscape art (the channel's logo when there is none), a LIVE
//  pill or start time, the channel's logo in the corner, and the title over a
//  gradient, with how far through the programme is.
//

import UIKit

/// One card's content.
struct LiveCardItem: Hashable {
    enum Kind: Hashable {
        /// A channel and what is on it now.
        case channel
        /// A programme starting soon on `channel`.
        case upcoming
        /// A recording Plex or Dispatcharr has lined up.
        case recording
    }

    let id: String
    let kind: Kind
    let channel: UnifiedChannel?
    let program: UnifiedProgram?
    let recording: LiveTVScheduledRecording?
    /// The programme is set to record (see `markingRecordings`).
    var setToRecord = false

    static func channel(_ channel: UnifiedChannel, program: UnifiedProgram?, section: String) -> LiveCardItem {
        LiveCardItem(id: "\(section)|\(channel.id)", kind: .channel, channel: channel,
                     program: program, recording: nil)
    }

    /// An upcoming card's start: the time alone today, with the weekday after.
    static func startLabel(_ program: UnifiedProgram, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = program.eventStart
        return calendar.isDate(start, inSameDayAs: now)
            ? start.formatted(.dateTime.hour().minute())
            : start.formatted(.dateTime.weekday().hour().minute())
    }

    static func upcoming(_ program: UnifiedProgram, on channel: UnifiedChannel, section: String = "soon") -> LiveCardItem {
        LiveCardItem(id: "\(section)|\(program.id)", kind: .upcoming, channel: channel,
                     program: program, recording: nil)
    }

    static func recording(_ recording: LiveTVScheduledRecording, channel: UnifiedChannel?) -> LiveCardItem {
        LiveCardItem(id: "rec|\(recording.id)", kind: .recording, channel: channel,
                     program: nil, recording: recording)
    }
}

extension Array where Element == LiveCardItem {
    /// Each card's `setToRecord`, from the store's schedule. Recording cards
    /// already say so themselves.
    func markingRecordings(_ store: LiveTVDataStore) -> [LiveCardItem] {
        map { item in
            guard item.kind != .recording, let program = item.program else { return item }
            var marked = item
            marked.setToRecord = store.activeRecording(for: program) != nil
            return marked
        }
    }

    /// First of each id. A diffable snapshot traps on a repeated identifier,
    /// and a merged lineup can list a channel twice.
    func uniquedById() -> [LiveCardItem] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

final class LiveCardCell: UICollectionViewCell {
    static let reuseID = "LiveCardCell"
    static let aspect: CGFloat = 9.0 / 16.0

    private let card = UIView()
    /// A very blurred colour field behind a card with no wide art: the
    /// programme's square or poster art, else the channel's logo.
    private let colorField = UIImageView()
    private let artView = UIImageView()
    private let logoFallback = UIImageView()
    private let gradient = CAGradientLayer()
    private let pill = UILabel()
    private let pillBackground = UIView()
    private let cornerLogo = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressWidth: NSLayoutConstraint!

    private var artTask: Task<Void, Never>?
    private var logoTask: Task<Void, Never>?
    private var fieldTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?
    private var artURL: URL?
    private var logoURL: URL?
    private var fieldURL: URL?

    private static let timeFormat = Date.FormatStyle.dateTime.hour().minute()

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.backgroundColor = UIColor(white: 0.14, alpha: 1)
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        // Shadow on the unclipped content view, so the lift reads on focus.
        contentView.layer.shadowColor = UIColor.black.cgColor
        contentView.layer.shadowOpacity = 0
        contentView.layer.shadowRadius = 24
        contentView.layer.shadowOffset = CGSize(width: 0, height: 16)

        // A few pixels stretched with linear filtering is the blur.
        colorField.contentMode = .scaleToFill
        colorField.layer.magnificationFilter = .linear
        artView.contentMode = .scaleAspectFill
        artView.clipsToBounds = true
        logoFallback.contentMode = .scaleAspectFit
        [colorField, artView, logoFallback].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }

        gradient.colors = [UIColor.black.withAlphaComponent(0).cgColor,
                           UIColor.black.withAlphaComponent(0.8).cgColor]
        gradient.locations = [0.35, 1]
        card.layer.addSublayer(gradient)

        pillBackground.layer.cornerRadius = 8
        pillBackground.layer.cornerCurve = .continuous
        pill.font = .systemFont(ofSize: 18, weight: .bold)
        pill.textColor = .white
        cornerLogo.contentMode = .scaleAspectFit
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .white
        detailLabel.font = .systemFont(ofSize: 18, weight: .medium)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.3)
        progressTrack.layer.cornerRadius = 2
        progressFill.backgroundColor = .white
        progressFill.layer.cornerRadius = 2

        [pillBackground, pill, cornerLogo, titleLabel, detailLabel, progressTrack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        progressWidth = progressFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            colorField.topAnchor.constraint(equalTo: card.topAnchor),
            colorField.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            colorField.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            colorField.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            artView.topAnchor.constraint(equalTo: card.topAnchor),
            artView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            artView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            artView.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            logoFallback.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            logoFallback.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: -18),
            logoFallback.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.42),
            logoFallback.heightAnchor.constraint(equalTo: card.heightAnchor, multiplier: 0.36),

            pill.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            pill.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            pillBackground.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: -10),
            pillBackground.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 10),
            pillBackground.topAnchor.constraint(equalTo: pill.topAnchor, constant: -5),
            pillBackground.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: 5),

            cornerLogo.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            cornerLogo.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            cornerLogo.widthAnchor.constraint(equalToConstant: 70),
            cornerLogo.heightAnchor.constraint(equalToConstant: 36),

            progressTrack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            progressTrack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            progressTrack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressWidth,

            detailLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
            detailLabel.bottomAnchor.constraint(equalTo: progressTrack.topAnchor, constant: -8),

            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -16),
            titleLabel.bottomAnchor.constraint(equalTo: detailLabel.topAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// How far through the programme, 0...1; applied against the track's
    /// real width on layout.
    private var progressFraction: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = card.bounds
        CATransaction.commit()
        let width = progressTrack.bounds.width * progressFraction
        if abs(progressWidth.constant - width) > 0.5 { progressWidth.constant = width }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artTask?.cancel()
        logoTask?.cancel()
        fieldTask?.cancel()
        measureTask?.cancel()
        artTask = nil
        logoTask = nil
        fieldTask = nil
        measureTask = nil
        artURL = nil
        logoURL = nil
        fieldURL = nil
        colorField.image = nil
        artView.image = nil
        logoFallback.image = nil
        cornerLogo.image = nil
    }

    func configure(_ item: LiveCardItem, now: Date = Date()) {
        let channel = item.channel
        let program = item.program

        // Text
        switch item.kind {
        case .channel:
            titleLabel.text = program?.displayTitle ?? channel?.name ?? "Live"
            detailLabel.text = [channel?.channelNumber.map(String.init), channel?.name]
                .compactMap { $0 }
                .joined(separator: " · ")
            // On now and set to record means it is recording. LIVE is for
            // live airings only, never replays.
            setPill(item.setToRecord ? "● REC" : program?.isLiveAiring == true ? "▶ LIVE" : nil, color: .systemRed)
        case .upcoming:
            titleLabel.text = program?.displayTitle ?? "Upcoming"
            detailLabel.text = channel?.name
            setPill(program.map { LiveCardItem.startLabel($0, now: now) }, color: UIColor.white.withAlphaComponent(0.25),
                    recordDot: item.setToRecord)
        case .recording:
            let recording = item.recording
            titleLabel.text = recording.map { UnifiedProgram.displayTitle($0.title) } ?? "Recording"
            detailLabel.text = [recording?.subtitle, recording?.channelName]
                .compactMap { $0 }
                .joined(separator: " · ")
            if recording?.status == .recording {
                setPill("● REC", color: .systemRed)
            } else {
                setPill(recording.map { $0.startTime.formatted(Self.timeFormat) },
                        color: UIColor.white.withAlphaComponent(0.25), recordDot: true)
            }
        }

        // Progress through what is on now.
        var progress: Double?
        if item.kind == .channel, let program, program.endTime > program.startTime,
           program.startTime <= now, program.endTime > now {
            progress = now.timeIntervalSince(program.startTime) / program.endTime.timeIntervalSince(program.startTime)
        }
        progressTrack.isHidden = progress == nil
        progressFraction = CGFloat(min(max(progress ?? 0, 0), 1))
        setNeedsLayout()

        // Art: the programme's own 16:9 image (its icon counts once measured
        // wide), else the channel's logo over a blurred field of the
        // programme's other art, or of the logo itself.
        let art = EPGImageClassifier.shared.wideArt(for: program) ?? item.recording?.posterURL
        let logo = channel?.logoURL
        load(art: art)
        load(logo: logo, asFallback: art == nil)
        load(field: art == nil ? (program?.posterURL ?? program?.iconURL ?? logo) : nil)
        measure(art == nil ? program?.iconURL : nil, then: item)
    }

    /// Measures an icon the EPG gave no size for, and redraws the card once it
    /// proves wide (Dispatcharr's feed declares no icon sizes).
    private func measure(_ icon: URL?, then item: LiveCardItem) {
        measureTask?.cancel()
        guard let icon, EPGImageClassifier.shared.kind(for: icon) == nil else { return }
        measureTask = Task { [weak self] in
            let kind = await EPGImageClassifier.shared.classify(icon) {
                await ImageCacheManager.shared.image(for: icon, quality: .thumb)?.size
            }
            guard let self, !Task.isCancelled, kind == .landscape else { return }
            self.configure(item)
        }
    }

    /// `recordDot` puts the guide's red record dot before `text`: scheduled
    /// to record, not yet recording.
    private func setPill(_ text: String?, color: UIColor, recordDot: Bool = false) {
        let label = NSMutableAttributedString()
        if recordDot, text != nil {
            label.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: UIColor.systemRed]))
        }
        label.append(NSAttributedString(string: text ?? "", attributes: [.foregroundColor: UIColor.white]))
        label.addAttribute(.font, value: pill.font as Any, range: NSRange(location: 0, length: label.length))
        pill.attributedText = label
        pill.isHidden = text == nil
        pillBackground.isHidden = text == nil
        pillBackground.backgroundColor = color
    }

    private func load(art url: URL?) {
        guard url != artURL else { return }
        artTask?.cancel()
        artURL = url
        artView.image = nil
        guard let url else { return }
        artTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard let self, !Task.isCancelled, self.artURL == url else { return }
            self.artView.image = image
        }
    }

    private func load(field url: URL?) {
        guard url != fieldURL else { return }
        fieldTask?.cancel()
        fieldURL = url
        colorField.image = nil
        guard let url else { return }
        fieldTask = Task { [weak self] in
            let field = await Self.colorField(for: url)
            guard let self, !Task.isCancelled, self.fieldURL == url else { return }
            self.colorField.image = field
        }
    }

    private static let fieldCache = NSCache<NSURL, UIImage>()

    private static func colorField(for url: URL) async -> UIImage? {
        if let cached = fieldCache.object(forKey: url as NSURL) { return cached }
        guard let source = await ImageCacheManager.shared.image(for: url, quality: .thumb)?.cgImage else { return nil }
        let field = await Task.detached(priority: .utility) { colorField(from: source) }.value
        if let field { fieldCache.setObject(field, forKey: url as NSURL) }
        return field
    }

    /// `source` reduced to a 4x3 field of its colours, dimmed so white text
    /// reads over it. Each cell is an alpha-weighted mean, so a logo on a
    /// transparent background gives the logo's colour; a nearly empty cell
    /// takes the whole image's.
    nonisolated static func colorField(from source: CGImage) -> UIImage? {
        let (sw, sh, fw, fh) = (24, 18, 4, 3)
        let dim = 0.55
        var px = [UInt8](repeating: 0, count: sw * sh * 4)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: sw, height: sh, bitsPerComponent: 8,
                                      bytesPerRow: sw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            let scale = max(CGFloat(sw) / CGFloat(source.width), CGFloat(sh) / CGFloat(source.height))
            let w = CGFloat(source.width) * scale, h = CGFloat(source.height) * scale
            ctx.draw(source, in: CGRect(x: (CGFloat(sw) - w) / 2, y: (CGFloat(sh) - h) / 2, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        func sums(_ xs: Range<Int>, _ ys: Range<Int>) -> (r: Double, g: Double, b: Double, a: Double) {
            var r = 0.0, g = 0.0, b = 0.0, a = 0.0
            for y in ys {
                for x in xs {
                    let i = (y * sw + x) * 4
                    r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]); a += Double(px[i + 3])
                }
            }
            return (r, g, b, a)
        }
        let whole = sums(0..<sw, 0..<sh)
        guard whole.a > 0 else { return nil }

        let (bw, bh) = (sw / fw, sh / fh)
        var out = [UInt8](repeating: 255, count: fw * fh * 4)
        for fy in 0..<fh {
            for fx in 0..<fw {
                let cell = sums(fx * bw..<(fx + 1) * bw, fy * bh..<(fy + 1) * bh)
                let s = cell.a > Double(bw * bh) * 255 * 0.15 ? cell : whole
                let o = (fy * fw + fx) * 4
                // Premultiplied sums over the alpha sum: the straight colour.
                out[o] = UInt8(min(255, s.r / s.a * 255 * dim))
                out[o + 1] = UInt8(min(255, s.g / s.a * 255 * dim))
                out[o + 2] = UInt8(min(255, s.b / s.a * 255 * dim))
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: fw, height: fh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: fw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// The logo goes big in the middle when there is no art, and small in
    /// the corner when there is.
    private func load(logo url: URL?, asFallback: Bool) {
        logoFallback.isHidden = !asFallback
        cornerLogo.isHidden = asFallback
        guard url != logoURL else {
            let image = logoFallback.image ?? cornerLogo.image
            logoFallback.image = asFallback ? image : nil
            cornerLogo.image = asFallback ? nil : image
            return
        }
        logoTask?.cancel()
        logoURL = url
        logoFallback.image = nil
        cornerLogo.image = nil
        guard let url else { return }
        logoTask = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .thumb)
            guard let self, !Task.isCancelled, self.logoURL == url else { return }
            if asFallback {
                self.logoFallback.image = image
            } else {
                self.cornerLogo.image = image
            }
        }
    }

    // MARK: Focus

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        // Shelf cards sit 8pt apart, so the grown card must draw over its
        // neighbours.
        layer.zPosition = focused ? 1 : 0
        coordinator.addCoordinatedAnimations {
            self.transform = focused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
            self.contentView.layer.shadowOpacity = focused ? 0.55 : 0
        }
    }
}
