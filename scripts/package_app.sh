#!/bin/bash
# Package macSandbox for Windows into a distributable .app + .dmg.
#
#   ad-hoc (local/CI default):  scripts/package_app.sh
#                          → when DEVELOPER_ID is unset, signs ad-hoc ("-") and skips notarization.
#
#   distribution (signed):     DEVELOPER_ID="Developer ID Application: NAME (TEAMID)" \
#                          scripts/package_app.sh
#
#   distribution (signed+notarized):  in addition to the above, specifying notarization credentials in one of the ways below
#                          will automatically notarize + staple the DMG.
#     A) local (keychain profile):  NOTARY_PROFILE="<notarytool store-credentials profile>"
#     B) CI (app-specific password):  NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#
# In other words, signing/notarization turns on "just by adding environment variables" (no code changes needed).
#
# Prerequisites: macOS, Xcode CLT, brew (wimlib/freerdp installed), vendor/qemu prepared (scripts/bundle_qemu.py).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="macSandbox for Windows"        # Product/bundle display name (.app, DMG volume)
EXEC_NAME="MacSandbox"                   # SwiftPM executable name (fixed internally)
BUNDLE_ID="${BUNDLE_ID:-com.rkttu.macsandbox}"
VERSION="${VERSION:-1.0.0}"
IDENTITY="${DEVELOPER_ID:--}"            # default ad-hoc ("-")
DIST="dist"; APP="$DIST/$APP_NAME.app"; C="$APP/Contents"
ENT_APP="scripts/app.entitlements"     # disable-library-validation
ENT_QEMU="scripts/qemu.entitlements"   # hypervisor + disable-library-validation

sign() { codesign --force --timestamp --options runtime -s "$IDENTITY" "$@"; }

echo "▶ 1/8 Release build"
swift build -c release
BIN=".build/release/$EXEC_NAME"

echo "▶ 2/8 Create .app skeleton"
rm -rf "$APP"; mkdir -p "$C/MacOS" "$C/Resources" "$C/Frameworks"
cp "$BIN" "$C/MacOS/$EXEC_NAME"
# Put the SwiftPM resource bundle (localization .lproj) into Contents/Resources.
# L10nStore looks it up directly from Bundle.main.resourceURL (= Contents/Resources), so its location matters.
# If missing, the UI shows key strings (fallback) or degrades, so fail the build when it's absent.
RES_BUNDLE=".build/release/${EXEC_NAME}_${EXEC_NAME}.bundle"
if [ ! -d "$RES_BUNDLE" ]; then
  echo "  ❌ Resource bundle missing: $RES_BUNDLE (localization .lproj). Check the swift build -c release output" >&2
  exit 1
fi
cp -R "$RES_BUNDLE" "$C/Resources/"

# App icon — generate .icns from assets/AppIcon.png (1024²) (regenerate: swift scripts/make_assets.swift)
ICON_SRC="assets/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"           "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null 2>&1
    sips -z "$((s*2))" "$((s*2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns" && echo "  icon: AppIcon.icns generated"
  rm -rf "$(dirname "$ICONSET")"
else
  echo "  ⚠️ $ICON_SRC missing — skipping icon (generic). Generate with 'swift scripts/make_assets.swift'"
fi

echo "▶ 3/8 Info.plist"
cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>macSandbox</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>
    <string>en</string><string>ko</string><string>ja</string>
    <string>de</string><string>es</string><string>fr</string>
  </array>
  <key>NSMicrophoneUsageDescription</key><string>Used to share the microphone with the sandbox.</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict>
      <key>CFBundleTypeName</key><string>Windows Sandbox Configuration</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>$BUNDLE_ID.wsb</string></array>
      <key>CFBundleTypeExtensions</key><array><string>wsb</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key><array>
    <dict>
      <key>UTTypeIdentifier</key><string>$BUNDLE_ID.wsb</string>
      <key>UTTypeDescription</key><string>Windows Sandbox Configuration</string>
      <key>UTTypeConformsTo</key><array><string>public.xml</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>wsb</string></array>
      </dict>
    </dict>
  </array>
</dict></plist>
PLIST

echo "▶ 4/8 QEMU bundle (slimmed by removing the x86 emulator) + wimlib"
mkdir -p "$C/Resources/vendor"
cp -R vendor/qemu "$C/Resources/vendor/qemu"
rm -f "$C/Resources/vendor/qemu/bin/qemu-system-x86_64"   # not needed on Apple Silicon
# Bundle wimlib-imagex (for baseline builds) into vendor/qemu/bin → SandboxPaths discovers it automatically
WIMX="$(command -v wimlib-imagex || echo /opt/homebrew/bin/wimlib-imagex)"
if [ -x "$WIMX" ]; then
  cp "$WIMX" "$C/Resources/vendor/qemu/bin/wimlib-imagex"
  LIBWIM="$(otool -L "$WIMX" | awk '/libwim/{print $1; exit}')"
  if [ -n "$LIBWIM" ]; then
    cp "$(/usr/bin/python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$LIBWIM")" \
       "$C/Resources/vendor/qemu/lib/$(basename "$LIBWIM")"
    install_name_tool -change "$LIBWIM" "@loader_path/../lib/$(basename "$LIBWIM")" \
       "$C/Resources/vendor/qemu/bin/wimlib-imagex"
  fi
