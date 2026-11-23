#!/usr/bin/env bash
# 開發版一次做完：檢查和測試 → 裝到 BlueStacks 和連著的 iPhone → 問要不要 commit、push。
#
# 用法（在 repo 根目錄）：
#   bash tools/deploy_dev.sh            # 全部
#   bash tools/deploy_dev.sh android    # 只裝 BlueStacks
#   bash tools/deploy_dev.sh ios        # 只裝 iPhone
# 指定裝置：ANDROID_DEVICE=<adb devices 的序號>、IOS_DEVICE=<devicectl 的識別碼>
#
# BlueStacks 要先打開，並在 設定 › 進階 打開 Android Debug Bridge。
# iPhone 要解鎖、接線或和 Mac 在同一個網路；第一次要先用 Xcode 執行過一次（登入 Apple ID、選 Team、信任開發者）。
set -euo pipefail
cd "$(dirname "$0")/.."

WHAT=${1:-all}
PKG=io.github.howweichi.juango
project=(ios/*.xcodeproj)
APP="$(basename "${project[0]}" .xcodeproj)"
OUT="$PWD/dist/install"
ADB=$(command -v adb || echo /Applications/BlueStacks.app/Contents/MacOS/hd-adb)
ANDROID=${ANDROID_DEVICE:-emulator-5554}
mkdir -p "$OUT"

echo "== 檢查和測試"
(
  cd app
  # android/ 是產生的；沒有或比 prepare_android.sh 舊就重新產生
  if [ ! -d android ] || [ tool/prepare_android.sh -nt android ]; then
    rm -rf android
    bash tool/prepare_android.sh
  fi
  flutter pub get
  flutter analyze --no-fatal-infos
  flutter test
)

if [ "$WHAT" != ios ]; then
  echo "== Android → BlueStacks"
  (cd app && flutter build apk --release)
  if "$ADB" -s "$ANDROID" get-state >/dev/null 2>&1; then
    "$ADB" -s "$ANDROID" install -r app/build/app/outputs/flutter-apk/app-release.apk || {
      echo "安裝失敗。如果是簽名不同，先解除安裝舊版（App 裡的資料會清掉）：$ADB -s $ANDROID uninstall $PKG" >&2
      exit 1
    }
    "$ADB" -s "$ANDROID" shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    echo "已裝到 $ANDROID 並打開"
  else
    echo "找不到 $ANDROID（BlueStacks 要先打開，並打開 Android Debug Bridge），跳過"
  fi
fi

if [ "$WHAT" != android ]; then
  echo "== iPhone"
  DEVICE=${IOS_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep 'iPhone' | grep 'physical' | grep -v 'unavailable' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)}
  if [ -z "$DEVICE" ]; then
    echo "找不到連著的 iPhone（要解鎖，並和 Mac 在同一個網路或接線），跳過"
  else
    echo "編譯中（第一次比較久）…"
    if ! xcodebuild -project "${project[0]}" -scheme "$APP" -configuration Debug -destination 'generic/platform=iOS' \
      -derivedDataPath "$OUT/ios" -allowProvisioningUpdates build > "$OUT/xcodebuild.log" 2>&1; then
      tail -30 "$OUT/xcodebuild.log" >&2
      echo "編譯失敗，完整紀錄在 $OUT/xcodebuild.log" >&2
      exit 1
    fi
    xcrun devicectl device install app --device "$DEVICE" "$OUT/ios/Build/Products/Debug-iphoneos/$APP.app"
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing $PKG >/dev/null
    echo "已裝到 $DEVICE 並打開"
  fi
fi

echo "== Commit 和 push"
if [ -z "$(git status --porcelain)" ]; then
  echo "沒有要 commit 的修改"
  exit 0
fi
git status --short
read -r -p "Commit 訊息（直接按 Enter 就不 commit）：" MSG
[ -n "$MSG" ] || { echo "沒有 commit"; exit 0; }
BRANCH=$(git branch --show-current)
git add -A
git commit -m "$MSG"
git push origin "$BRANCH" || { echo "push 被拒絕的話，先 git pull --rebase 再跑一次" >&2; exit 1; }
echo "已 push 到 $BRANCH"
