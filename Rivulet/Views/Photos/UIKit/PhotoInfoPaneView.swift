// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoInfoPaneView.swift
//  Rivulet
//
//  The viewer's info pane: a photo's lines, a small map when it has a place,
//  and a Favorite button, the pane's only focus target. Drawn as the player's Info card.
//

import MapKit
import UIKit

@MainActor
final class PhotoInfoPaneView: UIView {
    static let mapSize = CGSize(width: 320, height: 180)
    private static let cardPadding: CGFloat = 40

    let favoriteButton = UIButton(type: .system)
    var onFavorite: (() -> Void)?

    private let lineStack = UIStackView()
    private let mapView = UIImageView()
    private var mapTask: Task<Void, Never>?
    private var mapCoordinate: PhotoCoordinate?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let card = makePaneGlass(cornerRadius: PlayerInfoCardView.Metrics.radius)

        lineStack.axis = .vertical
        lineStack.spacing = 8
        lineStack.alignment = .leading

        mapView.contentMode = .scaleAspectFill
        mapView.clipsToBounds = true
        mapView.layer.cornerRadius = 16
        mapView.layer.cornerCurve = .continuous
        mapView.isHidden = true

        favoriteButton.addAction(UIAction { [weak self] _ in self?.onFavorite?() }, for: .primaryActionTriggered)

        let side = UIStackView(arrangedSubviews: [mapView, favoriteButton])
        side.axis = .vertical
        side.spacing = 24
        side.alignment = .trailing
        let row = UIStackView(arrangedSubviews: [lineStack, side])
        row.alignment = .center
        row.distribution = .equalSpacing
        [card, row].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let inset = PlayerRailView.sideInset, padding = Self.cardPadding
        NSLayoutConstraint.activate([
            mapView.widthAnchor.constraint(equalToConstant: Self.mapSize.width),
            mapView.heightAnchor.constraint(equalToConstant: Self.mapSize.height),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: PlayerInfoCardView.Metrics.height),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -padding),
            row.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor, constant: padding),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `item`'s lines, its favorite, and its map when the place changed.
    func show(_ item: PhotoItem) {
        lineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, line) in PhotoInfoLines.lines(for: item).enumerated() {
            let label = UILabel()
            label.text = line
            // The player's Info card: a 31pt bold title over 25pt medium lines.
            label.font = .systemFont(ofSize: index == 0 ? 31 : 25, weight: index == 0 ? .bold : .medium)
            label.textColor = .white
            lineStack.addArrangedSubview(label)
        }
        favoriteButton.setTitle(item.isFavorite ? String(localized: "Unfavorite") : String(localized: "Favorite"),
                                for: .normal)
        favoriteButton.setImage(UIImage(systemName: item.isFavorite ? "heart.fill" : "heart"), for: .normal)
        showMap(item.coordinate)
    }

    private func showMap(_ coordinate: PhotoCoordinate?) {
        guard coordinate != mapCoordinate else { return }
        mapCoordinate = coordinate
        mapTask?.cancel()
        mapView.image = nil
        mapView.isHidden = coordinate == nil
        guard let coordinate else { return }
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: 2000, longitudinalMeters: 2000)
        options.size = Self.mapSize
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        mapTask = Task { [weak self] in
            let snapshot = try? await MKMapSnapshotter(options: options).start()
            guard !Task.isCancelled, let self else { return }
            // A failed snapshot is tried again on the next visit.
            guard let snapshot else { mapCoordinate = nil; return }
            mapView.image = Self.pinned(snapshot, at: center)
        }
    }

    /// The snapshot with a pin drawn on the place.
    private static func pinned(_ snapshot: MKMapSnapshotter.Snapshot, at center: CLLocationCoordinate2D) -> UIImage {
        UIGraphicsImageRenderer(size: snapshot.image.size).image { _ in
            snapshot.image.draw(at: .zero)
            let pin = UIImage(systemName: "mappin.circle.fill")?
                .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
            let side: CGFloat = 36, point = snapshot.point(for: center)
            pin?.draw(in: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side))
        }
    }
}
