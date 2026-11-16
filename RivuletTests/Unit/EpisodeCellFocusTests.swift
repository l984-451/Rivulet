import Testing
import UIKit
@testable import Rivulet

@MainActor
struct EpisodeCellFocusTests {
    @Test(arguments: [EpisodeCell.Layout.stacked, .sideBySide])
    func episodeIsOneFocusStop(layout: EpisodeCell.Layout) throws {
        let cell = EpisodeCell(layout: layout)
        let episode = JellyfinFixtures.mediaItem("episode", kind: .episode)
        let description = try #require(cell.subviews.compactMap { $0 as? EpisodeDescriptionView }.first)
        #expect(cell.preferredFocusEnvironments.first is EpisodeThumbCardView)

        // The title rides inside the artwork, so the description is neither shown nor a stop.
        cell.configure(episode: episode)
        #expect(description.isHidden && !description.canBecomeFocused)
        cell.resetFocusVisual()
        #expect(!description.canBecomeFocused)

        // Search's tile keeps its description under the thumb.
        cell.configure(searchResult: episode)
        #expect(!description.isHidden)

        cell.configure(episode: episode)
        #expect(description.isHidden && !description.canBecomeFocused)
        cell.configure(trailer: BelowFoldTrailer(
            id: "trailer", title: "Trailer", artworkURL: nil, durationFormatted: nil, providerID: "stub"))
        #expect(description.isHidden && !description.canBecomeFocused)
    }
}
