# Parity with the web panel

The goal: everything the panel's web page does, in the app. The panel does it through its own scripts;
the app goes through the panel's JSON API (`docs/api.md` in its repository), so each row needs an
endpoint before it can have a screen. "Now" means the app already does it.

| Panel feature | App |
| --- | --- |
| Upload, resumable | Upload |
| Device: queue, copy, mirror, check, sync log | Device |
| Issues for a device, fix in place | Device, Issues |
| Added since the last copy, copy history | Device |
| Not on the DAP (missing, partial, changed), Queue, Queue all | Device, Not on the Device (the app sends the listing) |
| Send an album to the device | Library, album |
| Needs you: the list, Later | Needs You |
| Import review, MusicBrainz candidates and search, accept | Needs You, an import |
| Import as-is, English names for imports | Needs You, an import |
| Names not in Latin letters | Needs You, Names |
| Covers: find (Cover Art Archive, Apple, Deezer), choose a file | Needs You, Covers; Library, album |
| Library health fixes: split albums, artist spellings, several albums in a folder, files with no tags | Needs You |
| Weekly health report text | Needs You |
| History: runs, search, filters | History |
| Undo preview and undo | History |
| Library: search, filters, sort, lyrics coverage | Library |
| Lyrics: status per track, read, paste, remove, instrumental, look up | Library, album and track |
| Activity: what the panel ran, with its log | Activity |
| ⌘K | ⌘K opens Library search |
| Play a track | Library, queue, issues |

Everything above is a screen in the app and a call in the panel's API (`docs/server-api.md`). Long
actions answer `{"job": id}` and are followed with `GET /api/jobs/{id}`.

Not in the app, on purpose: the web page's theme buttons (the app follows the system) and Navidrome's
own player (the app plays a track itself, to tell what it is). The web page's "Open in Navidrome" is not
there either.
