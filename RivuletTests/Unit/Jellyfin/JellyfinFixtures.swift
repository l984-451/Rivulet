// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinFixtures.swift
//  RivuletTests
//
//  Response bodies shaped from the Jellyfin 12.1 OpenAPI spec. Replace them
//  with captures from a live server when one is available (plan Task 7).
//

import Foundation
@testable import Rivulet

enum JellyfinFixtures {
    /// A minimal agnostic item for surface tests that never touch the server.
    static func mediaItem(_ id: String, kind: MediaKind = .movie, providerID: String = "jellyfin:srv",
                          played: Bool = false, grandparent: String? = nil) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: id),
            kind: kind, title: id, sortTitle: nil, overview: nil, year: nil, runtime: nil,
            parentRef: nil,
            grandparentRef: grandparent.map { MediaItemRef(providerID: providerID, itemID: $0) },
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: played, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    static let baseURL = URL(string: "http://jf.local:8096")!

    static func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) -> T {
        try! JellyfinJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    static let episode = """
    {"Id":"ep1","Name":"Pilot","SortName":"pilot","Type":"Episode","Overview":"It begins.",
     "ProductionYear":2008,"PremiereDate":"2008-01-20T00:00:00.0000000Z","OfficialRating":"TV-MA",
     "RunTimeTicks":34560000000,"SeriesId":"show1","SeasonId":"season1","ParentId":"season1",
     "IndexNumber":1,"ParentIndexNumber":1,
     "UserData":{"PlaybackPositionTicks":6000000000,"Played":false,"IsFavorite":true,
                 "LastPlayedDate":"2026-09-01T20:15:30.1234567Z"},
     "ImageTags":{"Primary":"epPrim"},"BackdropImageTags":[],
     "ParentBackdropItemId":"show1","ParentBackdropImageTags":["showBack"],
     "ParentLogoItemId":"show1","ParentLogoImageTag":"showLogo",
     "ParentPrimaryImageItemId":"season1","ParentPrimaryImageTag":"seasonPrim",
     "SeriesPrimaryImageTag":"showPrim"}
    """

    static let series = """
    {"Id":"show1","Name":"Breaking Bad","Type":"Series","RecursiveItemCount":62,
     "UserData":{"Played":false,"UnplayedItemCount":50,"PlaybackPositionTicks":0},
     "ImageTags":{"Primary":"showPrim","Logo":"showLogo"},"BackdropImageTags":["showBack"],
     "ParentId":"lib-tv","ProviderIds":{"Tmdb":"1396","Imdb":"tt0903747"},
     "Taglines":["Remember my name"],"Genres":["Drama"],"Studios":[{"Name":"AMC","Id":"s1"}],
     "People":[{"Id":"p1","Name":"Bryan Cranston","Role":"Walter White","Type":"Actor","PrimaryImageTag":"pt"},
               {"Id":"p2","Name":"Vince Gilligan","Type":"Director"},
               {"Id":"p3","Name":"Some Writer","Type":"Writer"},
               {"Id":"p4","Name":"Guest","Role":"Tuco","Type":"GuestStar"}],
     "CommunityRating":8.9,"ProductionLocations":["United States of America"],
     "Chapters":[{"StartPositionTicks":0,"Name":"Start","ImageTag":"c0"},
                 {"StartPositionTicks":3000000000,"Name":"Middle"}]}
    """

    static let movie = #"{"Id":"m1","Name":"Heat","Type":"Movie","ParentId":"lib-movies"}"#

    static let userViews = """
    {"Items":[{"Id":"a","Name":"Movies","CollectionType":"movies"},
              {"Id":"b","Name":"Shows","CollectionType":"tvshows"},
              {"Id":"c","Name":"Mixed"},
              {"Id":"d","Name":"Books","CollectionType":"books"},
              {"Id":"e","Name":"Collections","CollectionType":"boxsets"}],
     "TotalRecordCount":5}
    """

    /// Two versions of one title. The first direct-plays; the second is a
    /// source the server will not direct-play. Numbered the way Jellyfin
    /// numbers streams: external files first (here three subtitles, 0 to 2),
    /// then the container's own streams, so container stream N is Index N + 3.
    static let playbackInfo = """
    {"PlaySessionId":"psid-1","MediaSources":[
     {"Id":"src-4k","Name":"4K","Container":"mkv","Size":60000000000,"Bitrate":80000000,
      "RunTimeTicks":34560000000,"SupportsDirectPlay":true,
      "DefaultAudioStreamIndex":5,"DefaultSubtitleStreamIndex":0,
      "MediaStreams":[
       {"Index":0,"Type":"Subtitle","Codec":"subrip","Language":"spa","IsExternal":true,
        "IsTextSubtitleStream":true,"IsForced":true},
       {"Index":1,"Type":"Subtitle","Codec":"ass","Language":"jpn","IsExternal":true,"IsTextSubtitleStream":true},
       {"Index":2,"Type":"Subtitle","Codec":"PGSSUB","Language":"fre","IsExternal":true,"IsTextSubtitleStream":false},
       {"Index":3,"Type":"Video","Codec":"hevc","Profile":"Main 10","Level":153,"Width":3840,"Height":2160,
        "RealFrameRate":23.976,"VideoRangeType":"DOVIWithHDR10","DvProfile":8,"IsInterlaced":false,"IsDefault":true},
       {"Index":4,"Type":"Audio","Codec":"truehd","Channels":8,"ChannelLayout":"7.1","Language":"eng",
        "DisplayTitle":"English - TRUEHD - 7.1","AudioSpatialFormat":"DolbyAtmos","IsDefault":true},
       {"Index":5,"Type":"Audio","Codec":"dts","Profile":"DTS-HD MA","Channels":6,"Language":"eng",
        "DisplayTitle":"English - DTS-HD MA - 5.1"},
       {"Index":6,"Type":"Subtitle","Codec":"PGSSUB","Language":"eng","IsExternal":false,"IsTextSubtitleStream":false}]},
     {"Id":"src-1080","Name":"1080p","Container":"mp4","SupportsDirectPlay":false,"MediaStreams":[]}]}
    """

    /// One video stream with the given range type and transfer characteristic.
    static func videoStream(rangeType: String, transfer: String?) -> String {
        let transferField = transfer.map { #","ColorTransfer":"\#($0)""# } ?? ""
        return #"{"Index":0,"Type":"Video","Codec":"hevc","VideoRangeType":"\#(rangeType)"\#(transferField)}"#
    }

    static func publicInfo(id: String = "srv", version: String = "12.1.0",
                           product: String = "Jellyfin Server") -> String {
        #"{"Id":"\#(id)","ServerName":"NAS","Version":"\#(version)","ProductName":"\#(product)"}"#
    }
}
