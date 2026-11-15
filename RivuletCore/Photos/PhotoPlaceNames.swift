// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  PhotoPlaceNames.swift
//  Rivulet
//
//  A photo's place for the viewer caption ("Portland, OR"), reverse geocoded once per
//  spot for the session. Never logs a coordinate or a name.
//

import CoreLocation
import Foundation
import MapKit

@MainActor
protocol PlaceGeocoding {
    /// nil on any failure.
    func placeName(at coordinate: PhotoCoordinate) async -> String?
}

@MainActor
final class PhotoPlaceNames {
    static let shared = PhotoPlaceNames(geocoder: SystemPlaceGeocoder())

    /// A coordinate rounded to 3 decimals (about 100 m), so a burst of photos shares one lookup.
    struct Key: Hashable {
        let latitude: Int
        let longitude: Int

        init(_ coordinate: PhotoCoordinate) {
            latitude = Int((coordinate.latitude * 1000).rounded())
            longitude = Int((coordinate.longitude * 1000).rounded())
        }
    }

    private let geocoder: any PlaceGeocoding
    private var names: [Key: String] = [:]
    private var inFlight = false
    /// The one request waiting its turn; a newer one sends it away with nil.
    private var waiting: CheckedContinuation<Bool, Never>?
    /// `queuedName` requests, in order, served after `waiting`.
    private var queue: [CheckedContinuation<Void, Never>] = []

    init(geocoder: any PlaceGeocoding) {
        self.geocoder = geocoder
    }

    func cachedName(for coordinate: PhotoCoordinate) -> String? {
        names[Key(coordinate)]
    }

    /// One request at a time (Apple rate-limits the geocoder); while one runs, only the newest waits.
    func name(for coordinate: PhotoCoordinate) async -> String? {
        let key = Key(coordinate)
        if let known = names[key] { return known }
        if inFlight {
            let myTurn = await withCheckedContinuation { continuation in
                waiting?.resume(returning: false)
                waiting = continuation
            }
            guard myTurn else { return nil }
            if let known = names[key] { handOver(); return known }
        }
        return await lookUp(key, coordinate)
    }

    /// Like `name(for:)`, but waits its turn behind every other request instead of being
    /// sent away, for naming a list of places one by one.
    func queuedName(for coordinate: PhotoCoordinate) async -> String? {
        let key = Key(coordinate)
        if let known = names[key] { return known }
        if inFlight {
            await withCheckedContinuation { queue.append($0) }
            if let known = names[key] { handOver(); return known }
        }
        return await lookUp(key, coordinate)
    }

    private func lookUp(_ key: Key, _ coordinate: PhotoCoordinate) async -> String? {
        inFlight = true
        let name = await geocoder.placeName(at: coordinate)
        if let name { names[key] = name }
        handOver()
        return name
    }

    /// The caption's waiting request goes first: it is what's on screen.
    private func handOver() {
        if let next = waiting {
            waiting = nil
            next.resume(returning: true)
        } else if !queue.isEmpty {
            queue.removeFirst().resume()
        } else {
            inFlight = false
        }
    }

    /// "City, Area" at home (MapKit's `cityWithContext`); abroad "City, Country".
    nonisolated static func format(city: String?, cityWithArea: String?, country: String?,
                                   countryCode: String?, homeRegion: String?) -> String? {
        let abroad = countryCode != nil && homeRegion != nil && countryCode != homeRegion
        let parts = abroad ? [city, country] : [cityWithArea ?? city]
        let shown = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return shown.isEmpty ? nil : shown.joined(separator: ", ")
    }
}

/// MapKit's reverse geocoder, in the user's language.
@MainActor
struct SystemPlaceGeocoder: PlaceGeocoding {
    func placeName(at coordinate: PhotoCoordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let address = try? await request.mapItems.first?.addressRepresentations else { return nil }
        return PhotoPlaceNames.format(city: address.cityName, cityWithArea: address.cityWithContext,
                                      country: address.regionName, countryCode: address.region?.identifier,
                                      homeRegion: Locale.current.region?.identifier)
    }
}
