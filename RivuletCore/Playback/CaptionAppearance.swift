// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit
import CoreText
import MediaAccessibility

// MARK: - CaptionStyle

/// Snapshot of the system caption appearance preferences.
// CTFontDescriptor is a CF type with no Sendable conformance; this struct is
// only ever read/written on MainActor so the unchecked conformance is safe.
struct CaptionStyle: Equatable, @unchecked Sendable {

    /// Text/foreground color.
    var foreground: UIColor

    /// True when the system lets the CONTENT's own colour win — the "Video
    /// Override" state in tvOS caption settings, reported as
    /// `MACaptionAppearanceBehavior.useContentIfAvailable` on the foreground
    /// colour read. False means the user forced their colour and any
    /// content-specified colour must be ignored.
    var allowsContentColor: Bool

    /// Opacity of the text itself (0...1). Some system presets (and user
    /// overrides) express "translucent text"; ignoring it renders captions
    /// more opaque than the user asked for.
    var foregroundOpacity: Double

    /// Character-cell background color.
    var backgroundColor: UIColor

    /// Opacity of the character-cell background (0...1).
    var backgroundOpacity: Double

    /// Font size multiplier derived from the system relative-character-size preference.
    /// Applied on top of the size Apple bases on the presentation (view) height.
    var fontScale: CGFloat

    /// True while Apple's built-in Default style is active, which AVKit draws
    /// smaller than its reported size.
    var isSystemDefault: Bool

    /// Video Override state for the character size — gates a cue's own
    /// `fontSize` (ASS `\fs`, SRT `<font size=>`).
    var allowsContentFontSize: Bool

    /// System caption font descriptor. `nil` falls back to the system sans font.
    var fontDescriptor: CTFontDescriptor?

    /// Video Override state for the font — gates a cue's own `fontName` and
    /// its bold / italic / underline / strikethrough.
    var allowsContentFont: Bool

    /// Text edge (shadow/raised/etc.) style.
    var edge: Edge

    enum Edge: Equatable {
        case none
        case dropShadow
        case raised
        case depressed
        case uniform
    }

    /// Builds the caption font for the system settings at a concrete point size.
    /// Uses the configured caption font descriptor when available. `CTFont` and
    /// `UIFont` are toll-free bridged, so the descriptor path costs no copy.
    func font(ofSize size: CGFloat) -> UIFont {
        if let fontDescriptor {
            return CTFontCreateWithFontDescriptor(fontDescriptor, size, nil) as UIFont
        }
        return .systemFont(ofSize: size, weight: .medium)
    }

    static let `default` = CaptionStyle(
        foreground: .white,
        allowsContentColor: true,
        foregroundOpacity: 1.0,
        backgroundColor: .black,
        backgroundOpacity: 0.75,
        fontScale: 1.0,
        isSystemDefault: true,
        allowsContentFontSize: true,
        fontDescriptor: nil,
        allowsContentFont: true,
        edge: .dropShadow
    )

    static func == (lhs: CaptionStyle, rhs: CaptionStyle) -> Bool {
        lhs.foreground == rhs.foreground
            && lhs.allowsContentColor == rhs.allowsContentColor
            && lhs.foregroundOpacity == rhs.foregroundOpacity
            && lhs.backgroundColor == rhs.backgroundColor
            && lhs.backgroundOpacity == rhs.backgroundOpacity
            && lhs.fontScale == rhs.fontScale
            && lhs.isSystemDefault == rhs.isSystemDefault
            && lhs.allowsContentFontSize == rhs.allowsContentFontSize
            && lhs.allowsContentFont == rhs.allowsContentFont
            && lhs.edge == rhs.edge
            && descriptorsEqual(lhs.fontDescriptor, rhs.fontDescriptor)
    }

    private static func descriptorsEqual(_ a: CTFontDescriptor?, _ b: CTFontDescriptor?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (l?, r?): return CFEqual(l, r)
        default: return false
        }
    }
}

// MARK: - CaptionAppearance

enum CaptionAppearance {

    /// Clamps a MediaAccessibility relative-character-size value to a usable font scale.
    /// The API returns a scale (1.0 default, non-positive means unset), quantised on
    /// tvOS 26.5 to 0.35, 0.6, 1.0, 1.5, 2.0, so these bounds never bind. AVKit renders
    /// from the same buckets; `CaptionOverlayView.Metrics.pointSize` maps them (#299).
    static func fontScale(forRelativeSize relative: CGFloat) -> CGFloat {
        guard relative > 0 else { return 1.0 }
        return min(max(relative, 0.25), 4.0)
    }

