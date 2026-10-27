# Music Toolbox

A native Mac app for one job: getting music from a Mac into a self-hosted library, and from the
library onto players. Not a music player.

- **Needs You**: what waits on a decision: imports (MusicBrainz candidates and search, accept, import
  as-is, English names), names not in Latin letters, covers, and the library health fixes.
- **Upload**: folders and files, by drag and drop or the Add menu. Chunked and resumable (the panel's
  `/upload` protocol, with a checksum per file); pausing, a dropped connection or quitting the app all
  carry on where they stopped.
- **Library**: search, filters and sort, the lyrics coverage, an album's covers and lyrics (read, paste,
  remove, instrumental, look up), send it to a device, and play a track to see what it is.
- **History** and **Activity**: every change with an undo that says what it would do first, and the
  jobs the panel ran with their logs.
- **Devices**: a player is any volume with a `.dap-sync-target` marker (the file the `dap-sync-mac.sh`
  script writes, so both agree). The device's queue is copied to it with rsync over ssh; Everything,
  Mirror (with the list of what it would remove, behind a confirmation) and Check are in the More menu.
  The device page also lists what it cannot play (Fix has the panel repair it in place), the albums
  added since the last copy, and the copy history.
- **UI is labels only**: counts, names and controls. No hint lines, taglines or captions.

All of it goes through the panel's JSON API, so it does what the web page does ([docs/PARITY.md](docs/PARITY.md)).

## Build

Needs macOS 26, Xcode, and Homebrew's rsync 3.1+ (`brew install rsync`; Apple's has no `--info`).

```sh
./build.sh && open "build/Music Toolbox.app"
```

Signed with an Apple Development identity if the keychain has one, ad hoc otherwise (`MUSIC_SIGN` picks).

## First run

Settings asks for the panel's address, user and password (kept in the Keychain), and for the ssh
address and music folder of the server that holds the library (rsync's road). Nothing about a server is
built into the app.

## Test

```sh
PANEL_SAMPLES=FILE ./selftest.sh      # also replay the panel's recorded answers for History, lyrics, covers, health
./selftest.sh [WORK]                  # stand-in panel, pretend server, an exFAT disk image as the player
./selftest.sh WORK --real user@host   # instead: one small album from the real library, read-only there
```

The app drives its own upload and copy code; the script then compares files byte for byte. Pictures
land in `WORK/out`. The window is on screen for about a minute and a disk called MTTESTDAP comes and goes.

The server API the app uses is in [docs/server-api.md](docs/server-api.md).
