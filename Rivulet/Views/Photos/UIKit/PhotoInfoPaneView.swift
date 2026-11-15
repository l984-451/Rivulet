// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoInfoPaneView.swift
//  Rivulet
//
//  The viewer's info pane, laid out as the player's Info card: a map of the
//  photo's place (else the photo) in the poster slot, the day taken, camera
//  and exposure, size and file name, and Favorite, the pane's only focus target.
//

import MapKit
import UIKit

@MainActor
final class PhotoInfoPaneView: UIView {
    private typealias Metrics = PlayerInfoCardView.Metrics

    let favoriteButton = PlayerPaneActionButton(title: String(localized: "Favorite"), symbol: "heart")
    var onFavorite: (() -> Void)?

    private let artView = UIImageView()
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let metaLabel = UILabel()
    private var artTask: Task<Void, Never>?
    /// What the poster slot shows now, so a repeat `show` of the same photo leaves it alone.
    private var artKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let card = UIView()
        let glass = makePaneGlass(cornerRadius: Metrics.radius)

        artView.contentMode = .scaleAspectFill
        artView.clipsToBounds = true
        artView.layer.cornerRadius = Metrics.posterRadius
        artView.layer.cornerCurve = .continuous
        artView.backgroundColor = UIColor.white.withAlphaComponent(0.08)

        titleLabel.font = .systemFont(ofSize: 31, weight: .bold)
        titleLabel.textColor = .white
        summaryLabel.font = .systemFont(ofSize: 25, weight: .medium)
        summaryLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        summaryLabel.numberOfLines = 2
        metaLabel.font = .systemFont(ofSize: 25, weight: .medium)
        metaLabel.textColor = .white

        favoriteButton.onPress = { [weak self] in self?.onFavorite?() }

        addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        [glass, artView, titleLabel, summaryLabel, metaLabel, favoriteButton].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let inset = PlayerRailView.sideInset
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            card.heightAnchor.constraint(equalToConstant: Metrics.height),
            glass.topAnchor.constraint(equalTo: card.topAnchor),
            glass.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            artView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.poster.minX),
            artView.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.poster.minY),
            artView.widthAnchor.constraint(equalToConstant: Metrics.poster.width),
            artView.heightAnchor.constraint(equalToConstant: Metrics.poster.height),

            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.textX),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.titleTop),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: favoriteButton.leadingAnchor, constant: -40),

            summaryLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.textX),
            summaryLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.summaryTop),
            summaryLabel.widthAnchor.constraint(equalToConstant: Metrics.summaryWidth),

            metaLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.textX),
            metaLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.metaTop),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: favoriteButton.leadingAnchor, constant: -40),

            favoriteButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.actionTrailing),
            favoriteButton.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.actionTop),
            favoriteButton.widthAnchor.constraint(equalToConstant: Metrics.actionWidth)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `item`'s details and favorite, and its map (else the photo) when that changed.
    func show(_ item: PhotoItem) {
        let card = PhotoInfoLines.card(for: item)
        titleLabel.text = card.title
        summaryLabel.text = card.summary
        metaLabel.text = card.meta
        favoriteButton.set(title: item.isFavorite ? String(localized: "Unfavorite") : String(localized: "Favorite"),
                           symbol: item.isFavorite ? "heart.fill" : "heart")
        showArt(item)
    }

    private func showArt(_ item: PhotoItem) {
        let key = item.coordinate.map { "\($0.latitude),\($0.longitude)" } ?? item.thumbnail?.absoluteString
        guard key != artKey else { return }
        artKey = key
        artTask?.cancel()
        artView.image = nil
        if let coordinate = item.coordinate {
            let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: center, latitudinalMeters: 2000, longitudinalMeters: 2000)
            options.size = Metrics.poster.size
            options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
            artTask = Task { [weak self] in
                let snapshot = try? await MKMapSnapshotter(options: options).start()
                guard !Task.isCancelled, let self else { return }
                // A failed snapshot is tried again on the next visit.
                guard let snapshot else { artKey = nil; return }
                artView.image = Self.pinned(snapshot, at: center)
            }
        } else if let url = item.thumbnail {
            artTask = Task { [weak self] in
                let image = await ImageCacheManager.shared.image(for: url)
                guard !Task.isCancelled else { return }
                self?.artView.image = image
            }
        }
    }

    /// The snapshot with a pin drawn on the place.
    private static func pinned(_ snapshot: MKMapSnapshotter.Snapshot, at center: CLLocationCoordinate2D) -> UIImage {
        UIGraphicsImageRenderer(size: snapshot.image.size).image { _ in
            snapshot.image.draw(at: .zero)
            let pin = UIImage(systemName: "mappin.circle.fill")?
                .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            let side: CGFloat = 32, point = snapshot.point(for: center)
            pin?.draw(in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
        }
    }
}
