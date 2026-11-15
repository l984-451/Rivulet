import Testing
import UIKit
@testable import Rivulet

@MainActor
struct SeasonPillFocusTests {
    @Test func episodeEntryTracksSelectedSeasonAndClearsWithoutPills() throws {
        let view = ExpandedDetailContainerView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.setSeasonPills(["Season 1", "Season 2", "Season 3"],
                            seasonRefIDs: ["1", "2", "3"], selectedIndex: 1)
        let pills = descendants(of: view).compactMap { $0 as? SeasonPillView }
        let selected = try #require(view.seasonPillsFocusEnvironment)
        let guide = try #require(descendants(of: view).flatMap(\.layoutGuides)
            .compactMap { $0 as? UIFocusGuide }
            .first { $0.preferredFocusEnvironments.first === selected })

        #expect(pills.count == 3)
        #expect(pills.filter(\.canBecomeFocused).count == 1)
        #expect(pills.first(where: \.canBecomeFocused) === selected)
        #expect(guide.isEnabled)

        view.detailsFocusTarget = .pills
        #expect(pills.allSatisfy { $0.canBecomeFocused })
        #expect(guide.isEnabled == false)

        view.selectSeasonPill(2)
        view.detailsFocusTarget = .episodes
        let nextSelected = try #require(view.seasonPillsFocusEnvironment)
        #expect(nextSelected !== selected)
        #expect(pills.filter(\.canBecomeFocused).count == 1)
        #expect(pills.first(where: \.canBecomeFocused) === nextSelected)
        #expect(guide.preferredFocusEnvironments.first === nextSelected)
        #expect(guide.isEnabled)

        view.setSeasonPills(["Season 1"], seasonRefIDs: ["1"], selectedIndex: 0)
        #expect(view.hasSeasonPills == false)
        #expect(guide.isEnabled == false)
        #expect(guide.preferredFocusEnvironments.isEmpty)
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
