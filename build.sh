#!/bin/zsh
# Builds Music Toolbox.app: the SwiftUI app in Sources/, wrapped into a bundle and signed.
#
#   ./build.sh && open "build/Music Toolbox.app"
#
# MUSIC_ID, MUSIC_NAME and MUSIC_OUT build it under another id, name and folder (selftest.sh's, so
# the test never touches the real app's settings or Keychain item). MUSIC_SIGN picks the signing
# identity ("-" for ad hoc); by default an Apple Development identity from the keychain, else ad hoc.
# MUSIC_VERSION and MUSIC_BUILD set the version numbers (release.sh); MUSIC_KEYCHAIN names the keychain
# the identity is in when it is not one of the searched ones.
set -euo pipefail
cd "${0:A:h}"

ID=${MUSIC_ID:-xyz.tiresia.musictoolbox}
NAME=${MUSIC_NAME:-Music Toolbox}
VERSION=${MUSIC_VERSION:-0.1.0}
BUILD=${MUSIC_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
OUT=${MUSIC_OUT:-build}
APP="$OUT/$NAME.app"

swift build -c release 2>&1 | grep -E "error|warning: unre|Build complete" | tail -5
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MusicToolbox "$APP/Contents/MacOS/MusicToolbox"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Folders and music dropped on the Dock icon open the Upload screen. ATS is relaxed because the
# server may be reached by its Tailscale address over plain http, which WireGuard already encrypts.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleName</key><string>Music Toolbox</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>MusicToolbox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSRemovableVolumesUsageDescription</key><string>Music Toolbox copies music onto your player and keeps its marker file there.</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict><key>CFBundleTypeName</key><string>Folder</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string><key>LSItemContentTypes</key><array><string>public.folder</string></array></dict>
    <dict><key>CFBundleTypeName</key><string>Audio</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string><key>LSItemContentTypes</key><array><string>public.audio</string></array></dict>
  </array>
</dict></plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

cat > "$OUT/MusicToolbox.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><false/>
</dict></plist>
ENT

# an Apple Development identity if the keychain has one, ad hoc otherwise; none is written into
# this repository
IDENTITY=${MUSIC_SIGN:-$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]*\) "Apple Development.*/\1/p' | head -1)}
codesign --force --options runtime --entitlements "$OUT/MusicToolbox.entitlements" --sign "${IDENTITY:--}" ${MUSIC_KEYCHAIN:+--keychain "$MUSIC_KEYCHAIN"} "$APP"
[[ -n $IDENTITY ]] || echo "note: signed ad hoc; the Keychain asks again after each build"
echo "built $APP"