    /// Profile ID of Apple's built-in Default caption style. MediaAccessibility
    /// marks it not editable, so an edited style is a profile of its own.
    static let systemDefaultProfileID = "MACaptionProfile-Default"

    /// The system caption styles, in Settings order (built-ins first), as (id, display name).
    static func styles() -> [(id: String, name: String)] {
        let builtIns = ["Default", "LargeText", "Classic", "OutlineText"].map { "MACaptionProfile-\($0)" }
        let ids = (MACaptionAppearanceCopyProfileIDs() as? [String]) ?? []
        return ids.map { ($0, MACaptionAppearanceCopyProfileName($0 as CFString) as String) }
            .sorted {
                let a = builtIns.firstIndex(of: $0.0) ?? builtIns.count
                let b = builtIns.firstIndex(of: $1.0) ?? builtIns.count
                return a != b ? a < b : $0.1 < $1.1
            }
    }

    static var activeStyleID: String {
        get { MACaptionAppearanceCopyActiveProfileID() as String }
        set { MACaptionAppearanceSetActiveProfileID(newValue as CFString) }
    }

    /// Reads the current system caption style from MediaAccessibility.
    ///
    /// Uses the `.user` domain so that user-configured overrides take effect.
    /// Each value is fetched with `.useValue` so the system value is authoritative.
    static func current() -> CaptionStyle {
        var behavior = MACaptionAppearanceBehavior.useValue

        // `behavior` is an out param that every MediaAccessibility read overwrites,
        // so each `allowsContent*` is captured right after its own call.
        func contentMayOverride() -> Bool { behavior == .useContentIfAvailable }

        let fgUnmanaged = MACaptionAppearanceCopyForegroundColor(.user, &behavior)
        let foreground = UIColor(cgColor: fgUnmanaged.takeRetainedValue())
        let allowsContentColor = contentMayOverride()
        let rawFgOpacity = Double(MACaptionAppearanceGetForegroundOpacity(.user, &behavior))
        let foregroundOpacity = rawFgOpacity > 0 ? min(rawFgOpacity, 1.0) : 1.0

        // Background color + opacity — the box drawn directly behind the glyphs.
        let bgCG = MACaptionAppearanceCopyBackgroundColor(.user, &behavior).takeRetainedValue()
        let bgOpacity = Double(MACaptionAppearanceGetBackgroundOpacity(.user, &behavior))

        // Window color + opacity — the larger region box. Several built-in styles
        // express their "background" via the window rather than the character
        // background, so fall back to it when the character background is clear.
        let windowCG = MACaptionAppearanceCopyWindowColor(.user, &behavior).takeRetainedValue()
        let windowOpacity = Double(MACaptionAppearanceGetWindowOpacity(.user, &behavior))

        let useWindow = bgOpacity <= 0.01 && windowOpacity > 0.01
        let backgroundColor = UIColor(cgColor: useWindow ? windowCG : bgCG)
        let backgroundOpacity = useWindow ? windowOpacity : bgOpacity

        // Font scale
        let relative = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        let allowsContentFontSize = contentMayOverride()
        let scale = fontScale(forRelativeSize: relative)

        // Font (system caption font descriptor)
        let fontDescriptor = MACaptionAppearanceCopyFontDescriptorForStyle(.user, &behavior, .default)
            .takeRetainedValue()
        let allowsContentFont = contentMayOverride()

        // Edge style
        let maEdge = MACaptionAppearanceGetTextEdgeStyle(.user, &behavior)
        let edge: CaptionStyle.Edge
        switch maEdge {
        case .dropShadow: edge = .dropShadow
        case .raised:     edge = .raised
        case .depressed:  edge = .depressed
        case .uniform:    edge = .uniform
        default:          edge = .none
        }

        return CaptionStyle(
            foreground: foreground,
            allowsContentColor: allowsContentColor,
            foregroundOpacity: foregroundOpacity,
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity,
            fontScale: scale,
            isSystemDefault: MACaptionAppearanceCopyActiveProfileID() as String == systemDefaultProfileID,
            allowsContentFontSize: allowsContentFontSize,
            fontDescriptor: fontDescriptor,
            allowsContentFont: allowsContentFont,
            edge: edge
        )
    }

    /// Posted by the system whenever the user changes caption appearance settings.
    ///
    /// Bridged from `kMACaptionAppearanceSettingsChangedNotification`.
    static let changedNotification = Notification.Name(
        kMACaptionAppearanceSettingsChangedNotification as String
    )
}
