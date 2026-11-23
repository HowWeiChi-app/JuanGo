#!/usr/bin/env bash
# 編譯要發布的 iPhone 和 Android 版，放到 dist/release/。
# iPhone 版沒有簽名，安裝時用 Sideloadly 或 AltStore 以自己的 Apple ID 簽。
#
# 用法：在 repo 根目錄執行  bash tools/build_release.sh "這版改了什麼（App 內更新提醒會顯示）"
# 最後會重寫 release/latest.json：已經安裝的 App 讀它檢查有沒有新版。
# 它要跟著 commit 推上 main，而且要等 GitHub Release 的安裝檔換好再推，App 才不會抓到舊檔。

set -euo pipefail
cd "$(dirname "$0")/.."

project=(ios/*.xcodeproj)
APP="$(basename "${project[0]}" .xcodeproj)"
VERSION="$(sed -n 's/^version: \([^+]*\).*/\1/p' app/pubspec.yaml)"
IOS_VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "${project[0]}/project.pbxproj" | head -1)"
if [ "$VERSION" != "$IOS_VERSION" ]; then
  echo "版本不一致：Android $VERSION，iPhone $IOS_VERSION" >&2
  exit 1
fi

OUT="$PWD/dist/release"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$OUT"
mkdir -p "$OUT"

echo "== Android $VERSION"
(
  cd app
  # android/ 是產生的檔案；舊的留著會沿用過去的套件 ID 和名稱
  rm -rf android
  bash tool/prepare_android.sh
  flutter pub get
  flutter analyze --no-fatal-infos
  flutter test
  flutter build apk --release
)
cp app/build/app/outputs/flutter-apk/app-release.apk "$OUT/$APP-$VERSION.apk"

echo "== iPhone $VERSION"
if ! xcodebuild -project "${project[0]}" -target "$APP" -configuration Release -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$WORK/products" OBJROOT="$WORK/objects" build > "$WORK/xcodebuild.log" 2>&1; then
  tail -30 "$WORK/xcodebuild.log" >&2
  exit 1
fi
mkdir "$WORK/Payload"
cp -R "$WORK/products/Release-iphoneos/$APP.app" "$WORK/Payload/"
(cd "$WORK" && zip -qry "$OUT/$APP-$VERSION.ipa" Payload)

BUILD="$(sed -n 's/^version: [^+]*+\(.*\)/\1/p' app/pubspec.yaml)"
python3 tools/write_latest.py "$VERSION" "$BUILD" "${1:-}"

echo "== 完成"
(cd "$OUT" && shasum -a 256 ./*)
