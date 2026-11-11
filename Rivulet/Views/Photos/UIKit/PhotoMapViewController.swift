// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoMapViewController.swift
//  Rivulet
//
//  A library's located photos as a list of places over a map. Focus on a row moves
//  the map to that place, Select opens its photos. Right moves onto the map, which
//  then pans and zooms; Select there opens the photos in view, Menu goes back to the list.
//

import MapKit
import UIKit

final class PhotoMapViewController: UIViewController {
    private nonisolated enum Row: Hashable, Sendable {
        case all
        case place(PhotoPlace.ID)
    }

    private static let panelWidth: CGFloat = 720
    /// About 2 km, so a place with one photo isn't framed down to a street.
    private static let minimumSpanMeters: Double = 2000

    private let provider: any PhotoProvider
    private let library: MediaLibrary
    private let mapView = PhotoMapView()
    /// The map area right of the list, leading Right from a row onto the map.
    private let mapGuide = UIFocusGuide()
    private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private lazy var dataSource = makeDataSource()
    /// Holds focus until the first place arrives, so Menu still closes the map.
    private let loadingAnchor = PreviewFocusAnchorView()

    private var located: [PhotoItem] = []
    private var places: [PhotoPlace] = []
    private var names: [PhotoPlace.ID: String] = [:]
    private var attempted: Set<PhotoPlace.ID> = []
    private var loadTask: Task<Void, Never>?
    private var namingTask: Task<Void, Never>?
    private var framed = false
    /// Set once focus moves between rows; until then each page reframes every place.
    private var followsFocus = false

