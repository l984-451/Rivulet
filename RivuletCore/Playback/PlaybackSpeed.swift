import Foundation

/// The player's speed menu (#426), shared by both apps. A speed lasts for one player session:
/// Up Next keeps it, closing the player puts it back to 1×. Live TV offers none.
nonisolated enum PlaybackSpeed {
    /// AVKit's set (`AVPlaybackSpeed.systemDefaultSpeeds`).
    static let standard: [Float] = [0.5, 1, 1.25, 1.5, 2]

    /// What AVPlayer plays reliably on a server transcode; above 2× it needs fast-forward support.
    static let transcodeMaxRate: Float = 2

    /// The speeds to offer for an item whose player tops out at `maxRate`.
    /// Empty when it can't play faster than 1×, which hides the control.
    static func choices(maxRate: Float) -> [Float] {
        guard maxRate > 1 else { return [] }
        return standard.filter { $0 <= maxRate + 0.001 }
    }

    /// "1.25×", in the viewer's number format.
    static func label(_ rate: Float, locale: Locale = .current) -> String {
        let number = Double(rate).formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        return String(localized: "\(number)×", comment: "Playback speed, such as 1.25×")
    }

    /// Wall-clock seconds `mediaSeconds` of media take to play at `rate`.
    static func wallSeconds(forMedia mediaSeconds: TimeInterval, at rate: Float) -> TimeInterval {
        rate > 0 ? mediaSeconds / TimeInterval(rate) : mediaSeconds
    }

    /// Media seconds that play in `wallSeconds` at `rate`.
    static func mediaSeconds(forWall wallSeconds: TimeInterval, at rate: Float) -> TimeInterval {
        rate > 0 ? wallSeconds * TimeInterval(rate) : wallSeconds
    }
}
