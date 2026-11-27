import Testing
import UIKit
@testable import Rivulet

@MainActor
struct SeasonPillFocusTests {
    private let snapshotPadding: CGFloat = 8

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

    @Test(arguments: ["Season 1", "A much longer season title"])
    func focusKeepsLayoutStableAndResetsAfterResize(title: String) throws {
        let pill = SeasonPillView(frame: .zero)
        pill.overrideUserInterfaceStyle = .dark
        pill.configure(label: title, isSelected: true)
        let size = pill.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        pill.frame = CGRect(origin: .zero, size: size)
        pill.layoutIfNeeded()
        let originalFrame = pill.frame
        let leftProbe = CGPoint(x: -3, y: pill.bounds.midY)
        let topProbe = CGPoint(x: pill.bounds.midX, y: -3)
        let resting = render(pill)
        #expect(try alpha(resting, at: leftProbe) == 0)
        #expect(try alpha(resting, at: topProbe) == 0)

        pill.setFocused(true)
        #expect(pill.frame == originalFrame)
        let focused = render(pill)
        #expect(try alpha(focused, at: leftProbe) > 128)
        #expect(try alpha(focused, at: topProbe) > 128)

        pill.bounds.size.width += 100
        pill.setNeedsLayout()
        pill.layoutIfNeeded()
        let resized = render(pill)
        let rightProbe = CGPoint(x: pill.bounds.maxX + 2, y: pill.bounds.midY)
        #expect(try alpha(resized, at: rightProbe) > 128)
        pill.setFocused(false)
        #expect(try alpha(render(pill), at: rightProbe) == 0)
        let expected = SeasonPillView(frame: CGRect(origin: .zero, size: pill.bounds.size))
        expected.overrideUserInterfaceStyle = .dark
        expected.configure(label: title, isSelected: true)
        #expect(render(pill).pngData() == render(expected).pngData(),
                "Unfocus after resizing must restore the same capsule and title as an unfocused pill")
    }

    @Test func selectedAppearanceReturnsWhenFocusLeavesAnotherSeason() throws {
        let selected = SeasonPillView(frame: .zero)
        let other = SeasonPillView(frame: .zero)
        selected.overrideUserInterfaceStyle = .dark
        other.overrideUserInterfaceStyle = .dark
        selected.configure(label: "Season 1", isSelected: true)
        other.configure(label: "Season 2", isSelected: false)
        let row = UIStackView(arrangedSubviews: [selected, other])
        row.frame = CGRect(x: 0, y: 0, width: 680, height: 66)
        row.layoutIfNeeded()
        let selectedAppearance = render(selected)
        let fillProbe = CGPoint(x: selected.bounds.midX, y: 4)
        #expect(try alpha(selectedAppearance, at: fillProbe) > 0)

        try withExtendedLifetime(row) {
            other.setFocused(true)
            let hiddenFill = try alpha(render(selected), at: fillProbe)
            #expect(hiddenFill == 0)
            other.setFocused(false)
            #expect(render(selected).pngData() == selectedAppearance.pngData())
        }
    }

    private func render(_ pill: SeasonPillView) -> UIImage {
        pill.layoutIfNeeded()
        let size = pill.bounds.insetBy(dx: -snapshotPadding, dy: -snapshotPadding).size
        return UIGraphicsImageRenderer(size: size, format: .layeredArtwork(scale: 1)).image { context in
            context.cgContext.translateBy(x: snapshotPadding, y: snapshotPadding)
            pill.layer.render(in: context.cgContext)
        }
    }

    private func alpha(_ image: UIImage, at point: CGPoint) throws -> UInt8 {
        let cgImage = try #require(image.cgImage)
        let x = Int(point.x + snapshotPadding)
        let y = Int(point.y + snapshotPadding)
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                                bitsPerComponent: 8, bytesPerRow: 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1,
                                             width: cgImage.width, height: cgImage.height))
        }
        return pixel[3]
    }
}
