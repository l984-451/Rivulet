// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Which music tracks AVPlayer cannot decode and so go to the engine (#544).
/// A denylist: a codec not named here (or missing) plays through AVPlayer as before.
enum MusicCodecPolicy {
    /// Names as Plex, Jellyfin and Emby spell them, compared lowercased with punctuation removed.
    private static let engineCodecs: Set<String> = [
        "truehd", "mlp", "dca", "opus", "vorbis", "ape", "wavpack", "wv", "tta",
        "mpc", "mpc7", "mpc8", "musepack", "tak", "mp2", "mp1",
    ]
    private static let engineCodecPrefixes = ["dts", "wma", "dsd"]

    static func needsEngine(codec: String?) -> Bool {
        guard let codec else { return false }
        let name = String(codec.lowercased().filter { $0.isLetter || $0.isNumber })
        return engineCodecs.contains(name) || engineCodecPrefixes.contains { name.hasPrefix($0) }
    }
}
