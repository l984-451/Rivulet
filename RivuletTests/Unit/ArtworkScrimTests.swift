import Testing
import UIKit
@testable import Rivulet

@MainActor
struct ArtworkScrimTests {
    @Test func cancelledCacheMissDoesNotPopulateCacheOrAffectNextRequest() async throws {
        let image = artwork { context in
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        let cancelled = Task { await ArtworkScrim.image(for: image, aspectRatio: 16 / 9) }
        cancelled.cancel()
        let stale = await cancelled.value
        #expect(stale == nil)
        #expect(ArtworkScrim.cachedImage(for: image, aspectRatio: 16 / 9) == nil)

        let current = await ArtworkScrim.image(for: image, aspectRatio: 16 / 9)
        let rendered = try #require(current)
        #expect(ArtworkScrim.cachedImage(for: image, aspectRatio: 16 / 9) === rendered)
    }

    @Test func transparentArtworkHasNoPaletteColor() {
        let image = artwork { _ in }
        let color = ArtworkScrim.analyze(image)
        #expect(color == nil)
    }

    @Test func palettePreservesTheSelectedColorBeforeRendering() throws {
        let image = artwork { context in
            context.setFillColor(UIColor(red: 0.7, green: 0.5, blue: 0.3, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        let actual = try components(ArtworkScrim.analyze(image))
        for (value, expected) in zip(actual, [CGFloat(0.7), 0.5, 0.3]) {
            #expect(abs(value - expected) < 0.005)
        }
    }

    @Test(arguments: [false, true])
    func fadeCompositesColorBelowGrayAndLeavesTheTopClear(missingColor: Bool) throws {
        let image = artwork(size: CGSize(width: 40, height: 400)) { context in
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 400))
        }
        let rendered = try #require(ArtworkScrim.render(image, color: missingColor ? nil : .white, aspectRatio: 0.1))
        let pixels = try pixels(rendered)
        let gray = 40.0 / 255
        let expectedBottom = 0.036 + (missingColor ? 0 : 0.324) + 0.64 * gray
        for channel in 0..<3 {
            #expect(pixels[(200 * 40 + 20) * 4 + channel] == 255)
            let middle = Double(pixels[(240 * 40 + 20) * 4 + channel]) / 255
            #expect(abs(middle - (1 - 0.0364 * (1 - gray))) < 0.012)
            let bottom = Double(pixels[(399 * 40 + 20) * 4 + channel]) / 255
            #expect(abs(bottom - expectedBottom) < 0.012)
        }
    }

    @Test(arguments: [false, true])
    func foregroundDoesNotDetermineBackdrop(brightBackground: Bool) throws {
        let background = brightBackground
            ? UIColor(red: 0.7, green: 0.75, blue: 0.8, alpha: 1)
            : UIColor(red: 0.05, green: 0.1, blue: 0.15, alpha: 1)
        let foreground: UIColor = brightBackground ? .black : .white
        let plain = artwork { context in
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        let withForeground = artwork { context in
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.setFillColor(foreground.cgColor)
            context.fill(CGRect(x: 0, y: 240, width: 640, height: 120))
        }
        let expected = try components(ArtworkScrim.analyze(plain))
        let actual = try components(ArtworkScrim.analyze(withForeground))
        for (lhs, rhs) in zip(actual, expected) {
            #expect(abs(lhs - rhs) < 0.015)
        }
    }

    @Test func vividBackdropDoesNotOverpowerASubstantialMutedRegion() throws {
        let image = artwork { context in
            context.setFillColor(UIColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.setFillColor(UIColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 350, height: 360))
        }
        let color = try components(ArtworkScrim.analyze(image))
        #expect(color[2] < 0.25)
        #expect(color[2] > color[0])
    }

    @Test func whiteSkyDoesNotWashOutTheBackdrop() throws {
        let image = artwork { context in
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.setFillColor(UIColor(red: 0.1, green: 0.12, blue: 0.16, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 240, width: 640, height: 120))
        }
        let color = try components(ArtworkScrim.analyze(image))
        #expect(color.allSatisfy { $0 < 0.25 })
        #expect(color[2] > color[0])
    }

    @Test func transparentPixelsDoNotBecomeTheDominantColor() throws {
        let image = artwork { context in
            context.setFillColor(UIColor.red.cgColor)
            context.fill(CGRect(x: 200, y: 100, width: 200, height: 100))
        }
        let color = try components(ArtworkScrim.analyze(image))
        #expect(color[0] > color[1] + 0.3)
        #expect(color[0] > color[2] + 0.3)
    }

    @Test func renderedArtworkIsCachedSeparatelyForEachSourceAndCrop() async throws {
        let red = artwork { context in
            context.setFillColor(UIColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        let blue = artwork { context in
            context.setFillColor(UIColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }
        #expect(ArtworkScrim.cachedImage(for: red, aspectRatio: 16 / 9) == nil)
        let redResult = await ArtworkScrim.image(for: red, aspectRatio: 16 / 9)
        let renderedRed = try #require(redResult)
        #expect(ArtworkScrim.cachedImage(for: red, aspectRatio: 16 / 9) === renderedRed)
        let repeated = await ArtworkScrim.image(for: red, aspectRatio: 16 / 9)
        #expect(repeated === renderedRed)
        let blueResult = await ArtworkScrim.image(for: blue, aspectRatio: 16 / 9)
        let renderedBlue = try #require(blueResult)
        #expect(renderedRed !== renderedBlue)
        let redPixels = try pixels(renderedRed)
        let bluePixels = try pixels(renderedBlue)
        #expect(redPixels[0] > redPixels[2])
        #expect(bluePixels[2] > bluePixels[0])
        #expect(ArtworkScrim.cachedImage(for: red, aspectRatio: 1) == nil)
        let squareResult = await ArtworkScrim.image(for: red, aspectRatio: 1)
        let square = try #require(squareResult)
        #expect(square.size.width == square.size.height)
        #expect(ArtworkScrim.cachedImage(for: red, aspectRatio: 1) === square)
        #expect(ArtworkScrim.cachedImage(for: red, aspectRatio: 16 / 9) == nil)
    }

    @Test func fadeStaysAtTheBottomAfterCroppingPortraitArtwork() throws {
        let image = artwork(size: CGSize(width: 40, height: 120)) { context in
            context.setFillColor(UIColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 40, width: 40, height: 40))
            context.setFillColor(UIColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 80, width: 40, height: 40))
        }
        let rendered = try #require(ArtworkScrim.render(image, color: .black, aspectRatio: 2))
        #expect(rendered.size == CGSize(width: 120, height: 60))
        let pixels = try pixels(rendered)
        #expect(pixels[0] == 255)
        #expect(pixels[1] == 255)
        #expect(pixels[2] == 255)
        let bottom = (59 * 120 + 60) * 4
        #expect(pixels[bottom] < 80)
        #expect(pixels[bottom] == pixels[bottom + 2])
    }

    @Test(arguments: [CGFloat.zero, -1, .infinity, .nan])
    func invalidCropDoesNotRender(aspectRatio: CGFloat) {
        let image = artwork { _ in }
        #expect(ArtworkScrim.render(image, color: nil, aspectRatio: aspectRatio) == nil)
    }

    private func artwork(size: CGSize = CGSize(width: 640, height: 360), draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image {
            draw($0.cgContext)
        }
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let image = try #require(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func components(_ color: UIColor?) throws -> [CGFloat] {
        let color = try #require(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        #expect(color.getRed(&red, green: &green, blue: &blue, alpha: nil))
        return [red, green, blue]
    }
}
