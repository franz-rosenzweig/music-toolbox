# Music Toolbox

A native Mac app for one job: getting music from a Mac into a self-hosted library, and from the
library onto players. Not a music player.

- **Upload**: folders and files, by drag and drop or the Add menu. Chunked and resumable (the panel's
  `/upload` protocol, with a checksum per file); pausing, a dropped connection or quitting the app all
  carry on where they stopped.
- **Devices**: a player is any volume with a `.dap-sync-target` marker (the file the `dap-sync-mac.sh`
  script writes, so both agree). The device's queue on the panel is copied to it with rsync over ssh;
  Everything, Mirror (with the list of what it would remove, behind a confirmation) and Check are in the
  More menu. The panel's profile for the device says what it can play; Issues lists files it cannot, and
  Fix has the panel repair them in place (undoable from its History page).
- **Library**: search, open an album, play a track to see what it is. Nothing more than that.
- **UI is labels only**: counts, names and controls. No hint lines, taglines or captions.

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
./selftest.sh [WORK]                  # stand-in panel, pretend server, an exFAT disk image as the player
./selftest.sh WORK --real user@host   # instead: one small album from the real library, read-only there
```

The app drives its own upload and copy code; the script then compares files byte for byte. Pictures
land in `WORK/out`. The window is on screen for about a minute and a disk called MTTESTDAP comes and goes.

The server API the app uses is in [docs/server-api.md](docs/server-api.md).
