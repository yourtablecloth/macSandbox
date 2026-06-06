#!/bin/bash
# MacSandbox를 배포용 .app + .dmg로 패키징한다.
#
#   ad-hoc(로컬 테스트):  scripts/package_app.sh
#   배포(서명+공증):       DEVELOPER_ID="Developer ID Application: NAME (TEAMID)" \
#                          NOTARY_PROFILE="<notarytool 키체인 프로파일>" \
#                          scripts/package_app.sh
#
# 전제: macOS, Xcode CLT, brew(wimlib/freerdp 설치됨), vendor/qemu 준비(scripts/build.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="MacSandbox"
BUNDLE_ID="${BUNDLE_ID:-com.rkttu.macsandbox}"
VERSION="${VERSION:-1.0.0}"
IDENTITY="${DEVELOPER_ID:--}"            # 기본 ad-hoc("-")
DIST="dist"; APP="$DIST/$APP_NAME.app"; C="$APP/Contents"
ENT_APP="scripts/app.entitlements"     # disable-library-validation
ENT_QEMU="scripts/qemu.entitlements"   # hypervisor + disable-library-validation

sign() { codesign --force --timestamp --options runtime -s "$IDENTITY" "$@"; }

echo "▶ 1/8 릴리스 빌드"
swift build -c release
BIN=".build/release/$APP_NAME"

echo "▶ 2/8 .app 골격 생성"
rm -rf "$APP"; mkdir -p "$C/MacOS" "$C/Resources" "$C/Frameworks"
cp "$BIN" "$C/MacOS/$APP_NAME"

echo "▶ 3/8 Info.plist"
cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSMicrophoneUsageDescription</key><string>샌드박스에 마이크를 공유하기 위해 사용됩니다.</string>
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
python3 scripts/bundle_dylibs.py "$C/MacOS/$APP_NAME" "$C/Frameworks" --add-rpath @executable_path/../Frameworks

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
sign --entitlements "$ENT_APP" "$C/MacOS/$APP_NAME"
sign --entitlements "$ENT_APP" "$APP"
codesign --verify --strict --verbose=1 "$APP" && echo "  서명 검증 OK"

echo "▶ 8/8 DMG 생성"
STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
[ "$IDENTITY" != "-" ] && codesign --force --timestamp -s "$IDENTITY" "$DMG"

echo ""
echo "✅ 완료:"
echo "   앱: $APP"
echo "   DMG: $DMG  ($(du -h "$DMG" | cut -f1))"
if [ "$IDENTITY" = "-" ]; then
  echo ""
  echo "ℹ️ ad-hoc 서명입니다(로컬 실행용). 배포하려면:"
  echo "   1) Apple Developer 가입 → 'Developer ID Application' 인증서 발급"
  echo "   2) DEVELOPER_ID=\"Developer ID Application: NAME (TEAMID)\" scripts/package_app.sh"
  echo "   3) 공증(notarize):"
  echo "      xcrun notarytool store-credentials <프로파일> --apple-id <id> --team-id <TEAMID> --password <앱암호>"
  echo "      xcrun notarytool submit \"$DMG\" --keychain-profile <프로파일> --wait"
  echo "      xcrun stapler staple \"$DMG\"  (그리고 .app에도 staple 후 DMG 재생성 권장)"
fi
