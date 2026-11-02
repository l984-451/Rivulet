// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import XCTest
@testable import Rivulet

@MainActor
final class CinematicThemeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private var previousTheme: Any?

    override func setUp() {
        super.setUp()
        previousTheme = UserDefaults.standard.object(forKey: AppTheme.storageKey)
        UserDefaults.standard.set(AppTheme.standard.rawValue, forKey: AppTheme.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousTheme, forKey: AppTheme.storageKey)
        NotificationCenter.default.post(name: .appThemeDidChange, object: nil)
        super.tearDown()
    }

    func test_existingAndUnknownPreferencesKeepStandard() throws {
        let name = "CinematicThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppTheme.stored(in: defaults), .standard)
        defaults.set("future-theme", forKey: AppTheme.storageKey)
        XCTAssertEqual(AppTheme.stored(in: defaults), .standard)
        defaults.set(false, forKey: "showHomeHero")
        AppTheme.cinematic.apply(to: defaults)
        XCTAssertEqual(AppTheme.stored(in: defaults), .cinematic)
        AppTheme.standard.apply(to: defaults)
        XCTAssertEqual(AppTheme.stored(in: defaults), .standard)
        XCTAssertFalse(defaults.bool(forKey: "showHomeHero"), "switching themes must preserve layout preferences")
    }

    func test_pickerPersistsAndReportsTheSelection() throws {
        let appearance = try XCTUnwrap(SettingsContent.rows(for: .appearance).first { $0.id == "appTheme" })
        XCTAssertEqual(appearance.valueText, "Standard")
        guard case .navigationValue(.themePicker, _) = appearance.kind else { return XCTFail("Theme has no picker") }
        let options = SettingsContent.rows(for: .themePicker)
        XCTAssertEqual(Set(options.map(\.id)).count, 2)
        let cinematic = try XCTUnwrap(options.first { $0.id == "appTheme_cinematic" })
        XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: cinematic.id))
        guard case .option(_, let select) = cinematic.kind else { return XCTFail("Theme cannot be selected") }
        select()
        XCTAssertEqual(AppTheme.current, .cinematic)
        XCTAssertEqual(appearance.valueText, "Cinematic")
        XCTAssertEqual(options.filter(\.showsCheckmark).map(\.id), [cinematic.id])
    }

    func test_switchRebuildsCachedPagesAndKeepsSettingsMounted() {
        var made: [SidebarTab: [UIViewController]] = [:]
        let shell = RootShellViewController()
        shell.makeContent = { tab in
            let controller = UIViewController()
            made[tab, default: []].append(controller)
            return controller
        }
        shell.loadViewIfNeeded()
        shell.applySelection(.discover)
        shell.applySelection(.settings)
        let settings = made[.settings]?.first
        AppTheme.cinematic.apply()
        XCTAssertEqual(shell.currentTab, .settings)
        XCTAssertTrue(settings?.parent === shell)
        XCTAssertNil(made[.home]?.first?.parent)
        XCTAssertNil(made[.discover]?.first?.parent)
        XCTAssertEqual(shell.overrideUserInterfaceStyle, .dark)
        shell.applySelection(.home)
        XCTAssertEqual(made[.home]?.count, 2)
        AppTheme.standard.apply()
        XCTAssertEqual(made[.home]?.count, 3, "the visible page must also refresh when the theme changes")
        XCTAssertEqual(shell.overrideUserInterfaceStyle, .unspecified)
        shell.applySelection(.settings)
        XCTAssertEqual(made[.settings]?.count, 1)
    }

    func test_reusedRowClearsWatchedAndMetadata() {
        let cell = CinematicLibraryCell(frame: CGRect(x: 0, y: 0, width: 900, height: 112))
        var watched = item("Distant Shores")
        watched.userState = MediaUserState(isPlayed: true, viewOffset: 0, isFavorite: false, lastViewedAt: nil)
        cell.configure(item: watched)
        XCTAssertEqual(cell.accessibilityValue, "Watched")
        XCTAssertTrue(cell.accessibilityLabel?.contains("118 min") == true)
        cell.prepareForReuse()
        cell.configure(item: .gridPlaceholder)
        XCTAssertNil(cell.accessibilityValue)
        XCTAssertEqual(cell.accessibilityLabel, "Loading…")
    }

    /// Uses the real library controller and its provider/paging boundary, with no account or server.
    func test_cinematicLibraryLoadsRowsAndOpensDetails() async throws {
        AppTheme.cinematic.apply()
        let stub = StubMediaProvider(id: "cinematic-test", kind: .jellyfin)
        let artwork = try await seedArtwork()
        let titles = ["Distant Shores", "Blue Meridian", "Harbor Lights", "The Last Observatory",
                      "North of the Sun", "Quiet Earth", "The Long Way Home", "Winter Light"]
        stub.libraryItems = titles.map { item($0, artwork: artwork) }
            + (9...80).map { item("Movie \($0)", artwork: artwork) }
        let selected = stub.libraryItems[0]
        stub.detailResult = MediaItemDetail(item: selected, tagline: nil, genres: ["Adventure", "Drama"],
            studios: [], cast: [], directors: [], writers: [], chapters: [], mediaSources: [],
            trailerURL: nil, contentRating: "PG-13", nextEpisode: nil, collections: [])
        MediaProviderRegistry.shared.register(stub)
        defer { MediaProviderRegistry.shared.unregister(providerID: stub.id) }
        let library = MediaLibrary(id: "cinematic-movies", providerID: stub.id, title: "Movies", kind: .movies)
        let controller = PlexHomeViewController(mode: .library(key: library.id, title: library.title), providerLibrary: library)
        let window = try host(controller)
        defer { window.isHidden = true }
        let collection = try XCTUnwrap(descendants(in: controller.view, of: UICollectionView.self).first)
        try await settle { collection.numberOfSections == 2 && collection.numberOfItems(inSection: 1) == 80 }
        controller.view.layoutIfNeeded()
        let first = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 1)) as? CinematicLibraryCell)
        let next = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 1, section: 1)) as? CinematicLibraryCell)
        XCTAssertEqual(first.frame.minX, next.frame.minX, accuracy: 1)
        XCTAssertEqual(next.frame.minY - first.frame.minY, CinematicStyle.rowHeight, accuracy: 1)
        XCTAssertGreaterThan(first.frame.minX, collection.bounds.width * 0.4)
        XCTAssertTrue(controller.collectionView(collection, canFocusItemAt: IndexPath(item: 0, section: 1)))
        let panel = try XCTUnwrap(descendants(in: controller.view, of: CinematicLibraryArtworkView.self).first)
        XCTAssertEqual(panel.displayedItem?.ref, selected.ref)
        XCTAssertFalse(panel.canBecomeFocused)
        try await settle {
            collection.cellForItem(at: IndexPath(item: 0, section: 1))?.isFocused == true
        }
        try await Task.sleep(for: .milliseconds(250))
        attach(window, name: "Cinematic library — sample media")

        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 0, section: 1))
        try await settle { controller.presentedViewController is PreviewCarouselViewController }
        try await Task.sleep(for: .milliseconds(800))
        attach(window, name: "Cinematic details — sample media")
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
        try await Task.sleep(for: .milliseconds(350))

        // A later page replaces placeholders in place, without reverting to poster cells.
        let laterPath = IndexPath(item: 70, section: 1)
        collection.scrollToItem(at: laterPath, at: .centeredVertically, animated: false)
        try await settle {
            (collection.cellForItem(at: laterPath) as? CinematicLibraryCell)?.accessibilityLabel?.hasPrefix("Movie 71") == true
        }

        panel.configure(item: item("A title without artwork"))
        XCTAssertTrue(descendants(in: panel, of: UIImageView.self).filter { $0.contentMode == .scaleAspectFill }.allSatisfy { $0.image == nil })
        panel.configure(item: nil)
        XCTAssertNil(panel.displayedItem)
        XCTAssertTrue(descendants(in: panel, of: UILabel.self).allSatisfy { $0.text == nil })
    }

    func test_failedLibraryCanRetryIntoContent() async throws {
        AppTheme.cinematic.apply()
        let stub = StubMediaProvider(id: "cinematic-test", kind: .jellyfin)
        stub.libraryItemsError = MediaProviderError.notFound
        MediaProviderRegistry.shared.register(stub)
        defer { MediaProviderRegistry.shared.unregister(providerID: stub.id) }
        let library = MediaLibrary(id: "retry-movies", providerID: stub.id, title: "Movies", kind: .movies)
        let controller = PlexHomeViewController(mode: .library(key: library.id, title: library.title), providerLibrary: library)
        let window = try host(controller)
        defer { window.isHidden = true }
        let state = try XCTUnwrap(descendants(in: controller.view, of: HomeStateView.self).first)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(state.isHidden)
        stub.libraryItemsError = nil
        stub.libraryItems = [item("Recovered title")]
        state.onAction?()
        try await settle { state.isHidden }
        let panel = try XCTUnwrap(descendants(in: controller.view, of: CinematicLibraryArtworkView.self).first)
        XCTAssertEqual(panel.displayedItem?.title, "Recovered title")
    }

    private func host(_ controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = screen
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = screen
        controller.view.layoutIfNeeded()
        return window
    }

    private func settle(file: StaticString = #filePath, line: UInt = #line, until ready: () -> Bool) async throws {
        for _ in 0..<80 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The library did not settle", file: file, line: line)
    }

    private func descendants<T: UIView>(in view: UIView, of type: T.Type) -> [T] {
        view.subviews.flatMap { child in ((child as? T).map { [$0] } ?? []) + descendants(in: child, of: type) }
    }

    private func attach(_ view: UIView, name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func item(_ title: String, artwork: URL? = nil) -> MediaItem {
        MediaItem(ref: MediaItemRef(providerID: "cinematic-test", itemID: title), kind: .movie,
            title: title, sortTitle: nil,
            overview: "A lone traveler follows the coast toward an unfamiliar horizon, discovering the people and places that make a journey worth taking.",
            year: 2026, contentRating: "PG-13", runtime: 7080, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: artwork, backdrop: artwork, thumbnail: artwork, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
    }

    /// A deterministic, network-free artwork fixture for the production image cache.
    private func seedArtwork() async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://cinematic-test.invalid/\(UUID().uuidString).png"))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 1200, height: 1600)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let ctx = renderer.cgContext
            let colors = [UIColor(red: 0.18, green: 0.4, blue: 0.48, alpha: 1).cgColor,
                          UIColor(red: 0.88, green: 0.62, blue: 0.36, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 1400), options: [.drawsAfterEndLocation])
            }
            UIColor(red: 1, green: 0.88, blue: 0.65, alpha: 1).setFill()
            ctx.fillEllipse(in: CGRect(x: 770, y: 300, width: 180, height: 180))
            for index in 0..<4 {
                let y = CGFloat(660 + index * 200)
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: 360, y: y - 220))
                path.addLine(to: CGPoint(x: 650, y: y + 90))
                path.addLine(to: CGPoint(x: 1050, y: y - 160))
                path.addLine(to: CGPoint(x: 1200, y: y + 40))
                path.addLine(to: CGPoint(x: 1200, y: 1600))
                path.addLine(to: CGPoint(x: 0, y: 1600))
                path.close()
                UIColor(red: 0.12, green: 0.25, blue: 0.3, alpha: 0.5).setFill()
                path.fill()
            }
        }
        let directory = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
            .appendingPathComponent("PlexImageCache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(url.absoluteString.sha256Hash())
        try XCTUnwrap(image.pngData()).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loaded = await ImageCacheManager.shared.image(for: url, quality: .full)
        XCTAssertNotNil(loaded)
        let thumbnail = await ImageCacheManager.shared.image(for: url, quality: .thumb)
        XCTAssertNotNil(thumbnail)
        return url
    }
}
