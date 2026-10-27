#!/bin/zsh
# The app against a stand-in panel and a pretend server, never the real ones. A disk image formatted
# exFAT plays the player. The app drives its own upload and copy code; this script then compares the
# files. Pictures and the log land in WORK/out.
#
#   ./selftest.sh [WORK]                  # WORK defaults to a new temporary folder
#   ./selftest.sh WORK --samples FILE     # instead: only decode the panel's recorded answers (docs/api-samples.json
#                                         # in its repository) the way the app does
#   ./selftest.sh WORK --real user@host   # instead: one small album pulled from the real library
#                                         # (read-only there; the panel it reports to is the stand-in)
#
# The window is on screen for about a minute, and a disk called MTTESTDAP shows up and goes away.
set -euo pipefail
cd "${0:A:h}"
WORK=${1:-$(mktemp -d)}; mkdir -p "$WORK"; WORK=${WORK:A}
REAL=""; [[ ${2:-} == --real ]] && REAL=${3:?user@host}
SAMPLES=""; [[ ${2:-} == --samples ]] && SAMPLES=${3:?FILE}
OUT=$WORK/out; rm -rf "$OUT"; mkdir -p "$OUT"
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
fail() { echo "FAIL $*"; FAILED=1; }
ok()   { echo "PASS $*"; }
FAILED=0

MUSIC_OUT=$WORK/app MUSIC_ID=xyz.tiresia.musictoolbox.selftest MUSIC_NAME="Music Toolbox Selftest" ./build.sh >/dev/null
APP="$WORK/app/Music Toolbox Selftest.app/Contents/MacOS/MusicToolbox"

if [[ -n $SAMPLES ]]; then
  MUSIC_OUT=$WORK/app MUSIC_ID=xyz.tiresia.musictoolbox.selftest MUSIC_NAME="Music Toolbox Selftest" ./build.sh >/dev/null
  ( sleep 60; pkill -f "$APP" ) 2>/dev/null & WATCH=$!
  MUSIC_SELFTEST=$OUT MUSIC_TEST_SAMPLES=${SAMPLES:A} "$APP" -ApplePersistenceIgnoreState YES >"$OUT/stdout.txt" 2>"$OUT/stderr.txt" || true
  kill $WATCH 2>/dev/null || true
  grep -E "^(PASS|FAIL|SELFTEST)" "$OUT/log.txt"; grep -q "SELFTEST passed" "$OUT/log.txt"; exit $?
fi

# --- the pretend server: a library, a queue, a log
LIB=$WORK/server/lib; Q=$WORK/server/dap-queue.txt; LOG=$WORK/server/dap-sync-log.jsonl
rm -rf "$WORK/server" "$WORK/up1" "$WORK/up2" "$WORK/panel"; mkdir -p "$LIB" "$WORK/up1" "$WORK/up2" "$WORK/panel"
blob() { mkdir -p "${1:h}"; head -c "$2" /dev/urandom > "$1"; }
blob "$LIB/Artist A/Album One/01 One.flac" 3000000; blob "$LIB/Artist A/Album One/02 Two.flac" 2000000
blob "$LIB/Artist A/Album One/cover.jpg" 50000;     echo "[00:01.00]one" > "$LIB/Artist A/Album One/01 One.lrc"
blob "$LIB/אמן/אלבום א/01 שיר.flac" 1000000
blob "$LIB/Single Artist/Single Album/05 Track.flac" 800000; blob "$LIB/Single Artist/Single Album/06 Other.flac" 700000
echo "server junk" > "$LIB/settings.txt"
printf '%s\n' "Artist A/Album One" "אמן/אלבום א" "Single Artist/Single Album/05 Track.flac" "Gone Artist/Gone Album" > "$Q"
: > "$Q.lock"
# --- uploads: 4 music files the panel takes, and junk it must not
blob "$WORK/up1/Album A/01.flac" 10000000; blob "$WORK/up1/Album A/02.flac" 10000000; blob "$WORK/up1/Album A/cover.jpg" 100000
echo "[00:01.00]x" > "$WORK/up1/Album A/sub/01.lrc" 2>/dev/null || { mkdir -p "$WORK/up1/Album A/sub"; echo "[00:01.00]x" > "$WORK/up1/Album A/sub/01.lrc"; }
echo junk > "$WORK/up1/Album A/._01.flac"; echo junk > "$WORK/up1/Album A/.DS_Store"; echo pdf > "$WORK/up1/Album A/notes.pdf"
for n in 1 2 3; do blob "$WORK/up2/Album B/$n.flac" 20000000; done

