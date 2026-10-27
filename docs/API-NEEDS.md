# What the app needs from the panel

The app uses today: HTTP Basic with the panel's password (sent up front), `GET /healthz`, the
`/upload/*` chunk protocol, and the panel's HTML job card at `GET /jobs/{id}` (read for the numbers
it shows). Copying to a device uses ssh + rsync, as `dap-sync-mac.sh` does: the queue, sizes and
sync log are read and written over ssh. Everything below replaces one of those workarounds or adds
what the brief needs. JSON, same Basic auth, UTF-8 paths exactly as stored (the app sends them to
rsync as raw bytes; Foundation otherwise decomposes `á` and the server cannot find it).

## 1. Upload (works; two fixes and one convenience)

1. **Positional chunk writes.** `PUT /upload/{batch}/{i}?offset=N` appends at EOF after checking the
   offset once. A request cut off by a pause or a drop can still be draining on the server when the
   resumed one starts, and its late bytes land in the middle of the file. Found by the app's test: a
   pause then resume produced a corrupt file. The app now waits until the byte counts stop moving
   (about a second) before it continues, but the server should open `r+b`, `seek(offset)`, write, and
   answer 409 when `offset > size`; then a late duplicate is harmless.
2. **`POST /upload/{batch}/finish` and `GET /jobs/{id}` as JSON** (on `Accept: application/json`):
   `{"job": 12}` and `{"id": 12, "status": "queued|running|done|failed|interrupted", "result":
   {"tracks_total": 14, "tracks_imported": 11, "tracks_left": 3}, "error": null}`. The app reads the
   HTML card for these today.
3. **Optional integrity check.** A `sha256` per file in `/upload/start`, verified when the batch
   finishes, so silent corruption cannot reach the importer. The app can send it.

## 2. Devices and profiles

4. `GET /api/devices`: `[{"id": "hifi-walker-h2", "name": "HiFi Walker H2", "formats": ["flac", "mp3"],
   "max_sample_rate": 96000, "max_bit_depth": 24, "max_flac_blocksize": 4608, "convert_to":
   {"format": "flac", "sample_rate": 48000, "bit_depth": 16}, "protect": ["/.rockbox/", "/settings.txt"]}]`.
   The app marks a volume with `profile=<id>` in `.dap-sync-target` and has the H2 built in until this exists.
5. **Where a device copies from.** If conversions produce device-specific files, say where: the app
   needs, per device, the folder (and entry names) to rsync from. A field `"source": "<path>"` on the
   device is enough.

## 3. Queue, library and sync log (replaces ssh for these)

6. `GET /api/devices/{id}/queue`: entries with `{"entry": "Artist/Album", "kind": "album|track", "album_id",
   "artist", "album", "bytes", "tracks"}`; `-1` bytes or `"gone": true` for an entry no longer in the library.
7. `POST /api/devices/{id}/queue/complete {"entries": [...]}`: moves exactly those lines to the done
   list under the lock the panel uses (the app does this over ssh today; anything queued during a copy stays queued).
8. `POST /api/sync-log` with the line `dap-sync-mac.sh` appends (`mode`, `result`, `copied`, `removed`, `seconds`, `detail`).
9. *Optional, later:* `GET /api/devices/{id}/manifest` (path, size, mtime) and `GET /api/files/{path}` with
   Range, so a device can be loaded over HTTPS with no ssh or rsync, from anywhere.

## 4. What is wrong for a device, and fixing it

10. `GET /api/devices/{id}/issues?scope=queue|library`: counts by check and the files behind them:
    `{"path", "album_id", "check": "flac_blocksize|sample_rate|bit_depth|format", "value": 8192, "limit": 4608,
    "fixable": true, "bytes"}`.
11. `POST /api/devices/{id}/conversions {"paths": [...]} | {"album_ids": [...]} | {"all": true}`, then
    `GET /api/conversions`: `{"id", "path", "state": "queued|running|done|failed", "progress": 0.4, "error"}`,
    and `DELETE /api/conversions/{id}`. Say whether a fix replaces the library file (with undo) or
    makes a device copy; the app only needs to know which folder to copy from (item 5).

## 5. Playing a track

12. `GET /api/search?q=` and `GET /api/albums/{id}` (tracks with ids and paths), `GET /api/tracks?path=`
    (path to id), and `GET /api/tracks/{id}/stream` proxying Navidrome with Range, so the app holds only
    the panel's credentials and no Navidrome ones.

Auth stays HTTP Basic. The cross-site check (`Sec-Fetch-Site`, `Origin`) passes: the app sends neither.
