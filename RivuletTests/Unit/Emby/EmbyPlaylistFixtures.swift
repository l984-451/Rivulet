// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyPlaylistFixtures.swift
//  RivuletTests
//
//  Emby 4.10.2.0 playlist, user data and DeleteInfo responses, trimmed to the fields Rivulet decodes.
//

import Foundation

enum EmbyPlaylistFixtures {
    /// `Users/{uid}/Views`: a music library (7), movies (3) and the Playlists view.
    static let views = ##"{"Items":[{"Name":"Movies","Id":"3","Type":"CollectionFolder","CollectionType":"movies"},{"Name":"Music","Id":"7","Type":"CollectionFolder","CollectionType":"music"},{"Name":"Playlists","Id":"1770","Type":"CollectionFolder","CollectionType":"playlists"}],"TotalRecordCount":3}"##

    /// `Items?IncludeItemTypes=Playlist&Recursive=true`: one audio and two video playlists, owner-scoped.
    static let allPlaylists = ##"{"Items":[{"Name":"zz-userdata-form","Id":"1791","CanDelete":false,"RunTimeTicks":57678870000,"IsFolder":true,"ParentId":"1790","Type":"Playlist","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ChildCount":1,"ImageTags":{},"BackdropImageTags":[]},{"Name":"Zz-userdata-audio","Id":"1795","CanDelete":false,"RunTimeTicks":14988825170,"IsFolder":true,"ParentId":"1794","Type":"Playlist","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ChildCount":2,"ImageTags":{},"BackdropImageTags":[]},{"Name":"Aa-weekend","Id":"1801","CanDelete":false,"IsFolder":true,"ParentId":"1800","Type":"Playlist","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ChildCount":4,"ImageTags":{},"BackdropImageTags":[]}],"TotalRecordCount":3}"##

    /// The same call under the music library's `ParentId`: audio playlists only.
    static let musicPlaylists = ##"{"Items":[{"Name":"Zz-userdata-audio","Id":"1795","CanDelete":false,"IsFolder":true,"ParentId":"1794","Type":"Playlist","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ChildCount":2,"ImageTags":{},"BackdropImageTags":[]}],"TotalRecordCount":1}"##

    /// `Playlists/{id}/Items`: each row carries a `PlaylistItemId` apart from its media `Id`.
    static let entries = ##"{"Items":[{"Name":"28 Years Later","Id":"857","PlaylistItemId":"21","Container":"mkv","RunTimeTicks":69069120000,"IsFolder":false,"Type":"Movie","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ImageTags":{},"BackdropImageTags":[],"MediaType":"Video"},{"Name":"The Silence of the Lambs","Id":"873","PlaylistItemId":"22","Container":"mkv","RunTimeTicks":71135980000,"IsFolder":false,"Type":"Movie","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ImageTags":{},"BackdropImageTags":[],"MediaType":"Video"}],"TotalRecordCount":2}"##

    /// The same playlist after an add: the existing rows are renumbered (measured; the id values are illustrative).
    static let entriesAfterAdd = ##"{"Items":[{"Name":"28 Years Later","Id":"857","PlaylistItemId":"31","Type":"Movie","IsFolder":false,"UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ImageTags":{},"BackdropImageTags":[]},{"Name":"The Silence of the Lambs","Id":"873","PlaylistItemId":"32","Type":"Movie","IsFolder":false,"UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ImageTags":{},"BackdropImageTags":[]},{"Name":"Up","Id":"858","PlaylistItemId":"33","Type":"Movie","IsFolder":false,"UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ImageTags":{},"BackdropImageTags":[]}],"TotalRecordCount":3}"##

    /// A row with no `PlaylistItemId`, which a removal or move could not name.
    static let entryWithoutID = ##"{"Items":[{"Name":"Up","Id":"858","Type":"Movie","IsFolder":false,"UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false}}],"TotalRecordCount":1}"##

    /// `POST Playlists?Name=...&Ids=...`.
    static let created = ##"{"Id":"1809","Name":"zz-userdata-fx","ItemAddedCount":2}"##

    /// `Users/{uid}/Items/1809`.
    static let createdItem = ##"{"Name":"zz-userdata-fx","Id":"1809","CanDelete":false,"IsFolder":true,"ParentId":"1808","Type":"Playlist","UserData":{"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":false},"ChildCount":2,"ImageTags":{},"BackdropImageTags":[]}"##

    /// `PlayedItems` and `FavoriteItems` reply for a series after a native mark, 97 episodes.
    static let seriesPlayed = ##"{"UnplayedItemCount":0,"PlaybackPositionTicks":0,"PlayCount":0,"IsFavorite":false,"Played":true}"##

    /// `Items/{id}/DeleteInfo` for a movie (its folder), an episode (its file) and a loose movie file.
    static let movieDeleteInfo = ##"{"Paths":["/library/movies/Up (2009)"]}"##
    static let fileDeleteInfo = ##"{"Paths":["/library/movies/Up (2009).mkv"]}"##
}
