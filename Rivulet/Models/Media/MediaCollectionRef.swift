//
//  MediaCollectionRef.swift
//  Rivulet
//
//  Lightweight reference to a collection an item belongs to. Carries the
//  provider-native id plus the display name. Distinct from a full collection
//  entity (which a future browse surface would model as `MediaItem` with
//  `kind == .collection`) — this type only needs to identify and label a
//  collection, not render it as a tile.
//

import Foundation

struct MediaCollectionRef: Hashable, Identifiable, Sendable {
    /// Provider-native ID. For Plex this is the stringified `Collection[].id`
    /// used by `/library/sections/{sectionId}/all?collection={id}`.
    let id: String
    let name: String
}