else
  echo "  ⚠️ wimlib-imagex missing — the baseline build feature requires 'brew install wimlib'"
fi

echo "▶ 5/8 Bundle FreeRDP dylibs + fix @rpath"
python3 scripts/bundle_dylibs.py "$C/MacOS/$EXEC_NAME" "$C/Frameworks" --add-rpath @executable_path/../Frameworks

echo "▶ 6/8 Bundle licenses/notices (GPL compliance)"
for f in LICENSE THIRD-PARTY-NOTICES.md WRITTEN-OFFER.txt LICENSING.md; do
  [ -f "$f" ] && cp "$f" "$C/Resources/"
done
[ -d gpl-sources ] && cp -R gpl-sources "$C/Resources/gpl-sources" || \
  echo "  ℹ️ gpl-sources missing — 'python3 scripts/fetch_gpl_sources.py' is recommended before distribution (or substitute with WRITTEN-OFFER)"

echo "▶ 7/8 Code-signing (identity: $IDENTITY)"
# (1) All dylibs (Frameworks + vendor/qemu/lib)
find "$APP" -name '*.dylib' -exec codesign --force --timestamp --options runtime -s "$IDENTITY" {} +
# (2) QEMU system emulator — hypervisor + library validation disabled (loads bundled dylibs)
sign --entitlements "$ENT_QEMU" "$C/Resources/vendor/qemu/bin/qemu-system-aarch64"
# (3) The remaining vendor/qemu/bin executables — Hardened Runtime turns on lib validation, so
#     disable-library-validation is required to load ad-hoc/mixed-signed bundled dylibs (libzstd, etc.).
find "$C/Resources/vendor/qemu/bin" -type f -perm -111 ! -name 'qemu-system-aarch64' \
  -exec codesign --force --timestamp --options runtime --entitlements "$ENT_APP" -s "$IDENTITY" {} + 2>/dev/null || true
# (5) Main executable → app bundle (last)
sign --entitlements "$ENT_APP" "$C/MacOS/$EXEC_NAME"
sign --entitlements "$ENT_APP" "$APP"
codesign --verify --strict --verbose=1 "$APP" && echo "  signature verification OK"

echo "▶ 8/8 Create DMG (background/layout styling)"
DMG="$DIST/macSandbox-for-Windows-$VERSION.dmg"
VOLNAME="$APP_NAME"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
BG_SRC="assets/dmg-background.png"
[ -f "$BG_SRC" ] && { mkdir -p "$STAGE/.background"; cp "$BG_SRC" "$STAGE/.background/background.png"; }

# Create a read/write DMG, decorate it with Finder (background, icon positions), then convert to a compressed format.
RW="$DIST/.rw-$VERSION.dmg"; rm -f "$RW"
hdiutil detach "/Volumes/$VOLNAME" >/dev/null 2>&1 || true
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
rm -rf "$STAGE"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -oE '^/dev/disk[0-9]+' | head -1)"
sleep 1

style_dmg() {   # Finder automation (may fail when headless / permission not granted) — protected with a timeout
  osascript <<OSA
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 160, 960, 588}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 112
    set text size of vopts to 12
    set background picture of vopts to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {172, 218}
    set position of item "Applications" of container window to {488, 218}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
}
STYLED=0
if [ -f "$BG_SRC" ]; then
  ( style_dmg >/dev/null 2>&1 ) & SP=$!
  ( sleep 40; kill "$SP" 2>/dev/null ) & WP=$!
  if wait "$SP" 2>/dev/null; then STYLED=1; echo "  styling applied"; else echo "  ⚠️ Finder automation unavailable — proceeding with the default layout"; fi
  kill "$WP" 2>/dev/null || true
fi
sync
hdiutil detach "$DEV" >/dev/null 2>&1 || { sleep 2; hdiutil detach -force "$DEV" >/dev/null 2>&1 || true; }

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
[ "$IDENTITY" != "-" ] && codesign --force --timestamp -s "$IDENTITY" "$DMG"

# ── Notarization — performed automatically only when credentials are provided ─────────────────
# If signed with a Developer ID (not ad-hoc) and NOTARY_* credentials are present, notarize + staple the DMG.
# If unset, silently skip (the ad-hoc/unnotarized DMG is produced as-is).
NOTARIZED=0
if [ "$IDENTITY" != "-" ]; then
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▶ Notarization (notarytool · keychain-profile)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"; NOTARIZED=1
  elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    echo "▶ Notarization (notarytool · apple-id)"
    xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG"; NOTARIZED=1
  fi
fi

echo ""
echo "✅ Done:"
echo "   App: $APP"
echo "   DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
if [ "$IDENTITY" = "-" ]; then
  echo "   Signing: ad-hoc (for local/testing — specify DEVELOPER_ID to distribute)"
elif [ "$NOTARIZED" = "1" ]; then
  echo "   Signing: $IDENTITY"
  echo "   Notarization: complete + stapled (passes Gatekeeper, ready to distribute)"
else
  echo "   Signing: $IDENTITY"
  echo "   Notarization: skipped (auto-notarizes when NOTARY_PROFILE or NOTARY_APPLE_ID/TEAM_ID/PASSWORD is set)"
fi
