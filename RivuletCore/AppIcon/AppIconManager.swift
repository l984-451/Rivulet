// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  AppIconManager.swift
//  RivuletCore
//
//  Manages alternate app icons and user icon preferences across iOS and tvOS.
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

public enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case defaultIcon = "default"
    case simpleDark = "simple-dark"
    case simpleLight = "simple-light"
    case pixel = "pixel"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .defaultIcon: return "Default"
        case .simpleDark: return "Simple (Dark)"
        case .simpleLight: return "Simple (Light)"
        case .pixel: return "Pixel"
        }
    }

    /// The alternate icon name declared in Info.plist / Asset catalog.
    /// `nil` indicates the primary (default) app icon.
    public var alternateIconName: String? {
        switch self {
        case .defaultIcon: return nil
        case .simpleDark: return "AppIconSimpleDark"
        case .simpleLight: return "AppIconSimpleLight"
        case .pixel: return "AppIconPixel"
        }
    }

    /// Preview image asset name in xcassets.
    public var previewImageName: String {
        switch self {
        case .defaultIcon: return "AppIconPreviewDefault"
        case .simpleDark: return "AppIconPreviewSimpleDark"
        case .simpleLight: return "AppIconPreviewSimpleLight"
        case .pixel: return "AppIconPreviewPixel"
        }
    }
}

public final class AppIconManager: ObservableObject {
    public static let shared = AppIconManager()

    public static let storageKey = "appIcon"
    public static let didChangeNotification = Notification.Name("AppIconManagerDidChangeNotification")

    @Published public private(set) var currentIcon: AppIconOption

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppIconOption.defaultIcon.rawValue
        currentIcon = AppIconOption(rawValue: stored) ?? .defaultIcon
    }

    public func setIcon(_ option: AppIconOption) {
        guard currentIcon != option else { return }
        currentIcon = option
        UserDefaults.standard.set(option.rawValue, forKey: Self.storageKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: option)
        applyToSystem(option)
    }

    public func syncWithSystem() {
        applyToSystem(currentIcon)
    }

    private func applyToSystem(_ option: AppIconOption) {
        #if canImport(UIKit)
        DispatchQueue.main.async {
            guard UIApplication.shared.supportsAlternateIcons else {
                print("AppIconManager: System reports supportsAlternateIcons = false")
                return
            }
            let targetIconName = option.alternateIconName
            print("AppIconManager: Applying icon '\(String(describing: targetIconName))' (current='\(String(describing: UIApplication.shared.alternateIconName))')")
            if UIApplication.shared.alternateIconName != targetIconName {
                UIApplication.shared.setAlternateIconName(targetIconName) { error in
                    if let error = error {
                        print("AppIconManager: Failed to set alternate icon to '\(String(describing: targetIconName))': \(error.localizedDescription)")
                    } else {
                        print("AppIconManager: Successfully set alternate icon to '\(String(describing: targetIconName))'")
                    }
                }
            }
        }
        #endif
    }
}