# --- the pretend player
DISK=$WORK/dap.sparseimage; rm -f "$DISK" "$WORK/dap.dmg"
hdiutil detach /Volumes/MTTESTDAP -force >/dev/null 2>&1 || true
hdiutil create -size 600m -fs ExFAT -volname MTTESTDAP -type SPARSE "$DISK" >/dev/null
hdiutil attach "$DISK" >/dev/null
VOL=/Volumes/MTTESTDAP
cleanup() { [[ -n ${SERVER_PID:-} ]] && kill $SERVER_PID 2>/dev/null; hdiutil detach "$VOL" -force >/dev/null 2>&1 || true; }
trap cleanup EXIT
printf '# dap-sync target marker\nmarked=2026-10-26 12:00:00\nmusicdir=\nprofile=hifi-walker-h2\n' > "$VOL/.dap-sync-target"
mkdir -p "$VOL/.rockbox" "$VOL/Playlists"; echo "rockbox settings" > "$VOL/.rockbox/config.cfg"; echo "#EXTM3U" > "$VOL/Playlists/x.m3u"; echo "device settings" > "$VOL/settings.txt"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 tests/standin-panel.py $PORT "$WORK/panel" --lib "$LIB" --queue "$Q" --log "$LOG" --drop-after 3000000 --slow 0.4 --needs-look 1 --issues 2 --corrupt-once 2>"$OUT/standin.err" &
SERVER_PID=$!
sleep 1

if [[ -z $REAL ]]; then
  ( sleep 240; pkill -f "$APP" ) 2>/dev/null & WATCH=$!
  MUSIC_SELFTEST=$OUT MUSIC_PANEL_URL=http://127.0.0.1:$PORT MUSIC_PANEL_USER=test MUSIC_PANEL_PASSWORD=test-password \
  MUSIC_SSH=$PWD/tests/fake-ssh MUSIC_SSH_TARGET=test MUSIC_MUSICPATH=$LIB \
  MUSIC_TEST_UPLOAD="$WORK/up1/Album A" MUSIC_TEST_UPLOAD2="$WORK/up2/Album B" MUSIC_TEST_FILES=4 MUSIC_TEST_VOLUME=$VOL MUSIC_TEST_QUEUE=4 MUSIC_TEST_EJECT=1 \
    "$APP" -ApplePersistenceIgnoreState YES >"$OUT/stdout.txt" 2>"$OUT/stderr.txt" || true
  kill $WATCH 2>/dev/null || true
  [[ -f $OUT/crash.txt ]] && { echo "CRASH:"; cat "$OUT/crash.txt"; FAILED=1; }
  grep -E "^(PASS|FAIL|SELFTEST)" "$OUT/log.txt" || true
  grep -q "SELFTEST passed" "$OUT/log.txt" || FAILED=1

  echo "--- the files"
  [[ -d $VOL ]] || { echo "(the app ejected the player; mounting it again to look)"; hdiutil attach "$DISK" >/dev/null 2>&1; }

  INBOX=$WORK/panel/inbox
  diff -r "$WORK/up1/Album A" "$INBOX/Album A/Album A" -x '._*' -x .DS_Store -x notes.pdf >/dev/null && ok "upload 1 arrived byte for byte, junk left out" || fail "upload 1 differs"
  diff -r "$WORK/up2/Album B" "$INBOX/Album B/Album B" >/dev/null && ok "upload 2 (paused and resumed) arrived byte for byte" || fail "upload 2 differs"
  grep -q "dropped the connection" $WORK/panel/log.txt && grep -q "^resumed" $WORK/panel/log.txt && ok "the server saw a dropped connection and a resume" || fail "no drop/resume seen"
  grep -q "bad checksum" $WORK/panel/log.txt && ok "a corrupted file was caught by its checksum and sent again" || fail "no checksum failure seen"
  [[ -z $(ls -A "$WORK/panel/stage") ]] && ok "no staging left behind" || fail "staging left"
  for e in "Artist A/Album One" "אמן/אלבום א" ; do diff -r "$LIB/$e" "$VOL/$e" >/dev/null && ok "on the player, identical: $e" || fail "differs on the player: $e"; done
  cmp -s "$LIB/Single Artist/Single Album/05 Track.flac" "$VOL/Single Artist/Single Album/05 Track.flac" && ok "the single track is on the player" || fail "single track missing"
  [[ $(cat "$VOL/settings.txt") == "device settings" && $(cat "$VOL/.rockbox/config.cfg") == "rockbox settings" && -f "$VOL/Playlists/x.m3u" ]] && ok "the player's own files untouched, through a mirror" || fail "device files changed"
  # macOS 14+ tags every file with com.apple.provenance and exFAT keeps that as a ._ twin; the app
  # clears them after each copy and before eject (the INFO lines show none while it runs), but macOS
  # writes some back when the volume is unmounted. Reported, not failed: the script has the same exposure.
  echo "note: $(find "$VOL" -name '._*' | wc -l | tr -d ' ') ._ twins on the player after eject/exit"
  [[ ! -e "$VOL/Stale Artist" ]] && ok "the mirror removed the stale album" || fail "stale album still there"
  [[ ! -s $Q ]] && ok "the queue ended empty" || fail "queue is: $(cat "$Q")"
  [[ $(wc -l < "${Q%.txt}.done.txt") -eq 4 ]] && ok "all four entries moved to the done list" || fail "done list wrong"
  python3 - "$LOG" <<'PY' && ok "sync log lines are valid JSON the panel can read" || fail "sync log"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
