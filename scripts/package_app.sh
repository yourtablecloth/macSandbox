#!/bin/bash
# macSandbox for Windows를 배포용 .app + .dmg로 패키징한다.
#
#   ad-hoc(로컬/CI 기본):  scripts/package_app.sh
#                          → DEVELOPER_ID 미지정 시 ad-hoc("-") 서명, 공증 생략.
#
#   배포(서명):            DEVELOPER_ID="Developer ID Application: NAME (TEAMID)" \
#                          scripts/package_app.sh
#
#   배포(서명+공증):       위에 더해 아래 중 한 방식의 공증 자격증명을 지정하면
#                          DMG를 자동으로 공증(notarize) + 스테이플(staple)한다.
#     A) 로컬(키체인 프로파일):  NOTARY_PROFILE="<notarytool store-credentials 프로파일>"
#     B) CI(앱 전용 암호):       NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#
# 즉 서명/공증은 "환경 변수만 추가하면" 켜진다(코드 변경 불필요).
#
# 전제: macOS, Xcode CLT, brew(wimlib/freerdp 설치됨), vendor/qemu 준비(scripts/bundle_qemu.py).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="macSandbox for Windows"        # 제품/번들 표시 이름 (.app, DMG 볼륨)
EXEC_NAME="MacSandbox"                   # SwiftPM 실행 파일 이름 (내부 고정)
BUNDLE_ID="${BUNDLE_ID:-com.rkttu.macsandbox}"
VERSION="${VERSION:-1.0.0}"
IDENTITY="${DEVELOPER_ID:--}"            # 기본 ad-hoc("-")
DIST="dist"; APP="$DIST/$APP_NAME.app"; C="$APP/Contents"
ENT_APP="scripts/app.entitlements"     # disable-library-validation
ENT_QEMU="scripts/qemu.entitlements"   # hypervisor + disable-library-validation

sign() { codesign --force --timestamp --options runtime -s "$IDENTITY" "$@"; }

echo "▶ 1/8 릴리스 빌드"
swift build -c release
BIN=".build/release/$EXEC_NAME"

echo "▶ 2/8 .app 골격 생성"
rm -rf "$APP"; mkdir -p "$C/MacOS" "$C/Resources" "$C/Frameworks"
cp "$BIN" "$C/MacOS/$EXEC_NAME"
# SwiftPM 리소스 번들(로컬라이제이션 .lproj)을 Contents/Resources에 넣는다.
# L10nStore가 Bundle.main.resourceURL(= Contents/Resources)에서 직접 찾으므로 위치가 중요.
# 누락되면 UI가 키 문자열로 표시되거나(폴백) 빈약해지므로 없으면 빌드를 실패시킨다.
RES_BUNDLE=".build/release/${EXEC_NAME}_${EXEC_NAME}.bundle"
if [ ! -d "$RES_BUNDLE" ]; then
  echo "  ❌ 리소스 번들 없음: $RES_BUNDLE (로컬라이제이션 .lproj). swift build -c release 산출물 확인" >&2
  exit 1
fi
cp -R "$RES_BUNDLE" "$C/Resources/"

# 앱 아이콘 — assets/AppIcon.png(1024²)에서 .icns 생성(재생성: swift scripts/make_assets.swift)
ICON_SRC="assets/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"           "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null 2>&1
    sips -z "$((s*2))" "$((s*2))" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns" && echo "  아이콘: AppIcon.icns 생성"
  rm -rf "$(dirname "$ICONSET")"
else
  echo "  ⚠️ $ICON_SRC 없음 — 아이콘 생략(generic). 'swift scripts/make_assets.swift'로 생성"
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

echo "▶ 4/8 QEMU 번들(x86 에뮬레이터 제거 슬림화) + wimlib"
mkdir -p "$C/Resources/vendor"
cp -R vendor/qemu "$C/Resources/vendor/qemu"
rm -f "$C/Resources/vendor/qemu/bin/qemu-system-x86_64"   # Apple Silicon에선 불필요
# wimlib-imagex(베이스라인 빌드용)를 vendor/qemu/bin에 동봉 → SandboxPaths가 자동 탐색
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
  echo "  ⚠️ wimlib-imagex 없음 — 베이스라인 빌드 기능엔 'brew install wimlib' 필요"
fi

echo "▶ 5/8 FreeRDP dylib 번들 + @rpath 수정"
python3 scripts/bundle_dylibs.py "$C/MacOS/$EXEC_NAME" "$C/Frameworks" --add-rpath @executable_path/../Frameworks

echo "▶ 6/8 라이선스/고지 동봉(GPL 컴플라이언스)"
for f in LICENSE THIRD-PARTY-NOTICES.md WRITTEN-OFFER.txt LICENSING.md; do
  [ -f "$f" ] && cp "$f" "$C/Resources/"
