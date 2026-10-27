# The server API the app uses

The panel's JSON API is documented in the panel's own repository (`docs/api.md`): HTTP Basic with the
panel's password, UTF-8 library-relative paths exactly as stored. The app uses:

| Screen | Calls |
| --- | --- |
| Upload | `POST /upload/start` (with a `sha256` per file), `PUT /upload/{batch}/{i}?offset=`, `GET /upload/{batch}`, `POST /upload/{batch}/finish`, `GET /api/jobs/{id}`, `DELETE /upload/{batch}` |
| Devices | `GET /api/devices`, `GET /api/devices/{id}/queue`, `POST …/queue/complete`, `DELETE …/queue`, `GET …/issues`, `POST …/fix`, `POST /api/sync-log` |
| Library and play | `GET /api/search`, `GET /api/albums/{id}`, `GET /api/tracks?path=`, `GET /api/tracks/{id}/stream` (AVPlayer, with the login and Range), `GET /cover/{album_id}` |

Files themselves travel by rsync over ssh, as `dap-sync-mac.sh` does; the app sends the names to rsync
on stdin (`--files-from=-`), because Foundation turns accented names in arguments into decomposed
Unicode and the server stores the composed form.

`tests/standin-panel.py` is a stand-in that follows that document, for `selftest.sh`.
