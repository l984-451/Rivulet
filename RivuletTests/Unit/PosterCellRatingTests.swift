// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The focused poster's score (Settings > Appearance > Rating > Show on Focused Poster).
@MainActor
final class PosterCellRatingTests: XCTestCase {
    private var savedSource: Any?

    override func setUp() {
        super.setUp()
        savedSource = UserDefaults.standard.object(forKey: MediaRating.detailSourceKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedSource, forKey: MediaRating.detailSourceKey)
        super.tearDown()
    }

    private func choose(_ source: MediaRating.Source) {
        UserDefaults.standard.set(source.rawValue, forKey: MediaRating.detailSourceKey)
    }

    /// Hub items carry Plex's flat pair: here a Rotten Tomatoes critic score and an IMDb audience score.
    private func plex(type: String) -> PlexMetadata {
        var meta = PlexMetadata()
        meta.ratingKey = "1"
        meta.type = type
        meta.title = "Charge"
        meta.rating = 8.3
        meta.ratingImage = "rottentomatoes://image.rating.ripe"
        meta.audienceRating = 7.6
        meta.audienceRatingImage = "imdb://image.rating"
        return meta
    }

    private func cell() -> PosterCell { PosterCell(frame: CGRect(x: 0, y: 0, width: 220, height: 400)) }

    func test_plexPath_moviesAndShowsOnly_clearedOnReuse() {
        choose(.imdb)
        let cell = cell()
        cell.configure(item: plex(type: "movie"))
        XCTAssertEqual(cell.posterRatingLine, "IMDb 7.6")
        cell.prepareForReuse()
        XCTAssertNil(cell.posterRatingLine)
        cell.configure(item: plex(type: "show"))
        XCTAssertEqual(cell.posterRatingLine, "IMDb 7.6")
        cell.configure(item: plex(type: "episode"))
        XCTAssertNil(cell.posterRatingLine, "episodes never show a score")
    }

    func test_mediaItemPath_usesTheListScores() {
        choose(.rottenTomatoes)
        let item = PlexMediaMapper.item(plex(type: "movie"), providerID: "plex", serverURL: "http://s", authToken: "t")
        let cell = cell()
        cell.configure(item: item)
        XCTAssertEqual(cell.posterRatingLine, "🍅 83%")
    }

    /// The source is picked when the badge shows, not when the cell is configured.
    func test_sourceChangedAfterConfigure_appliesWithoutReconfigure() {
        choose(.imdb)
        let cell = cell()
        cell.configure(item: plex(type: "movie"))
        XCTAssertEqual(cell.posterRatingLine, "IMDb 7.6")
        choose(.rottenTomatoes)
        XCTAssertEqual(cell.posterRatingLine, "🍅 83%")
        choose(.letterboxd)
        XCTAssertEqual(cell.posterRatingLine, "🍅 83%", "Letterboxd is never in list data: the list's own score")
    }

    func test_badgeText_isThePosterLine() {
        let badge = PosterRatingBadge()
        for rating in [MediaRating(7.6, source: .imdb)!, MediaRating(4.1, source: .rottenTomatoes)!,
                       MediaRating(9.2, source: .rottenTomatoesAudience)!, MediaRating(8.4, source: .letterboxd)!] {
            badge.configure(rating)
            XCTAssertEqual(badge.text, rating.posterLine)
        }
    }

