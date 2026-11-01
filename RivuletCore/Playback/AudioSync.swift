import Foundation

/// The user's audio offset for their speakers (#437), one value for every title.
/// Positive plays audio later, negative earlier, the engine's sign.
enum AudioSync {
    static let stepMs = 10
    /// AetherEngine clamps at 2 s (`AudioDelayPolicy.maxAbsSeconds`).
    static let maxMs = 2000
    static let key = "audioSyncOffsetMs"

    static func offsetMs(defaults: UserDefaults = .standard) -> Int {
        clamp(defaults.integer(forKey: key))
    }

    static func seconds(defaults: UserDefaults = .standard) -> Double {
        Double(offsetMs(defaults: defaults)) / 1000
    }

    static func step(by steps: Int, defaults: UserDefaults = .standard) {
        let value = clamp(offsetMs(defaults: defaults) + steps * stepMs)
        if value == 0 { defaults.removeObject(forKey: key) } else { defaults.set(value, forKey: key) }
    }

    /// "0 ms", "+50 ms", "-50 ms": the stepper's centre label.
    static func formatted(_ ms: Int) -> String {
        ms == 0 ? "0 ms" : String(format: "%+d ms", ms)
    }

    private static func clamp(_ ms: Int) -> Int {
        max(-maxMs, min(maxMs, ms))
    }
}
