// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import UIKit
@testable import Rivulet

final class ArtworkTitleCheckTests: XCTestCase {

    private typealias Check = ArtworkTitleCheck
    private typealias Line = Check.RecognizedLine

    // MARK: Text

    func testStylisedMisreadsStillMatch() {
        XCTAssertTrue(Check.textShowsTitle([Line(text: "AMLY", height: 0.2), Line(text: "GUÝ", height: 0.14)],
                                                title: "Family Guy"))
        XCTAssertTrue(Check.textShowsTitle([Line(text: "SIRANGER", height: 0.26), Line(text: "THINGS", height: 0.2)],
                                                title: "Stranger Things"))
        XCTAssertTrue(Check.textShowsTitle([Line(text: "F.R.I•E•N.P.S", height: 0.16)], title: "Friends"))
        XCTAssertTrue(Check.textShowsTitle([Line(text: "TOPGUNE", height: 0.16), Line(text: "-MAVERICK", height: 0.1)],
                                                title: "Top Gun: Maverick"))
    }

    func testOtherTextDoesNotMatch() {
        XCTAssertFalse(Check.textShowsTitle([Line(text: "STRANGER", height: 0.12)], title: "Stranger Things"))
        XCTAssertFalse(Check.textShowsTitle([Line(text: "SCRANTON BUSINESS PARK", height: 0.05)], title: "The Office"))
        // Small print does not count, even when it names the title.
        XCTAssertFalse(Check.textShowsTitle([Line(text: "Breaking Bad", height: 0.02)], title: "Breaking Bad"))
    }

    func testShortTitleMustFillALargeLine() {
        XCTAssertTrue(Check.textShowsTitle([Line(text: "Us", height: 0.46)], title: "Us"))
        XCTAssertFalse(Check.textShowsTitle([Line(text: "BUSINESS", height: 0.3)], title: "Us"))
        XCTAssertFalse(Check.textShowsTitle([Line(text: "IT", height: 0.05)], title: "It"))
    }

    func testArtworkMayDropTheArticleOrTheSubtitle() {
        XCTAssertTrue(Check.textShowsTitle([Line(text: "MATRIX", height: 0.18)], title: "The Matrix"))
        XCTAssertTrue(Check.textShowsTitle([Line(text: "AVENGERS", height: 0.25)], title: "Avengers: Infinity War"))
        XCTAssertTrue(Check.textShowsTitle([Line(text: "MAD MAX", height: 0.2)], title: "Mad Max: Fury Road"))
        // A short part before the colon is too generic to stand for the title.
        XCTAssertFalse(Check.textShowsTitle([Line(text: "DUNE", height: 0.2)], title: "Dune: Part Two"))
        XCTAssertFalse(Check.textShowsTitle([Line(text: "FURY", height: 0.2)], title: "Fury Road: The Wasteland"))
    }

    func testFourLetterTitleMustReadExactly() {
        XCTAssertTrue(Check.textShowsTitle([Line(text: "SILO", height: 0.2)], title: "Silo"))
        XCTAssertFalse(Check.textShowsTitle([Line(text: "SLOTH", height: 0.04), Line(text: "GREED", height: 0.04)], title: "Silo"))
    }

    func testTitleForms() {
        XCTAssertEqual(Check.titleForms("The Matrix").map { String($0) }, ["thematrix", "matrix"])
        XCTAssertEqual(Check.titleForms("Avengers: Infinity War").map { String($0) }, ["avengersinfinitywar", "avengers"])
        XCTAssertEqual(Check.titleForms("It").map { String($0) }, ["it"])
    }

    func testSubstringDistance() {
        XCTAssertEqual(Check.substringDistance(Array("guy"), in: Array("familyguyshow")), 0)
        XCTAssertEqual(Check.substringDistance(Array("familyguy"), in: Array("amlyguy")), 2)
        XCTAssertEqual(Check.substringDistance(Array("abc"), in: []), 3)
    }

    // MARK: Logo

    func testFindsTheLogoPastedOnArtwork() throws {
        let logo = try XCTUnwrap(Self.logo())
        let plain = try XCTUnwrap(Self.artwork(logo: nil))
        let carrying = try XCTUnwrap(Self.artwork(logo: logo))
        XCTAssertTrue(Check.stillContainsLogo(carrying, logo: logo))
        XCTAssertFalse(Check.stillContainsLogo(plain, logo: logo))
    }

    /// A two-colour wordmark on a transparent ground.
    private static func logo() -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 120), format: format).image { _ in
            let font = UIFont.systemFont(ofSize: 96, weight: .black)
            NSAttributedString(string: "LOGO", attributes: [.font: font, .foregroundColor: UIColor.systemYellow])
                .draw(at: CGPoint(x: 10, y: 0))
            UIColor.systemRed.setFill()
            UIRectFill(CGRect(x: 10, y: 104, width: 380, height: 12))
        }.cgImage
    }

    /// A busy 780 x 439 still, with the logo at 35% of its width when given.
    private static func artwork(logo: CGImage?) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 780, height: 439), format: format).image { context in
            for i in 0..<40 {
                UIColor(hue: CGFloat(i) / 40, saturation: 0.6, brightness: 0.4 + CGFloat(i % 5) / 10, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(i * 37 % 780), y: CGFloat(i * 53 % 439), width: 160, height: 90))
            }
            guard let logo else { return }
            UIImage(cgImage: logo).draw(in: CGRect(x: 420, y: 60, width: 273, height: 82))
        }.cgImage
    }
}
