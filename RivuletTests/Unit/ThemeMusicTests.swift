import XCTest
@testable import Rivulet

final class ThemeMusicTests: XCTestCase {

    private let show = MediaItemRef(providerID: "plex:m1", itemID: "10")
    private let other = MediaItemRef(providerID: "plex:m1", itemID: "20")

    private func page(_ show: MediaItemRef?) -> ThemeMusic.Layer {
        ThemeMusic.Layer(isPage: true, show: show, isFullScreen: false)
    }
    private let popup = ThemeMusic.Layer(isPage: false, show: nil, isFullScreen: false)
    private let player = ThemeMusic.Layer(isPage: false, show: nil, isFullScreen: true)

    // MARK: Which show the pages ask for

    func test_screen_noPagesIsNoShow() {
        XCTAssertEqual(ThemeMusic.screen(for: []), .noShow)
        XCTAssertEqual(ThemeMusic.screen(for: [popup]), .noShow)
    }

    func test_screen_theTopmostPageDecides() {
        XCTAssertEqual(ThemeMusic.screen(for: [page(show)]), .show(show))
        // show -> season -> episode of the same show: still that show.
        XCTAssertEqual(ThemeMusic.screen(for: [page(show), page(show), page(show)]), .show(show))
        // A related show opened over it.
        XCTAssertEqual(ThemeMusic.screen(for: [page(show), page(other)]), .show(other))
        // A film's page (no show) over a show's page.
        XCTAssertEqual(ThemeMusic.screen(for: [page(show), page(nil)]), .noShow)
    }

    func test_screen_aPopupChangesNothing() {
        XCTAssertEqual(ThemeMusic.screen(for: [page(show), popup]), .show(show))
    }

    func test_screen_aFullScreenCoverSilencesWithoutEndingTheVisit() {
        XCTAssertEqual(ThemeMusic.screen(for: [page(show), player]), .covered)
        XCTAssertEqual(ThemeMusic.screen(for: [page(show), player, popup]), .covered)
        // A player with no show's page under it is nothing to this feature.
        XCTAssertEqual(ThemeMusic.screen(for: [player]), .noShow)
        XCTAssertEqual(ThemeMusic.screen(for: [page(nil), player]), .noShow)
    }

    // MARK: Whether it may start

    func test_mayStart_needsEveryCondition() {
        func may(enabled: Bool = true, foreground: Bool = true, music: Bool = false,
                 video: Bool = false, other: Bool = false) -> Bool {
            ThemeMusic.mayStart(enabled: enabled, isForeground: foreground, musicActive: music,
                                videoActive: video, otherAppAudio: other)
        }
        XCTAssertTrue(may())
        XCTAssertFalse(may(enabled: false))
        XCTAssertFalse(may(foreground: false))
        XCTAssertFalse(may(music: true))
        XCTAssertFalse(may(video: true))
        XCTAssertFalse(may(other: true))
    }

    // MARK: Settings

    func test_settings_defaultsAndClamp() {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: ThemeMusicSettings.enabledKey)
        let savedVolume = defaults.object(forKey: ThemeMusicSettings.volumeKey)
        defer {
            defaults.set(savedEnabled, forKey: ThemeMusicSettings.enabledKey)
            defaults.set(savedVolume, forKey: ThemeMusicSettings.volumeKey)
        }
        defaults.removeObject(forKey: ThemeMusicSettings.enabledKey)
        defaults.removeObject(forKey: ThemeMusicSettings.volumeKey)
        XCTAssertTrue(ThemeMusicSettings.isEnabled)
        XCTAssertEqual(ThemeMusicSettings.volumePercent, ThemeMusicSettings.defaultVolume)

        ThemeMusicSettings.volumePercent = 500
        XCTAssertEqual(ThemeMusicSettings.volumePercent, 100)
        ThemeMusicSettings.volumePercent = -3
        XCTAssertEqual(ThemeMusicSettings.volumePercent, 10)
        ThemeMusicSettings.volumePercent = 40
        XCTAssertEqual(ThemeMusicSettings.volume, 0.4, accuracy: 0.0001)
        ThemeMusicSettings.isEnabled = false
        XCTAssertFalse(ThemeMusicSettings.isEnabled)
    }

    func test_settings_nextVolumeStepsAndWraps() {
        XCTAssertEqual(ThemeMusicSettings.nextVolume(after: 30), 40)
        XCTAssertEqual(ThemeMusicSettings.nextVolume(after: 90), 100)
        XCTAssertEqual(ThemeMusicSettings.nextVolume(after: 100), 10)
        // A stored value between two options moves on from the option above it.
        XCTAssertEqual(ThemeMusicSettings.nextVolume(after: 35), 50)
        XCTAssertEqual(ThemeMusicSettings.volumeLabel(30), "30%")
    }

    // MARK: Which show a page belongs to

    private func item(_ kind: MediaKind, id: String, parent: MediaItemRef? = nil,
                      grandparent: MediaItemRef? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:m1", itemID: id), kind: kind, title: "T", sortTitle: nil,
            overview: nil, year: nil, runtime: nil, parentRef: parent, grandparentRef: grandparent,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil)
    }

    func test_showRef_isTheShowForItsSeasonsAndEpisodes() {
        let season = MediaItemRef(providerID: "plex:m1", itemID: "11")
        XCTAssertEqual(item(.show, id: "10").themeMusicShowRef, show)
        XCTAssertEqual(item(.season, id: "11", parent: show).themeMusicShowRef, show)
        XCTAssertEqual(item(.episode, id: "12", parent: season, grandparent: show).themeMusicShowRef, show)
    }

    func test_showRef_isNilForAFilmAndForAnEpisodeThatDoesNotKnowItsShow() {
        XCTAssertNil(item(.movie, id: "30").themeMusicShowRef)
        XCTAssertNil(item(.episode, id: "12").themeMusicShowRef)
        XCTAssertNil(item(.season, id: "11", parent: MediaItemRef(providerID: "plex:m1", itemID: "")).themeMusicShowRef)
    }

    func test_indicator_onlyLoadingShowsTheRing() {
        XCTAssertTrue(ThemeMusic.Indicator.loading.showsRing)
        XCTAssertFalse(ThemeMusic.Indicator.sounding.showsRing)
        XCTAssertFalse(ThemeMusic.Indicator.quiet.showsRing)
    }
}
