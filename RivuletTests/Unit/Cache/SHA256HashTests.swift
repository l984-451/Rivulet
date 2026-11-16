// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The image cache names its files with `sha256Hash()`. Another spelling would orphan every
/// cached image, so this pins lowercase, 64-character hex.
final class SHA256HashTests: XCTestCase {
    func test_sha256Hash_isLowercaseHex() {
        XCTAssertEqual("abc".sha256Hash(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual("".sha256Hash(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
