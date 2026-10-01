# Plex Collections: Apple TV checks

Everything below needs the Apple TV. Unit tests (1104), the tvOS and iOS builds and lint all pass, but none of them exercise focus, Menu, or real presentation. Run a Debug build of `feature/plex-collections` from Xcode against the home PMS (`192.168.1.140:32400`). Titles and rating keys were read from that server on 2026-09-30.

Use a Siri Remote throughout, then repeat the Menu checks (A2, A3) with a clickpad-only or IR/CEC remote and with the iPhone Remote.

Network Link Conditioner ("Very Bad Network") is under Settings > Developer on a paired Apple TV, or in Xcode > Devices and Simulators > this Apple TV > Device Conditions.

## A. Run these first (highest risk)

**A1. Open a collection.** Movies > Collections row > James Bond (rk 9144) > Select. The page blur-fades in with its title header; focus lands on Dr. No once it loads. The preview carousel never appears.

**A2. Menu closes the page, focus returns to the library.** From a first-row tile, Menu: the page fades out and focus is back on the James Bond tile, library at the same scroll position. Reopen, go down three rows, Menu: it closes on the first press (no stop at the top row).

**A3. Loading window.** Conditioner on Very Bad Network. Focus a genre-row tile below the Collections row, then Select a collection tile. While it loads:
- Down, Left, Right, touch-surface swipes: nothing moves; the library underneath does not scroll.
- Select: no carousel opens.
- Menu: the page closes; the library stays put, does not jump to its hero; the sidebar does not open.
- Menu again: the library's normal return to its top row.
Turn the conditioner off.

**A4. Impatient presses during the fade.** Normal network. Select a Collections tile, then Menu within half a second: Menu is ignored during the fade, the page finishes opening and stays up, nothing moves underneath. A second Menu closes it with focus on the same tile. Repeat with Select then Select: the page opens on its first tile, no carousel. Repeat both on Very Bad Network.

**A5. Collection shrinks under focus (the crash case).** In Plex Web, add 70 movies to a new manual collection "AAA Shrink Test 2". Relaunch, open it, go down to row 11 so slots 60 to 69 load, focus slot 65. In Plex Web remove 15 members (count 55). In Rivulet long-press the focused tile > Mark as Watched. No crash; the grid ends at 55 with no blank tile; focus is on a surviving tile and moves. Repeat with play-and-exit instead of Mark as Watched. Undo in Plex Web.
Smaller variant: a 5-movie collection, focus tile 5, remove movie 4, Mark as Watched: 4 tiles, focus on one of them.

**A6. Detail trailing tile, and the stack unwind.** Raiders of the Lost Ark (rk 87157) > details. Its "IMDb Top 250 Collection" row ends with a trailing collection tile. Right to it, Select: the IMDb Top 250 page opens (collection 118562, not 118561). Menu: focus is back on the trailing tile and the row is still scrolled to its end. Then from that page open Forrest Gump > details > its IMDb Top 250 row > trailing tile > Select: the existing page comes back (no second copy stacked); one more Menu returns to Raiders.

