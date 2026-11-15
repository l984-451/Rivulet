import Testing
import UIKit
@testable import Rivulet

@MainActor
struct EpisodeCellFocusTests {
    @Test(arguments: [EpisodeCell.Layout.stacked, .sideBySide])
    func thumbnailGuideFollowsCardMode(layout: EpisodeCell.Layout) throws {
        let cell = EpisodeCell(layout: layout)
        let episode = JellyfinFixtures.mediaItem("episode", kind: .episode)
        cell.configure(episode: episode)
        let guide = try #require(cell.layoutGuides.compactMap { $0 as? UIFocusGuide }.first)
        #expect(guide.isEnabled == (layout == .stacked))
        #expect(guide.preferredFocusEnvironments.first === cell.preferredFocusEnvironments.first)

        cell.configure(searchResult: episode)
        #expect(guide.isEnabled == false)
        cell.resetFocusVisual()
        #expect(guide.isEnabled == false)

        cell.configure(episode: episode)
        #expect(guide.isEnabled == (layout == .stacked))
        cell.configure(trailer: BelowFoldTrailer(
            id: "trailer", title: "Trailer", artworkURL: nil, durationFormatted: nil, providerID: "stub"))
        #expect(guide.isEnabled == false)
        cell.resetFocusVisual()
        #expect(guide.isEnabled == false)
    }
}
