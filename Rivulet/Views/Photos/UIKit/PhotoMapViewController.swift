// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoMapViewController.swift
//  Rivulet
//
//  A library's located photos on a map, clustered. A photo opens the viewer
//  on it; a cluster opens a grid of its members.
//

import MapKit
import UIKit

final class PhotoMapViewController: UIViewController {
    private let provider: any PhotoProvider
    private let library: MediaLibrary
    private let mapView = MKMapView()
    private var loadTask: Task<Void, Never>?
    private var framed = false

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
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.register(PhotoMapAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoMapAnnotationView.reuseID)
        mapView.register(PhotoMapClusterView.self,
                         forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        view.addSubview(mapView)

        let loader = PhotoMapLoader(provider: provider, library: library)
        loadTask = Task { [weak self] in
            await loader.load { [weak self] items in
                guard let self else { return }
                self.mapView.addAnnotations(items.map(PhotoMapAnnotation.init))
                // Frame on the first points, then once more when every page is in.
                if !self.framed { self.framed = true; self.frameAll() }
            }
            self?.frameAll()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { loadTask?.cancel() }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [mapView] }

    private func frameAll() {
        guard !mapView.annotations.isEmpty else { return }
        mapView.showAnnotations(mapView.annotations, animated: false)
    }

    private func open(_ photos: [PhotoItem]) {
        let items = photos.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let provider = provider, library = library
        let listing = PhotoListing(folder: nil, source: { (FixedPhotoProvider(items: items, server: provider), library) })
        if items.count == 1 {
            Task { [weak self] in
                await listing.loadFirst()?.value
                self?.present(PhotoViewerViewController(listing: listing, index: 0), animated: true)
            }
        } else {
            let grid = PhotoGridViewController(title: library.title, listing: listing)
            grid.modalPresentationStyle = .fullScreen
            present(grid, animated: true)
        }
    }
}

extension PhotoMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        defer { mapView.deselectAnnotation(view.annotation, animated: false) }
        if let cluster = view.annotation as? MKClusterAnnotation {
            open(cluster.memberAnnotations.compactMap { ($0 as? PhotoMapAnnotation)?.photo })
        } else if let annotation = view.annotation as? PhotoMapAnnotation {
            open([annotation.photo])
        }
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

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations { [self] in
            transform = isFocused ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity
        }
    }
}

private final class PhotoMapAnnotationView: PhotoMapThumbnailView {
    static let reuseID = "photo"

    override var annotation: MKAnnotation? {
        didSet {
            clusteringIdentifier = "photo"
            show((annotation as? PhotoMapAnnotation)?.photo)
        }
    }
}

private final class PhotoMapClusterView: PhotoMapThumbnailView {
    override var annotation: MKAnnotation? {
        didSet {
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

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
    }

    required init?(coder: NSCoder) { fatalError() }
}