**A7. Cold launch with a pin.** Pin James Bond (section D), force-quit, relaunch, and wait 30 seconds without touching anything. The James Bond row is on Home in the Movies block and stays there. If it vanishes until the next navigation, report it (the pin loader's token check may be dropping a fetch during the profile restore).

## B. Paging (existing-bug fix; data behaviour, Simulator is informative)

1. Movies, Recently Added: Right past tile 48. Tiles keep arriving newest-added first. Tile 25 is not "The Adventures of Huck Finn". (Before: stopped at 48, page 2 in title order.)
2. Movies, a genre row (Crime, unwatched, 7+): ends at its filtered total (61 on 2026-09-30), all matching.
3. TV, Recently Released Episodes: past 24 and 48, still episodes, newest first. (Before: shows in title order from "The Artful Dodger".)
4. TV, Recently Added: now pages past 24, up to about 50.
5. Home, promoted Recently Added Movies: past 48 in added order.
6. Continue Watching unchanged: Home CW same tiles, no duplicates, no stuck skeleton; TV library CW stops at 25.
7. Hold Right on Recently Released Episodes (20,770 total) for about 20 seconds: stays responsive.
8. Promote Action Movies (416) to Home in Plex, relaunch: the row pages past 48 in the collection's order. Unpromote after.

## C. Library: Collections row and Titles / Collections switch

1. Movies rows: Continue Watching, Recently Released, Recently Added, **Collections**, genre rows, sort header, grid. TV: Continue Watching, Recently Released Episodes, Recently Added, **Collections**.
2. Collections row order matches Plex Web's Collections tab (Kometa lists first). Batman, Die Hard, Genre Collections absent; James Bond present. Composite posters render for Cinderella, The Hobbit, Marvel Studios. No progress bar or watched glyph on collection tiles.
3. Settings > Appearance > Library: Recent Rows off puts Collections right after Continue Watching; Discovery Rows off keeps Collections. Restore.
4. Focused tile stays still: cold launch, Very Bad Network, open Movies, press Down at once to a genre row. When Collections appears above, the focused tile does not move. Up once reaches Collections. Also try it with focus on the A to Z strip.
5. Admin reorder: in Plex Web drag a genre hub above Continue Watching; Collections still follows Recently Added. Restore.
6. Play a title from a genre row and exit: no jump, no flicker, focus back on the same tile.
7. Switch (Settings: Hero off, Discovery Rows off for this block, restore after):
   - It appears as a "Titles" pill when the Collections row arrives; the sort pill moves left.
   - Select: "Collections", stays focused, sort pill gone, count "71 collections", collection posters, no A to Z bar.
   - Select again: "Titles", sort pill back, grid refills in the saved sort. Left/Right move between the two pills.
   - Collections grid: Down into it, no placeholders past the last collection, Up returns to the pill. A tile opens its page; Menu comes back to the same tile.
   - Remembered path: in Titles use A to Z to reach slot about 500, Menu, Down to the header, switch to Collections, Menu, Menu (sidebar), Right: focus lands on a visible item. If not, report it.
   - Sort change in a library with no collections: change the sort, Menu to the top row, Menu to the sidebar, Right: focus lands on a visible item.
   - Held swap: create "AAA Rivulet Test" in Plex Web, open about the 10th Collections grid tile, play a member 10 s, exit, wait 5 s, Menu out: same tile, same collection. Then from a hub row play 10 s and wait: the new collection appears in the grid at its server position. Delete it and repeat: it goes away.
8. Collection page, large (Action Movies, 416): Down past slot 60 and 120, every row fills in order, header once at top; hold Down 3 s: no index dots on the right, focus on a tile after release.
9. Collection page watch state: in James Bond, Mark as Watched on Live and Let Die: glyph appears in place, focus stays. Play Dr. No 30 s, exit, close the carousel: Dr. No shows progress without reopening the page.
10. Member round trip: Select a member (carousel opens), Menu: back on that tile, page still up.
11. Try Again: 100% loss, open a collection, wait for the error, Try Again (Menu still closes it while loading). Turn loss off, Try Again: focus on the first tile.
12. Long press on a Collections tile in a library NOT pinned to Home: no popup. Play/Pause on a collection tile: nothing plays.
13. Library grid regression (shared paging code): Down past slot 60 and 120 fills every row; changing sort reloads from the top; A to Z jump loads tiles.

## D. Pins

Setup: in Plex Web, Movies is pinned to Home and James Bond is not promoted.

1. Movies > Collections row > James Bond > hold Select: one action, "Pin to Home". Select it; Home shows a James Bond row inside the Movies block, four films in release order.
2. Hold Select again: "Unpin from Home" in red. Select it; the Home row is gone at once.
3. From the Collections grid: pinned shows "Unpin", another collection shows "Pin".
4. A collection promoted to Home in Plex: no popup. A member tile of the pinned row on Home: the normal movie menu.
5. Settings > Appearance > Rows: "James Bond" is not among the toggles; a "PINNED COLLECTIONS" caption follows with a red "James Bond" row. Left panel: pin icon and "A collection you pinned to Home from its tile menu. Select to unpin it."
6. With two pins, Select one: it leaves the list and focus stays on a list row. Select the last: row and caption leave, focus stays in the list. If focus drops off the list, report it (fix: batch delete instead of reloadData).
7. Show All with a pin present: the pin stays listed.
8. Un-pin Movies from Home in Plex Web, relaunch: no James Bond row on Home, no popup on its tile, but it is still listed under Pinned Collections where Select unpins it. Restore.
9. Another Plex Home profile lists only its own pins.
10. Pin Action Movies, hold Right on its Home row past 48 and 72: keeps loading in order, no repeats. Unpin after.
11. No-pin smoke: Home rows and Settings Rows toggles are the same as before this branch.

## E. Detail page

1. Diamonds Are Forever (rk 55947): a "James Bond Collection" row with Dr. No, Live and Let Die, No Time to Die in that order, itself absent, no trailing tile.
2. Raiders: "IMDb Top 250 Collection" row (11 members, Raiders absent) plus the trailing tile. Related below shows the Spielberg and Harrison Ford titles, none of the collection row's tiles, no TV shows, not Raiders.
3. Two shelves: focus Related tile 2, go Up to the collection row's trailing tile, Select, Menu: focus returns to the trailing tile. Then focus collection tile 3, Up to a trailer, play it, exit: focus returns to that trailer.
4. Watch state: Braveheart (last member) > standalone detail > Watched > Menu: its tile updates after a brief cross-dissolve, row still at its end. Same on a Related tile. Playback variant: play Braveheart to the end, Menu twice: watched glyph appears. Also return within 2 s with focus on Braveheart's tile: focus survives the cross-dissolve. Restore watched states.
5. Aladdin and the King of Thieves (rk 63793): the bottom peek strip is the Disney Collection row with its title; Down slides it up; no Related row; a trailing tile ends the row.
6. UNTAMED (rk 141852, TV): an "IMDb Popular Collection" row of shows with a trailing tile (opens 118566), no "Movies in IMDb Popular Collection" row.

## If a check fails

- A2 loses the tapped tile: in `presentPreview`, store `pendingPreviewRestore` for the tapped tile and pass `onDismiss: { [weak self] in self?.applyPendingPreviewRestoreIfNeeded() }` to `openCollectionIfNeeded`.
- A2, A3 or A4 Menu does not close the page after the fade: dismiss from the page's own `handleMenuBack` (collection mode, focus inside `view`, `dismiss(animated: true)`, return true). Re-run A2 to A4 and C10 (C10 must still close only the carousel).
- A4 fails in the one-runloop gap after the fade: gate the Menu drop on collection mode, `presentedViewController == nil`, and focus not inside `view`.
- A6 focus lands elsewhere in the row: defer `restoreBelowFoldFocusAfterReturn()` by one runloop.
- A5 loses focus entirely: in `loadGridPage`'s success path, when a shrink deletes the focused slot in collection mode, set `pendingGridFocusItem = total - 1` and call `focusPendingGridSlot()` after the apply.