    /// The type's ink sits `inset` from the side it is pinned to, whatever glyph ends it: a tabular
    /// "1" has a far wider side bearing than an "8", and "IMDb" starts on a stem. Read from the pixels.
    func test_typeInk_landsOnTheInset_eitherCorner() throws {
        // Pinned in a poster-sized host, as the cell pins it to its art overlay.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 259, height: 390))
        let badge = PosterRatingBadge()
        host.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: host.topAnchor),
            badge.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            badge.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        badge.isHidden = false
        badge.alpha = 1
        let ratings = [MediaRating(8.1, source: .imdb)!, MediaRating(8.3, source: .rottenTomatoes)!,
                       MediaRating(7.6, source: .tmdb)!]
        for corner in [PosterRatingBadge.Corner.topTrailing, .topLeading] {
            for rating in ratings {
                // The cell's order (`prepareRatingBadge`).
                badge.configure(rating)
                host.layoutIfNeeded()
                badge.setCorner(corner)
                badge.layoutIfNeeded()
                let ink = try XCTUnwrap(Self.whiteInk(badge), rating.posterLine)
                let side = corner == .topTrailing ? badge.bounds.width - ink.max : ink.min
                // Within a pixel: frames snap to half points at the TV's 2x scale.
                XCTAssertEqual(side, PosterRatingBadge.inset, accuracy: 0.5, "\(rating.posterLine) \(corner)")
            }
        }
    }

    /// The horizontal extent, in points, of the light pixels in the view's top quarter: the type,
    /// not its shade or shadow.
    private static func whiteInk(_ view: UIView) -> (min: CGFloat, max: CGFloat)? {
        let scale: CGFloat = 4
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var minX = w, maxX = -1
        for y in 0..<(h / 4) {
            let row = (y * w) * 4
            for x in 0..<w where max(pixels[row + x * 4], pixels[row + x * 4 + 1], pixels[row + x * 4 + 2]) > 96 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        guard maxX >= minX else { return nil }
        return (CGFloat(minX) / scale, CGFloat(maxX + 1) / scale)
    }

    /// Each emoji is trimmed to its ink and sized by area, so none is lost or blown up beside the
    /// digits, and its ink centroid is what lands on their cap midline.
    func test_emojiGlyph_trimmedToInk_centroidInside() throws {
        let popcorn = try XCTUnwrap(PosterRatingBadge.emojiGlyph("🍿"))
        for emoji in ["🍅", "🤢", "🍿"] {
            let glyph = try XCTUnwrap(PosterRatingBadge.emojiGlyph(emoji), emoji)
            XCTAssert((12...22).contains(glyph.image.size.height), "\(emoji) \(glyph.image.size)")
            XCTAssert((0.35...0.65).contains(glyph.centroid), "\(emoji) centroid \(glyph.centroid)")
        }
        // Round art grows past the narrow popcorn's width.
        XCTAssertGreaterThan(try XCTUnwrap(PosterRatingBadge.emojiGlyph("🍅")).image.size.width, popcorn.image.size.width)
    }

    /// The watched pill holds the top trailing corner, the server and edition badges the leading one.
    func test_ratingSlot_besideThePillAndTheBadges() {
        let pill = CGRect(x: 226, y: 10, width: 26, height: 26)
        let shortBadge = CGRect(x: 10, y: 10, width: 60, height: 26)
        let longBadge = CGRect(x: 10, y: 10, width: 200, height: 26)
        let slot = { (pill: CGRect?, badges: CGRect?) in
            PosterCell.ratingSlot(pill: pill, badges: badges, typeWidth: 60, overlayWidth: 259)
        }
        XCTAssertEqual(slot(nil, nil).corner, .topTrailing)
        XCTAssertEqual(slot(nil, nil).clearance, 0)
        XCTAssertEqual(slot(pill, nil).corner, .topLeading, "the pill's corner is taken")
        XCTAssertEqual(slot(pill, nil).clearance, 0)
        XCTAssertEqual(slot(pill, shortBadge).corner, .topTrailing, "both corners taken: below the pill")
        XCTAssertEqual(slot(pill, shortBadge).clearance, 42)
        XCTAssertEqual(slot(nil, shortBadge).clearance, 0, "a short badge leaves the trailing corner free")
        XCTAssertEqual(slot(nil, longBadge).clearance, 42, "a long edition name would reach the score")
    }

    /// Metacritic and Letterboxd only come from the ratings worker, so posters fall back for them.
    func test_posterSources_areTheListSources() {
        XCTAssertEqual(MediaRating.posterSources, [.rottenTomatoes, .rottenTomatoesAudience, .imdb, .tmdb])
    }

    /// Lists cached before `ratings` existed still decode, with no scores.
    func test_mediaItem_decodesWithoutRatings() throws {
        let item = PlexMediaMapper.item(plex(type: "movie"), providerID: "plex", serverURL: "http://s", authToken: "t")
        XCTAssertEqual(item.ratings?.count, 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json)), item)
        json.removeValue(forKey: "ratings")
        XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json)).ratings)
    }
}
