#!/bin/zsh
# Cuts a release: the app built and signed on this Mac, zipped, a GitHub Release with the zip, and
# the Homebrew cask in the tap pointed at it.
#
#   ./release.sh 0.1.0 "What's new, in a line"
#   ./release.sh 0.1.0 --dry-run          build and check only; nothing is published
#
# Signed with the shared identity the other apps use, which lives in its own keychain. What this
# script needs to know about it is in ~/.config/music-toolbox-release.env, outside the repository:
#   SIGN_NAME=...            the identity's name
#   SIGN_KEYCHAIN=...        the keychain file that holds it
#   SIGN_PASSWORD_FILE=...   the file that unlocks that keychain
#   TAP=git@github.com:owner/homebrew-tap.git
# The keychain is locked again afterwards. Version numbers come from X.Y.Z: the build is
# 10000*X + 100*Y + Z, so each release outranks the last.
set -euo pipefail
cd "${0:A:h}"

V=${1:?usage: ./release.sh X.Y.Z "notes" | --dry-run}
[[ $V =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "a version is X.Y.Z" >&2; exit 2; }
BUILD=$(( match[1] * 10000 + match[2] * 100 + match[3] ))
DRY=0; NOTES="Music Toolbox $V"
[[ ${2:-} == --dry-run ]] && DRY=1 || { [[ -n ${2:-} ]] && NOTES=$2; }
CONF=${MUSIC_RELEASE_ENV:-$HOME/.config/music-toolbox-release.env}
[[ -f $CONF ]] || { echo "no $CONF (see the top of this script)" >&2; exit 2; }
source "$CONF"
: ${SIGN_NAME:?} ${SIGN_KEYCHAIN:?} ${SIGN_PASSWORD_FILE:?} ${TAP:?}
SIGN_KEYCHAIN=${SIGN_KEYCHAIN/#\~/$HOME}; SIGN_PASSWORD_FILE=${SIGN_PASSWORD_FILE/#\~/$HOME}
REPO=franz-rosenzweig/music-toolbox
say() { echo "release: $*"; }
fail() { echo "CHECK FAILED: $*" >&2; exit 1; }

# what ships is what is on origin/main
git fetch -q origin
[[ -z $(git status --porcelain) ]] || { echo "the tree isn't clean" >&2; exit 1; }
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "HEAD isn't origin/main" >&2; exit 1; }
if [[ $DRY == 0 ]]; then gh release view "v$V" --repo $REPO >/dev/null 2>&1 && { echo "v$V is already released" >&2; exit 1; }; fi
SHA=$(git rev-parse HEAD)
say "v$V (build $BUILD) from $(git log --oneline -1)"

# --- build, signed with the shared identity
HASH=$(security find-identity -p codesigning "$SIGN_KEYCHAIN" | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"$SIGN_NAME\".*/\1/p" | head -1)
[[ -n $HASH ]] || { echo "no identity named $SIGN_NAME in the keychain" >&2; exit 1; }
trap 'security lock-keychain "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true' EXIT
security unlock-keychain -p "$(cat "$SIGN_PASSWORD_FILE")" "$SIGN_KEYCHAIN"
OUT=build/release; rm -rf $OUT
MUSIC_OUT=$OUT MUSIC_VERSION=$V MUSIC_BUILD=$BUILD MUSIC_SIGN=$HASH MUSIC_KEYCHAIN=$SIGN_KEYCHAIN ./build.sh
APP="$OUT/Music Toolbox.app"
security lock-keychain "$SIGN_KEYCHAIN"

# --- what the app says about itself, before anything leaves the Mac
say "checking"
codesign --verify --deep --strict "$APP" || fail "the signature"
sig=$(codesign -dvv "$APP" 2>&1)
auth=$(sed -n 's/^Authority=//p' <<<"$sig" | sort -u)
[[ $auth == "$SIGN_NAME" ]] || fail "signed by '$auth', not only by $SIGN_NAME"
[[ $sig == *$'\n'"TeamIdentifier=not set"* ]] || fail "the app carries a team"
plist="$APP/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") == $V ]] || fail "the version"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist") == $BUILD ]] || fail "the build number"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist") == xyz.tiresia.musictoolbox ]] || fail "the id"
[[ -z $(grep -r -l -a '/Users/' "$APP" || true) ]] || fail "a home folder's path is in the app: $(grep -r -l -a '/Users/' "$APP")"
[[ -z $(grep -r -l -a -E '[0-9]{2,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]{2,5}|tiresia\.xyz/|@pm\.me' "$APP" || true) ]] || fail "a server address or an email is in the app"

ZIP="$OUT/MusicToolbox-$V-mac.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
SUM=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
say "$(du -h "$ZIP" | cut -f1) zip, sha256 $SUM"
if [[ $DRY == 1 ]]; then say "dry run: nothing published"; exit 0; fi

# --- the release, then the cask
gh release create "v$V" "$ZIP" --repo $REPO --target "$SHA" --title "Music Toolbox $V" --notes "$NOTES"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"; security lock-keychain "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true' EXIT
git clone -q "$TAP" "$WORK/tap"
mkdir -p "$WORK/tap/Casks"
cat > "$WORK/tap/Casks/music-toolbox.rb" <<CASK
cask "music-toolbox" do
  version "$V"
  sha256 "$SUM"

  url "https://github.com/$REPO/releases/download/v#{version}/MusicToolbox-#{version}-mac.zip"
  name "Music Toolbox"
  desc "Uploads music to a self-hosted library and loads it onto players"
  homepage "https://github.com/$REPO"

  depends_on macos: ">= :tahoe"
  depends_on formula: "rsync"

  app "Music Toolbox.app"

  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Music Toolbox.app"]
  end
end
CASK
if ! grep -q 'music-toolbox' "$WORK/tap/README.md"; then
  echo "| [music-toolbox](Casks/music-toolbox.rb) | [Music Toolbox](https://github.com/$REPO): uploads music to a self-hosted library and loads it onto players |" >> "$WORK/tap/README.md"
fi
git -C "$WORK/tap" add Casks/music-toolbox.rb README.md
git -C "$WORK/tap" commit -q -m "music-toolbox $V"
git -C "$WORK/tap" pull -q --rebase
git -C "$WORK/tap" push -q
say "released: $(gh release view "v$V" --repo $REPO --json url -q .url), and the cask is at $V"
