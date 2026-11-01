import Foundation

/// How the player treats one kind of marker (intro, credits, recap, commercial):
/// no button, a Skip button, or an automatic skip. Stored as two keys so the
/// older `autoSkip*` toggles keep their meaning.
enum MarkerSkipMode: String, CaseIterable {
    case off, manual, automatic

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .automatic: return "Automatic"
        case .off: return "Off"
        }
    }

    static func current(for markerType: String, defaults: UserDefaults = .standard) -> MarkerSkipMode {
        guard let suffix = keySuffix(markerType) else { return .manual }
        if defaults.object(forKey: "showSkip" + suffix) as? Bool == false { return .off }
        return defaults.bool(forKey: "autoSkip" + suffix) ? .automatic : .manual
    }

    static func set(_ mode: MarkerSkipMode, for markerType: String, defaults: UserDefaults = .standard) {
        guard let suffix = keySuffix(markerType) else { return }
        defaults.set(mode != .off, forKey: "showSkip" + suffix)
        defaults.set(mode == .automatic, forKey: "autoSkip" + suffix)
    }

    private static func keySuffix(_ markerType: String) -> String? {
        switch markerType {
        case "intro": return "Intro"
        case "recap": return "Recap"
        case "credits": return "Credits"
        case "commercial": return "Ads"
        default: return nil
        }
    }
}