done
[ -d gpl-sources ] && cp -R gpl-sources "$C/Resources/gpl-sources" || \
  echo "  ℹ️ gpl-sources 없음 — 배포 전 'python3 scripts/fetch_gpl_sources.py' 권장(또는 WRITTEN-OFFER로 갈음)"

echo "▶ 7/8 코드 서명 (identity: $IDENTITY)"
# (1) 모든 dylib(Frameworks + vendor/qemu/lib)
find "$APP" -name '*.dylib' -exec codesign --force --timestamp --options runtime -s "$IDENTITY" {} +
# (2) QEMU 시스템 에뮬레이터 — hypervisor + 라이브러리검증 비활성(번들 dylib 로드)
sign --entitlements "$ENT_QEMU" "$C/Resources/vendor/qemu/bin/qemu-system-aarch64"
# (3) 나머지 vendor/qemu/bin 실행파일 — Hardened Runtime은 lib validation을 켜므로,
#     ad-hoc/혼합 서명된 번들 dylib(libzstd 등)를 로드하려면 disable-library-validation 필수.
find "$C/Resources/vendor/qemu/bin" -type f -perm -111 ! -name 'qemu-system-aarch64' \
  -exec codesign --force --timestamp --options runtime --entitlements "$ENT_APP" -s "$IDENTITY" {} + 2>/dev/null || true
# (5) 메인 실행파일 → 앱 번들(마지막)
sign --entitlements "$ENT_APP" "$C/MacOS/$EXEC_NAME"
sign --entitlements "$ENT_APP" "$APP"
codesign --verify --strict --verbose=1 "$APP" && echo "  서명 검증 OK"

echo "▶ 8/8 DMG 생성 (배경/배치 스타일링)"
DMG="$DIST/macSandbox-for-Windows-$VERSION.dmg"
VOLNAME="$APP_NAME"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
BG_SRC="assets/dmg-background.png"
[ -f "$BG_SRC" ] && { mkdir -p "$STAGE/.background"; cp "$BG_SRC" "$STAGE/.background/background.png"; }

# 읽기/쓰기 DMG로 만들어 Finder로 꾸민 뒤(배경·아이콘 위치) 압축 포맷으로 변환한다.
RW="$DIST/.rw-$VERSION.dmg"; rm -f "$RW"
hdiutil detach "/Volumes/$VOLNAME" >/dev/null 2>&1 || true
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
rm -rf "$STAGE"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -oE '^/dev/disk[0-9]+' | head -1)"
sleep 1

style_dmg() {   # Finder 자동화(헤드리스/권한 미허용 시 실패 가능) — 타임아웃으로 보호
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
  if wait "$SP" 2>/dev/null; then STYLED=1; echo "  스타일링 적용됨"; else echo "  ⚠️ Finder 자동화 불가 — 기본 레이아웃으로 진행"; fi
  kill "$WP" 2>/dev/null || true
fi
sync
hdiutil detach "$DEV" >/dev/null 2>&1 || { sleep 2; hdiutil detach -force "$DEV" >/dev/null 2>&1 || true; }

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
[ "$IDENTITY" != "-" ] && codesign --force --timestamp -s "$IDENTITY" "$DMG"

# ── 공증(notarization) — 자격증명이 주어졌을 때만 자동 수행 ─────────────────
# Developer ID로 서명됐고(ad-hoc 아님) NOTARY_* 자격증명이 있으면 DMG를 공증 + 스테이플.
# 미지정 시 조용히 건너뛴다(ad-hoc/미공증 DMG는 그대로 산출됨).
NOTARIZED=0
if [ "$IDENTITY" != "-" ]; then
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "▶ 공증 (notarytool · keychain-profile)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"; NOTARIZED=1
  elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    echo "▶ 공증 (notarytool · apple-id)"
    xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG"; NOTARIZED=1
  fi
fi

echo ""
echo "✅ 완료:"
echo "   앱: $APP"
echo "   DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
if [ "$IDENTITY" = "-" ]; then
  echo "   서명: ad-hoc (로컬/테스트용 — 배포하려면 DEVELOPER_ID 지정)"
elif [ "$NOTARIZED" = "1" ]; then
  echo "   서명: $IDENTITY"
  echo "   공증: 완료 + 스테이플됨 (Gatekeeper 통과, 배포 가능)"
else
  echo "   서명: $IDENTITY"
  echo "   공증: 생략 (NOTARY_PROFILE 또는 NOTARY_APPLE_ID/TEAM_ID/PASSWORD 지정 시 자동 공증)"
fi
