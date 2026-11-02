// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The "Extras" row of the episode and season pages: the expanded detail's trailer/extra
//  card in one horizontal rail. Select plays through `ExtraPlayer`.

import UIKit

final class ExtrasShelfView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {

    static let headerHeight: CGFloat = 44
    static let height = headerHeight + EpisodeCell.trailerThumbHeight

    var onPlay: ((BelowFoldTrailer) -> Void)?
    private(set) var tiles: [BelowFoldTrailer] = []
    private let collection: UICollectionView

    /// `leading` is where the first card's artwork and the title rest.
    init(leading: CGFloat) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: EpisodeCell.cardWidth, height: EpisodeCell.trailerThumbHeight)
        layout.minimumLineSpacing = MediaRowMetrics.tileGap
        layout.sectionInset = UIEdgeInsets(top: 0, left: leading, bottom: 0, right: MediaRowMetrics.rowTrailing)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = MediaRowMetrics.headerFont
        title.textColor = MediaRowMetrics.headerColor
        title.text = String(localized: "Extras")
        addSubview(title)

        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.clipsToBounds = false
        collection.contentInsetAdjustmentBehavior = .never
        collection.dataSource = self
        collection.delegate = self
        collection.register(EpisodeCollectionCell.self, forCellWithReuseIdentifier: EpisodeCollectionCell.reuseID)
        addSubview(collection)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            title.lastBaselineAnchor.constraint(equalTo: collection.topAnchor, constant: -BelowFoldSectionHeader.cardBaseline),
            collection.topAnchor.constraint(equalTo: topAnchor, constant: Self.headerHeight),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.heightAnchor.constraint(equalToConstant: EpisodeCell.trailerThumbHeight),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Trailers first, then the other extras.
    func configure(_ tiles: [BelowFoldTrailer]) {
        self.tiles = tiles
        collection.reloadData()
    }

    /// The first card, for a focus request from the host.
    var firstCard: UIFocusEnvironment? {
        collection.layoutIfNeeded()
        return collection.cellForItem(at: IndexPath(item: 0, section: 0))
    }

    func contains(_ view: UIView?) -> Bool { view?.isDescendant(of: collection) ?? false }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { tiles.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: EpisodeCollectionCell.reuseID, for: indexPath) as! EpisodeCollectionCell
        let tile = tiles[indexPath.item]
        cell.onFocused = nil
        cell.configure(trailer: tile)
        cell.onPlay = { [weak self] in self?.onPlay?(tile) }
        return cell
    }

    /// The cards' thumbs are the focus stops, as in the expanded detail.
    func collectionView(_ cv: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool { false }
}
