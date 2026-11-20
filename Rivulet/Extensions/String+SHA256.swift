// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  String+SHA256.swift
//  Rivulet
//
//  SHA256 hash extension for generating safe cache filenames
//

import Foundation
import CryptoKit

extension String {
    /// Returns a SHA256 hash of the string, suitable for use as a cache filename
    nonisolated func sha256Hash() -> String {
        // Lowercase hex by hand: String(format:) per byte showed up on the main thread while browsing.
        // Same 64 characters as before, so existing cache files keep matching.
        let digest = SHA256.hash(data: Data(self.utf8))
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in digest {
            let hi = byte >> 4, lo = byte & 0x0F
            out.append(hi < 10 ? 0x30 + hi : 0x57 + hi)   // 0x57 + 10 == "a"
            out.append(lo < 10 ? 0x30 + lo : 0x57 + lo)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
