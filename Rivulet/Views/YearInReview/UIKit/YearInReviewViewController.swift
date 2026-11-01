// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  YearInReviewViewController.swift
//  Rivulet
//
//  The Year in Review pages, full screen. Left and Right page, Select goes on
//  (and closes from the last page), Menu closes. Pages about a title sit on its
//  artwork; the rest on the blurred welcome R, which runs behind every page.
//

import UIKit

@MainActor
final class YearInReviewViewController: UIViewController {
    private static let dissolve: TimeInterval = 0.45
    private static let margin: CGFloat = 120

    private let review: YearInReview
    private let pages: [YearInReview.Page]
    private let serverURL: String
    private let token: String
    private var index = 0

    private let glow = WelcomeGlowView(style: .blurred)
    private let dim = UIView()
    private var pageView: UIView?
    private let dots = UIStackView()
    /// The only focus target: presses reach a focused view, and the pages have no other.
    private let anchor = PreviewFocusAnchorView()
    private var input: DirectionalInputBinding?

    init(review: YearInReview, serverURL: String, token: String) {
        self.review = review
        self.pages = review.pages
        self.serverURL = serverURL
        self.token = token
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for layer in [glow, dim] as [UIView] {
            layer.frame = view.bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(layer)
        }
        dim.backgroundColor = UIColor(white: 0, alpha: 0.3)

        dots.axis = .horizontal
        dots.spacing = 12
        dots.alignment = .center
        dots.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dots)
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -64),
            dots.heightAnchor.constraint(equalToConstant: 10)
        ])
        view.addSubview(anchor)

        input = DirectionalInputBinding(view: view, directions: [.left, .right],
                                        onTap: { [weak self] in self?.step($0 == .right ? 1 : -1) })
        for (press, action) in [(UIPress.PressType.select, #selector(selectPressed)),
                                (.menu, #selector(close))] {
            let tap = UITapGestureRecognizer(target: self, action: action)
            tap.allowedPressTypes = [NSNumber(value: press.rawValue)]
            view.addGestureRecognizer(tap)
        }
        var first = 0
        #if DEBUG
        // `-YearInReviewPage N` opens on page N.
        first = min(max(UserDefaults.standard.integer(forKey: "YearInReviewPage"), 0), pages.count - 1)
        #endif
        show(first, animated: false)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [anchor] }

    // MARK: - Input

    private func step(_ by: Int) {
        let next = index + by
        guard pages.indices.contains(next) else { return }
        show(next, animated: true)
    }

    @objc private func selectPressed() {
        if index == pages.count - 1 { close() } else { step(1) }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - Pages

    private func show(_ newIndex: Int, animated: Bool) {
        index = newIndex
        let old = pageView
        let page = makePage(pages[newIndex])
        page.frame = view.bounds
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(page, belowSubview: dots)
        pageView = page
        updateDots()
        guard animated else { old?.removeFromSuperview(); return }
        page.alpha = 0
        UIView.animate(withDuration: Self.dissolve, animations: {
            page.alpha = 1
            old?.alpha = 0
        }, completion: { _ in old?.removeFromSuperview() })
    }

    private func updateDots() {
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in pages.indices {
            let dot = UIView()
            dot.layer.cornerRadius = 5
            dot.backgroundColor = i == index ? .white : UIColor(white: 1, alpha: 0.4)
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: i == index ? 32 : 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
            dots.addArrangedSubview(dot)
        }
    }

    private func makePage(_ page: YearInReview.Page) -> UIView {
        let year = review.year
        switch page {
        case .intro:
            return centered(eyebrow: nil, headline: String(localized: "Your \(year)"), headlineSize: 160,
                            detail: String(localized: "A look back at what you watched"))
        case .started(let title):
            var detail = title.date.map(Self.dateAndTime) ?? ""
            if let episode = title.detail { detail = String(localized: "“\(episode)”, \(detail)") }
            return titled(eyebrow: String(localized: "Your \(year) started with"), title: title.name, detail: detail, art: title.art)
        case .hours:
            return hoursPage()
        case .topShow(let title):
            return titled(eyebrow: String(localized: "Your top show"), title: title.name, detail: title.detail, art: title.art)
        case .topMovies:
            return topMoviesPage()
        case .biggestDay(let day):
            let hours = day.hours.formatted(.number.precision(.fractionLength(1)))
            let detail = day.topTitle.map { String(localized: "\(hours) hours, mostly \($0)") } ?? String(localized: "\(hours) hours")
            return centered(eyebrow: String(localized: "Your biggest day"), headline: Self.dayFormatter.string(from: day.date),
                            headlineSize: 110, detail: detail)
        case .whenYouWatch:
            return whenYouWatchPage()
        case .topArtist(let title):
            return titled(eyebrow: String(localized: "Your top artist"), title: title.name,
                          detail: String(localized: "\(title.plays) plays"), art: title.art)
        case .outro:
            let counts = [review.movieCount > 0 ? String(localized: "\(review.movieCount) movies") : nil,
                          review.episodeCount > 0 ? String(localized: "\(review.episodeCount) episodes") : nil,
                          review.songCount > 0 ? String(localized: "\(review.songCount) songs") : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
            return centered(eyebrow: counts, headline: String(localized: "That was your \(year)"), headlineSize: 120,
                            detail: String(localized: "See you in \(year + 1)"))
        }
    }

    // MARK: Page layouts

    /// A title's page: its artwork full bleed (the glow when it has none), the text bottom leading.
    private func titled(eyebrow: String, title: String, detail: String?, art: String?) -> UIView {
        let page = UIView()
        if let art, let url = imageURL(art, width: 1920, height: 1080) {
            let image = UIImageView()
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            pin(image, in: page)
            load(url, into: image, quality: .full)
            let side = GradientView(.axial, from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 0.62, y: 0.5),
                                    alphas: [0.88, 0], locations: nil)
            pin(side, in: page)
            let bottom = GradientView(.axial, from: CGPoint(x: 0.5, y: 0.6), to: CGPoint(x: 0.5, y: 1),
                                      alphas: [0, 0.65], locations: nil)
            pin(bottom, in: page)
        }
        let text = stack([label(eyebrow.uppercased(), size: 30, weight: .bold, alpha: 0.72),
                          label(title, size: 132, weight: .heavy, lines: 2),
                          detail.map { label($0, size: 38, weight: .medium, alpha: 0.85) }].compactMap { $0 },
                         spacing: 14, alignment: .leading)
        page.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: Self.margin),
            text.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -Self.margin),
            text.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -170)
        ])
        return page
    }

    private func centered(eyebrow: String?, headline: String, headlineSize: CGFloat, detail: String?) -> UIView {
        let page = UIView()
        let views = [eyebrow.map { label($0.uppercased(), size: 30, weight: .bold, alpha: 0.72) },
                     label(headline, size: headlineSize, weight: .heavy, lines: 2),
                     detail.map { label($0, size: 44, weight: .semibold, alpha: 0.9) }].compactMap { $0 }
        let text = stack(views, spacing: 16, alignment: .center)
        page.addSubview(text)
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            text.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -30),
            text.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -2 * Self.margin)
        ])
        return page
    }

    private func hoursPage() -> UIView {
        let page = UIView()
        let hours = review.hours
        let headline = stack([label(String(localized: "In \(review.year) you watched").uppercased(), size: 30, weight: .bold, alpha: 0.72),
                              label(Int(hours.video.rounded()).formatted(), size: 260, weight: .heavy),
                              label(String(localized: "hours of movies and TV"), size: 48, weight: .semibold, alpha: 0.9)],
                             spacing: 4, alignment: .center)
        let columns = [(hours.tv, String(localized: "hours of TV")), (hours.movies, String(localized: "hours of movies")),
                       (hours.music, String(localized: "hours of music"))]
            .filter { $0.0 >= 1 }
            .map { stack([label(Int($0.0.rounded()).formatted(), size: 72, weight: .bold),
                          label($0.1, size: 28, weight: .semibold, alpha: 0.72)], spacing: 4, alignment: .center) }
        let row = UIStackView(arrangedSubviews: columns)
        row.spacing = 140
        let all = stack([headline, row], spacing: 90, alignment: .center)
        page.addSubview(all)
        NSLayoutConstraint.activate([
            all.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            all.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -30)
        ])
        return page
    }

    private func topMoviesPage() -> UIView {
        let page = UIView()
        guard let first = review.topMovies.first else { return page }
        let headline = first.plays > 1
            ? String(localized: "You watched \(first.name) \(first.plays) times")
            : String(localized: "Your favorite was \(first.name)")
        let posters = review.topMovies.map { movie -> UIView in
            let poster = UIImageView()
            poster.contentMode = .scaleAspectFill
            poster.clipsToBounds = true
            poster.layer.cornerRadius = 12
            poster.layer.cornerCurve = .continuous
            poster.backgroundColor = UIColor(white: 1, alpha: 0.1)
            poster.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                poster.widthAnchor.constraint(equalToConstant: 260),
                poster.heightAnchor.constraint(equalToConstant: 390)
            ])
            if let path = movie.poster, let url = imageURL(path, width: 520, height: 780) {
                load(url, into: poster, quality: .thumb)
            }
            let name = label(movie.name, size: 26, weight: .semibold)
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            return stack([poster, name,
                          label(String(localized: "\(movie.plays) plays"), size: 24, weight: .medium, alpha: 0.68)],
                         spacing: 10, alignment: .center)
        }
        let row = UIStackView(arrangedSubviews: posters)
        row.spacing = 60
        row.alignment = .top
        let all = stack([label(String(localized: "Your top movies").uppercased(), size: 30, weight: .bold, alpha: 0.72),
                         label(headline, size: 64, weight: .heavy, lines: 2), row],
                        spacing: 20, alignment: .center)
        all.setCustomSpacing(70, after: all.arrangedSubviews[1])
        page.addSubview(all)
        NSLayoutConstraint.activate([
            all.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            all.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -30),
            all.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -2 * Self.margin)
        ])
        return page
    }

    private func whenYouWatchPage() -> UIView {
        let page = UIView()
        guard let time = review.watchTime else { return page }
        let headline = switch time.part {
        case .morning: String(localized: "You’re a morning watcher")
        case .afternoon: String(localized: "You’re an afternoon watcher")
        case .evening: String(localized: "You’re an evening watcher")
        case .lateNight: String(localized: "You’re a late-night watcher")
        }
        let detail = String(localized: "Your busiest hour is \(Self.hourName(time.peakHour)).")
        let text = stack([label(String(localized: "When you watch").uppercased(), size: 30, weight: .bold, alpha: 0.72),
                          label(headline, size: 96, weight: .heavy),
                          label(detail, size: 36, weight: .medium, alpha: 0.85)],
                         spacing: 12, alignment: .center)

        let peak = max(review.playsByHour.max() ?? 1, 1)
        let bars = review.playsByHour.enumerated().map { hour, plays -> UIView in
            let bar = UIView()
            bar.backgroundColor = hour == time.peakHour ? .white : UIColor(white: 1, alpha: 0.32)
            bar.layer.cornerRadius = 6
            bar.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            bar.translatesAutoresizingMaskIntoConstraints = false
            let height = max(6, 380 * CGFloat(plays) / CGFloat(peak))
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 44),
                bar.heightAnchor.constraint(equalToConstant: height)
            ])
            return bar
        }
        let chart = UIStackView(arrangedSubviews: bars)
        chart.spacing = 16
        chart.alignment = .bottom
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 380).isActive = true

        // One tick label under every sixth bar: 12 AM, 6 AM, 12 PM, 6 PM.
        let ticks = UIView()
        ticks.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(text)
        page.addSubview(chart)
        page.addSubview(ticks)
        for hour in stride(from: 0, to: 24, by: 6) {
            let tick = label(Self.hourName(hour), size: 24, weight: .semibold, alpha: 0.6)
            ticks.addSubview(tick)
            tick.centerXAnchor.constraint(equalTo: bars[hour].centerXAnchor).isActive = true
            tick.topAnchor.constraint(equalTo: ticks.topAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            text.topAnchor.constraint(equalTo: page.topAnchor, constant: 130),
            chart.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            chart.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 70),
            ticks.topAnchor.constraint(equalTo: chart.bottomAnchor, constant: 18),
            ticks.leadingAnchor.constraint(equalTo: chart.leadingAnchor),
            ticks.trailingAnchor.constraint(equalTo: chart.trailingAnchor),
            ticks.heightAnchor.constraint(equalToConstant: 34)
        ])
        return page
    }

    // MARK: Helpers

    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, alpha: CGFloat = 1,
                       lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = UIColor(white: 1, alpha: alpha)
        label.numberOfLines = lines
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func stack(_ views: [UIView], spacing: CGFloat, alignment: UIStackView.Alignment) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = alignment
        stack.translatesAutoresizingMaskIntoConstraints = false
        if alignment == .leading {
            views.compactMap { $0 as? UILabel }.forEach { $0.textAlignment = .natural }
        }
        return stack
    }

    private func pin(_ child: UIView, in parent: UIView) {
        child.frame = parent.bounds
        child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.addSubview(child)
    }

    private func imageURL(_ path: String, width: Int, height: Int) -> URL? {
        PlexNetworkManager.shared.buildThumbnailURL(serverURL: serverURL, authToken: token, thumbPath: path,
                                                    width: width, height: height)
    }

    private func load(_ url: URL, into imageView: UIImageView, quality: ImageQuality) {
        let cache = ImageCacheManager.shared
        if let image = cache.cachedImage(for: url, quality: quality) {
            imageView.image = image
            return
        }
        Task { [weak imageView] in
            let image = await cache.image(for: url, quality: quality)
            guard let imageView else { return }
            UIView.transition(with: imageView, duration: 0.25, options: .transitionCrossDissolve) {
                imageView.image = image
            }
        }
    }

    private static func hourName(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    private static func dateAndTime(_ date: Date) -> String {
        String(localized: "\(date.formatted(.dateTime.month(.wide).day())) at \(date.formatted(date: .omitted, time: .shortened))")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()
}
