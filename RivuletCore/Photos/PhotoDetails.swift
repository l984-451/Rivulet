// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoDetails.swift
//  Rivulet
//
//  A photo's camera facts and where it was taken, as far as its server says.
//

import Foundation

nonisolated struct PhotoCoordinate: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

nonisolated struct PhotoDetails: Hashable, Sendable {
    var takenAt: Date?
    var make: String?
    var model: String?
    var lens: String?
    var fNumber: Double?
    var exposureSeconds: Double?
    var iso: Int?
    var focalLength: Double?
    var width: Int?
    var height: Int?
    var fileName: String?
    /// How `takenAt` reads.
    enum Clock: Hashable, Sendable {
        /// A day with no time (Plex).
        case day
        /// The camera's clock stamped UTC (Jellyfin and Emby with EXIF).
        case wallClock
        /// A real instant (Jellyfin and Emby without EXIF, clips).
        case instant
    }
    var takenAtClock = Clock.day

    /// These details, each gap filled from `listed`.
    func merged(over listed: PhotoDetails?) -> PhotoDetails {
        guard let listed else { return self }
        var merged = self
        merged.takenAt = takenAt ?? listed.takenAt
        merged.make = make ?? listed.make
        merged.model = model ?? listed.model
        merged.lens = lens ?? listed.lens
        merged.fNumber = fNumber ?? listed.fNumber
        merged.exposureSeconds = exposureSeconds ?? listed.exposureSeconds
        merged.iso = iso ?? listed.iso
        merged.focalLength = focalLength ?? listed.focalLength
        merged.width = width ?? listed.width
        merged.height = height ?? listed.height
        merged.fileName = fileName ?? listed.fileName
        return merged
    }

    /// "Apple iPhone Air"; the model alone when it already starts with the make.
    var cameraLine: String? {
        switch (make, model) {
        case let (make?, model?):
            model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        case let (make?, nil): make
        case let (nil, model?): model
        case (nil, nil): nil
        }
    }

    /// "f/1.6 · 1/5 s · ISO 3200 · 6 mm", missing parts dropped.
    var exposureLine: String? {
        let parts = [
            fNumber.map { "f/" + String(format: "%g", $0) },
            exposureSeconds.map(Self.exposureText),
            iso.map { "ISO \($0)" },
            focalLength.map { "\(Int($0.rounded())) mm" }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// An APEX aperture value as an f-number: 2^(A/2), to one decimal.
    static func fNumber(apex: Double) -> Double {
        (pow(2, apex / 2) * 10).rounded() / 10
    }

    /// Plex's "f/1.6".
    static func fNumber(plex: String) -> Double? {
        Double(plex.hasPrefix("f/") ? String(plex.dropFirst(2)) : plex)
    }

    /// Plex's "1/5" or "2".
    static func exposureSeconds(plex: String) -> Double? {
        let parts = plex.split(separator: "/")
        if parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom > 0 {
            return top / bottom
        }
        return Double(plex)
    }

    /// "1/80 s" under a second, else "2 s".
    static func exposureText(_ seconds: Double) -> String {
        seconds < 1 && seconds > 0
            ? "1/\(Int((1 / seconds).rounded())) s"
            : String(format: "%g s", seconds)
    }

    /// A server string with nothing in it is no value.
    static func text(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The last component of a server file path.
    static func fileName(_ path: String?) -> String? {
        text(path).flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) }
    }
}