    init(provider: any PhotoProvider, library: MediaLibrary) {
        self.provider = provider
        self.library = library
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        setMapInteractive(false)
        let back = UITapGestureRecognizer(target: self, action: #selector(mapMenuPressed))
        back.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        mapView.addGestureRecognizer(back)
        let select = UITapGestureRecognizer(target: self, action: #selector(mapSelectPressed))
        select.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        mapView.addGestureRecognizer(select)
        mapView.register(PhotoMapAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoMapAnnotationView.reuseID)
        mapView.register(PhotoMapClusterView.self, forAnnotationViewWithReuseIdentifier: PhotoMapClusterView.reuseID)
        view.addSubview(mapView)

        panel.frame = CGRect(x: 0, y: 0, width: Self.panelWidth, height: view.bounds.height)
        panel.autoresizingMask = [.flexibleHeight]
        view.addSubview(panel)
        collectionView.frame = panel.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.delegate = self
        panel.contentView.addSubview(collectionView)
        view.addSubview(loadingAnchor)

        view.addLayoutGuide(mapGuide)
        mapGuide.preferredFocusEnvironments = [mapView]
        NSLayoutConstraint.activate([
            mapGuide.leadingAnchor.constraint(equalTo: panel.trailingAnchor),
            mapGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mapGuide.topAnchor.constraint(equalTo: view.topAnchor),
            mapGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let loader = PhotoMapLoader(provider: provider, library: library)
        loadTask = Task { [weak self] in
            await loader.load { [weak self] items in self?.add(items) }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !framed, !places.isEmpty, mapView.bounds.width > 0 {
            framed = true
            show(located, animated: false)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            loadTask?.cancel()
            namingTask?.cancel()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        places.isEmpty ? [loadingAnchor] : [collectionView]
    }

    // MARK: - Places

    private func add(_ items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        let wasEmpty = places.isEmpty
        located += items
        places = PhotoMapLoader.places(located)
        mapView.addAnnotations(items.map(PhotoMapAnnotation.init))

        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems([Row.all] + places.map { Row.place($0.id) })
        let existing = dataSource.snapshot().itemIdentifiers
        snapshot.reconfigureItems(existing.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)

        if wasEmpty {
            view.setNeedsLayout()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            loadingAnchor.isHidden = true
        } else if framed, !followsFocus {
            show(located, animated: false)
        }
        nameNext()
    }

    /// Names the places one by one, in list order; a row says Unknown Place until its name arrives.
    private func nameNext() {
        guard namingTask == nil else { return }
        namingTask = Task { [weak self] in
            while let self, !Task.isCancelled,
                  let place = self.places.first(where: { !self.attempted.contains($0.id) }) {
                self.attempted.insert(place.id)
                guard let coordinate = place.photos[0].coordinate,
                      let name = await PhotoPlaceNames.shared.queuedName(for: coordinate) else { continue }
                self.names[place.id] = name
                var snapshot = self.dataSource.snapshot()
                guard snapshot.indexOfItem(.place(place.id)) != nil else { continue }
                snapshot.reconfigureItems([.place(place.id)])
                await self.dataSource.apply(snapshot, animatingDifferences: false)
            }
            self?.namingTask = nil
        }
    }

    private func name(of place: PhotoPlace) -> String {
        names[place.id] ?? String(localized: "Unknown Place")
    }

    private func place(_ id: PhotoPlace.ID) -> PhotoPlace? {
        places.first { $0.id == id }
    }

    /// Frames every place, or one.
    private func show(_ row: Row, animated: Bool) {
        switch row {
        case .all: show(located, animated: animated)
        case .place(let id): if let place = place(id) { show(place.photos, animated: animated) }
        }
    }

    /// Frames these photos in the map area right of the list.
    private func show(_ photos: [PhotoItem], animated: Bool) {
        var rect = MKMapRect.null
        for photo in photos {
            guard let point = photo.coordinate else { continue }
            let mapPoint = MKMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            rect = rect.union(MKMapRect(origin: mapPoint, size: MKMapSize(width: 0, height: 0)))
        }
        guard !rect.isNull else { return }
        let minimum = Self.minimumSpanMeters * MKMapPointsPerMeterAtLatitude(rect.origin.coordinate.latitude)
        rect = rect.insetBy(dx: -max(0, minimum - rect.width) / 2, dy: -max(0, minimum - rect.height) / 2)
        let padding = UIEdgeInsets(top: 120, left: Self.panelWidth + 120, bottom: 120, right: 120)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: animated)
    }

    private func open(_ row: Row) {
        switch row {
        case .all: open(located, title: String(localized: "All"))
        case .place(let id): if let place = place(id) { open(place.photos, title: name(of: place)) }
        }
    }

    private func open(_ photos: [PhotoItem], title: String) {
        let items = photos.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let provider = provider, library = library
        let listing = PhotoListing(folder: nil, source: { (FixedPhotoProvider(items: items, server: provider), library) })
        let grid = PhotoGridViewController(title: title, listing: listing)
        grid.modalPresentationStyle = .fullScreen
        present(grid, animated: true)
    }

    // MARK: - Map

    /// The map takes the remote only while it holds focus; the list leaves it where the user put it.
    private func setMapInteractive(_ interactive: Bool) {
        mapView.isScrollEnabled = interactive
        mapView.isZoomEnabled = interactive
    }

    private var mapHasFocus: Bool {
        (UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView)?.isDescendant(of: mapView) == true
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let onMap = (context.nextFocusedView?.isDescendant(of: mapView)) == true
        setMapInteractive(onMap)
        if onMap { followsFocus = true }
    }

    /// Menu on the map goes back to the list, on the row last focused. Only reached while the map holds focus.
    @objc private func mapMenuPressed() {
        guard mapHasFocus else { return }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// Select on the map opens the photos in view right of the list; nothing when there are none.
    @objc private func mapSelectPressed() {
        guard mapHasFocus else { return }
        let area = view.bounds.inset(by: UIEdgeInsets(top: 0, left: Self.panelWidth, bottom: 0, right: 0))
        let inView = located.filter { photo in
            guard let point = photo.coordinate else { return false }
            let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            return area.contains(mapView.convert(coordinate, toPointTo: view))
        }
        guard !inView.isEmpty else { return }
        open(inView, title: String(localized: "Photos in View"))
    }

    // MARK: - List

    private static func makeLayout() -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(PhotoPlaceCell.height))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 16
        section.contentInsets = NSDirectionalEdgeInsets(top: 80, leading: 60, bottom: 80, trailing: 60)
        section.contentInsetsReference = .none
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Int, Row> {
        let registration = UICollectionView.CellRegistration<PhotoPlaceCell, Row> { [weak self] cell, _, row in
            guard let self else { return }
            switch row {
            case .all:
                cell.configure(name: String(localized: "All"), count: self.located.count,
                               thumbnail: self.places.first?.photos[0].thumbnail)
            case .place(let id):
                guard let place = self.place(id) else { return }
                cell.configure(name: self.name(of: place), count: place.photos.count, thumbnail: place.photos[0].thumbnail)
            }
        }
        return UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }
}

extension PhotoMapViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        // Only a move between rows: the first landing (open, or back from a place) keeps the map where it is.
        guard context.previouslyFocusedIndexPath != nil, let next = context.nextFocusedIndexPath,
              let row = dataSource.itemIdentifier(for: next) else { return }
        followsFocus = true
        show(row, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        open(row)
    }
}

extension PhotoMapViewController: MKMapViewDelegate {
    // A registered class is only used under the default ids unless the delegate returns it.
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        switch annotation {
        case is MKClusterAnnotation:
            mapView.dequeueReusableAnnotationView(withIdentifier: PhotoMapClusterView.reuseID, for: annotation)
        case is PhotoMapAnnotation:
            mapView.dequeueReusableAnnotationView(withIdentifier: PhotoMapAnnotationView.reuseID, for: annotation)
        default:
            nil
        }
    }
}

/// A place in the list: its newest photo, its name and how many photos.
/// Focusable so Right from the list can reach it; it pans and zooms only while focused.
private final class PhotoMapView: MKMapView {
    override var canBecomeFocused: Bool { true }
}

private final class PhotoPlaceCell: UICollectionViewCell {
    static let height: CGFloat = 132
    private static let thumbSide: CGFloat = 108

    private let thumbView = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private var loading: Task<Void, Never>?
    private var thumbnail: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 24
        contentView.layer.borderWidth = 1
        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.layer.cornerRadius = 14
        thumbView.backgroundColor = UIColor(white: 1, alpha: 0.1)
        nameLabel.font = .systemFont(ofSize: 31, weight: .semibold)
        nameLabel.textColor = .white
        countLabel.font = .systemFont(ofSize: 25, weight: .regular)
        countLabel.textColor = UIColor(white: 1, alpha: 0.6)
        for view in [thumbView, nameLabel, countLabel] { contentView.addSubview(view) }
        applyFocus(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = (bounds.height - Self.thumbSide) / 2
        thumbView.frame = CGRect(x: inset, y: inset, width: Self.thumbSide, height: Self.thumbSide)
        let textX = thumbView.frame.maxX + 28
        let width = bounds.width - textX - 24
        nameLabel.frame = CGRect(x: textX, y: bounds.midY - 42, width: width, height: 40)
        countLabel.frame = CGRect(x: textX, y: bounds.midY + 4, width: width, height: 32)
    }

    func configure(name: String, count: Int, thumbnail: URL?) {
        nameLabel.text = name
        countLabel.text = String(localized: "\(count) photos")
        guard thumbnail != self.thumbnail else { return }
        self.thumbnail = thumbnail
        loading?.cancel()
        thumbView.image = nil
        guard let thumbnail else { return }
        loading = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: thumbnail)
            guard !Task.isCancelled else { return }
            self?.thumbView.image = image
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { [self] in applyFocus(isFocused) }
    }

    private func applyFocus(_ focused: Bool) {
        contentView.backgroundColor = UIColor(white: 1, alpha: focused ? 0.18 : 0.08)
        contentView.layer.borderColor = UIColor(white: 1, alpha: focused ? 0.25 : 0.08).cgColor
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }
}

private final class PhotoMapAnnotation: NSObject, MKAnnotation {
    let photo: PhotoItem
    let coordinate: CLLocationCoordinate2D

    init(_ photo: PhotoItem) {
        self.photo = photo
        let point = photo.coordinate ?? PhotoCoordinate(latitude: 0, longitude: 0)
        coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
}

/// A rounded thumbnail; a cluster shows its newest member's with a count.
private class PhotoMapThumbnailView: MKAnnotationView {
    static let side: CGFloat = 96
    private let imageView = UIImageView()
    let countLabel = UILabel()
    private var loading: Task<Void, Never>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        canShowCallout = false
        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        imageView.layer.borderColor = UIColor.white.cgColor
        imageView.layer.borderWidth = 3
        imageView.backgroundColor = .darkGray
        addSubview(imageView)
        countLabel.font = .systemFont(ofSize: 22, weight: .bold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.backgroundColor = .systemBlue
        countLabel.layer.cornerRadius = 18
        countLabel.clipsToBounds = true
        countLabel.isHidden = true
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        imageView.image = nil
        countLabel.isHidden = true
    }

    func show(_ photo: PhotoItem?) {
        loading?.cancel()
        guard let url = photo?.thumbnail else { return }
        loading = Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            guard !Task.isCancelled else { return }
            self?.imageView.image = image
        }
    }
}

private final class PhotoMapAnnotationView: PhotoMapThumbnailView {
    static let reuseID = "photo"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = Self.reuseID
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        show((annotation as? PhotoMapAnnotation)?.photo)
    }
}

private final class PhotoMapClusterView: PhotoMapThumbnailView {
    static let reuseID = "photoCluster"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let cluster = annotation as? MKClusterAnnotation else { return }
        let photos = cluster.memberAnnotations.compactMap { ($0 as? PhotoMapAnnotation)?.photo }
        show(photos.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) })
        countLabel.text = "\(photos.count)"
        countLabel.sizeToFit()
        let width = max(36, countLabel.bounds.width + 16)
        countLabel.frame = CGRect(x: Self.side - width + 8, y: -8, width: width, height: 36)
        countLabel.isHidden = false
    }
}
