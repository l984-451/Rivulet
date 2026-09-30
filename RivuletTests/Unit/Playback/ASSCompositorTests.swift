import CoreGraphics
import XCTest
@testable import Rivulet

final class ASSCompositorTests: XCTestCase {

    private var allocations: [UnsafeMutablePointer<UInt8>] = []

    override func tearDown() {
        allocations.forEach { $0.deallocate() }
        allocations.removeAll()
        super.tearDown()
    }

    private func bitmap(_ mask: [UInt8], width: Int, height: Int, stride: Int? = nil,
                        color: UInt32, x: Int, y: Int) -> ASSCompositor.Bitmap {
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: mask.count)
        pointer.initialize(from: mask, count: mask.count)
        allocations.append(pointer)
        return ASSCompositor.Bitmap(width: width, height: height, stride: stride ?? width,
                                    pixels: pointer, color: color, x: x, y: y)
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        Array((image.dataProvider?.data as Data?) ?? Data())
    }

    func test_opaqueWhite_isPlacedAtItsOrigin() throws {
        let result = try XCTUnwrap(ASSCompositor.composite([
            bitmap([255, 255], width: 2, height: 1, color: 0xFFFFFF00, x: 3, y: 4)
        ]))
        XCTAssertEqual(result.rect, CGRect(x: 3, y: 4, width: 2, height: 1))
        XCTAssertEqual(bytes(result.image), [255, 255, 255, 255, 255, 255, 255, 255])
    }

    func test_fullyTransparentColour_drawsNothing() {
        XCTAssertNil(ASSCompositor.composite([
            bitmap([255], width: 1, height: 1, color: 0xFFFFFFFF, x: 0, y: 0)
        ]))
    }

    func test_halfBlueOverRed_blendsSourceOverPremultiplied() throws {
        let result = try XCTUnwrap(ASSCompositor.composite([
            bitmap([255], width: 1, height: 1, color: 0xFF000000, x: 0, y: 0),
            bitmap([255], width: 1, height: 1, color: 0x0000FF7F, x: 0, y: 0)
        ]))
        // Memory order B, G, R, A. Blue at opacity 128 over opaque red.
        XCTAssertEqual(bytes(result.image), [128, 0, 127, 255])
    }

    func test_unionRect_coversEveryBitmap() throws {
        let result = try XCTUnwrap(ASSCompositor.composite([
            bitmap([255], width: 1, height: 1, color: 0xFFFFFF00, x: 10, y: 10),
            bitmap([255], width: 1, height: 1, color: 0xFFFFFF00, x: 12, y: 13)
        ]))
        XCTAssertEqual(result.rect, CGRect(x: 10, y: 10, width: 3, height: 4))
    }

    func test_stride_skipsPaddingBytes() throws {
        // Two rows, one visible pixel each, three padding bytes per row.
        let result = try XCTUnwrap(ASSCompositor.composite([
            bitmap([255, 9, 9, 9, 0, 9, 9, 9], width: 1, height: 2, stride: 4, color: 0xFFFFFF00, x: 0, y: 0)
        ]))
        XCTAssertEqual(bytes(result.image), [255, 255, 255, 255, 0, 0, 0, 0])
    }
}