modes = [r["mode"] for r in rows]
assert modes == ["queue", "mirror"], modes
assert all(r["result"] == "finished" and isinstance(r["copied"], int) and isinstance(r["seconds"], int) for r in rows), rows
assert rows[0]["copied"] >= 5, rows[0]
PY
else
  # --- one small album from the real library, onto the pretend player
  SSH=(ssh -o BatchMode=yes $REAL)
  ENTRY=$("${SSH[@]}" 'cd /srv/media/music && find . -mindepth 2 -maxdepth 2 -type d | sed "s|^\./||" | LC_ALL=C grep -P "[^\x00-\x7F]" | head -40 | while IFS= read -r d; do printf "%s\t%s\n" "$(du -sm -- "$d" | cut -f1)" "$d"; done | awk -F"\t" "\$1>0 && \$1<80" | sort -n | head -1 | cut -f2')
  [[ -n $ENTRY ]] || { echo "no small non-ASCII album found"; exit 1; }
  echo "pulling: $ENTRY"
  ( sleep 400; pkill -f "$APP" ) 2>/dev/null & WATCH=$!
  MUSIC_SELFTEST=$OUT MUSIC_SSH_TARGET=$REAL MUSIC_TEST_ENTRY="$ENTRY" MUSIC_TEST_REAL=1 MUSIC_TEST_VOLUME=$VOL \
    MUSIC_PANEL_URL=http://127.0.0.1:$PORT MUSIC_PANEL_USER=test MUSIC_PANEL_PASSWORD=test-password \
    "$APP" -ApplePersistenceIgnoreState YES >"$OUT/stdout.txt" 2>"$OUT/stderr.txt" || true
  kill $WATCH 2>/dev/null || true
  [[ -f $OUT/crash.txt ]] && { echo "CRASH:"; cat "$OUT/crash.txt"; FAILED=1; }
  grep -E "^(PASS|FAIL|SELFTEST)" "$OUT/log.txt" || true
  grep -q "SELFTEST passed" "$OUT/log.txt" || FAILED=1
  DIFF=$(rsync -rn -i --checksum --modify-window=2 -s -e "ssh -o BatchMode=yes" --exclude='._*' "$REAL:/srv/media/music/$ENTRY/" "$VOL/$ENTRY/" | grep -c '^[<>]f' || true)
  [[ $DIFF -eq 0 ]] && ok "the album on the player matches the library by checksum (Hebrew/Unicode names included)" || fail "$DIFF files differ from the library"
  echo "note: $(find "$VOL" -name '._*' | wc -l | tr -d ' ') ._ twins on the player after exit"
  grep -q '"mode": *"queue"' "$LOG" && ok "the copy was reported to the (stand-in) panel's sync log" || fail "no sync log line"
fi
for f in "$OUT"/*.png(N); do echo "picture: $f"; done
[[ $FAILED -eq 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "SOME FAILED"; exit 1; }
