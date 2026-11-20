#!/usr/bin/env bash
# 產生官網用的實機截圖，輸出到 dist/screenshots/（不進版控）。
# 用獨立的 .demo 版本截圖，資料和平常使用的捲字完全分開。
#
# 用法：在 repo 根目錄執行
#   bash tools/capture_screens.sh           # iPhone 和 Android
#   bash tools/capture_screens.sh iphone
#   bash tools/capture_screens.sh android
#   bash tools/capture_screens.sh themes    # iPhone 的 56 種外觀
#
# iPhone 要接上並解鎖。可用 IPHONE_DEVICE 指定裝置。Android 預設用 ANDROID_SERIAL=127.0.0.1:5555。

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-all}"
BUNDLE=io.github.howweichi.juango.demo
OUT="$PWD/dist/screenshots"
IPHONE_WORDS=(vehicle striking prevent wildlife journey)
ANDROID_WORD=vehicle
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
export ANDROID_SERIAL="${ANDROID_SERIAL:-127.0.0.1:5555}"

check_size() {  # 檔案 寬 高
  local w h
  w=$(sips -g pixelWidth "$1" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$1" | awk '/pixelHeight/{print $2}')
  if [ "$w" != "$2" ] || [ "$h" != "$3" ]; then
    echo "$1 是 ${w}x${h}，應該是 $2x$3" >&2
    exit 1
  fi
}

find_iphone() {  # 印出 identifier 和 UDID
  local json
  json="$(mktemp)"
  xcrun devicectl list devices --quiet --json-output "$json" >/dev/null
  python3 - "$json" "${IPHONE_DEVICE:-}" <<'PY'
import json, sys
wanted = sys.argv[2]
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, cp = d["hardwareProperties"], d["connectionProperties"]
    if hw.get("reality") != "physical" or hw.get("platform") != "iOS" or hw.get("deviceType") != "iPhone":
        continue
    if wanted and wanted not in (d["identifier"], hw.get("udid")):
        continue
    if cp.get("tunnelState") == "unavailable":
        continue
    # 只用和 iPhone 18 Pro 同解析度的機型：16 Pro、17 Pro、18 Pro
    if hw.get("productType") in ("iPhone17,1", "iPhone18,1", "iPhone19,1"):
        print(d["identifier"], hw["udid"])
        break
PY
  rm -f "$json"
}

capture_iphone() {
  local found udid app  # id 不設 local：結束時移除展示版還要用
  found="$(find_iphone)"
  if [ -z "$found" ]; then
    echo "找不到可用的 iPhone 16 Pro／17 Pro／18 Pro，請接上並解鎖" >&2
    exit 1
  fi
  read -r id udid <<<"$found"

  echo "== 編譯 iPhone 展示版"
  xcodebuild -project ios/JuanGo.xcodeproj -scheme JuanGo -configuration Debug \
    -destination "id=$udid" -derivedDataPath ios/build/demo -allowProvisioningUpdates \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE" -quiet build
  app=ios/build/demo/Build/Products/Debug-iphoneos/JuanGo.app
  # 免費開發者帳號一支手機最多 3 個 App，所以展示版截完就移除
  trap 'xcrun devicectl device uninstall app --device "$id" "$BUNDLE" --quiet || true' EXIT
  xcrun devicectl device install app --device "$id" "$app" --quiet

  if [ "${1:-}" = themes ]; then capture_themes "$id"; return; fi

  mkdir -p "$OUT/iphone"
  for word in "${IPHONE_WORDS[@]}"; do
    echo "== iPhone 探索：$word"
    xcrun devicectl device process launch --device "$id" --terminate-existing --quiet \
      --environment-variables "{\"JUANGO_TAB\":\"explore\",\"JUANGO_EXPLORE_FIRST\":\"$word\"}" \
      -- "$BUNDLE" -onboarded YES -exploreTipsDone YES -muted YES -appearance 1 -themeID phoenix
    sleep 6
    xcrun devicectl device capture screenshot --device "$id" --quiet \
      --destination "$OUT/iphone/explore-$word.png"
    check_size "$OUT/iphone/explore-$word.png" 1206 2622
  done
}

launch_theme() {  # 裝置 顏色 背景（1 淺色、2 深色） 字體
  xcrun devicectl device process launch --device "$1" --terminate-existing --quiet \
    --environment-variables '{"JUANGO_TAB":"explore","JUANGO_EXPLORE_FIRST":"vehicle"}' \
    -- "$BUNDLE" -onboarded YES -exploreTipsDone YES -muted YES -appearance "$3" -themeID "$2" -fontStyle "$4"
}

capture_themes() {  # 官網「外觀」用：7 種顏色 x 淺色深色 x 4 種字體，共 56 張；已經有的會跳過
  local id="$1" theme mode font file
  mkdir -p "$OUT/themes"
  # 圓體和宋體是 iOS 隨選下載的系統字型，先各開一次讓手機下載好
  for font in 1 2; do
    launch_theme "$id" "phoenix" 1 "$font"
    sleep 30
  done
  for theme in phoenix amber pine ink plum graphite action; do
    for mode in 1 2; do
      for font in 0 1 2 3; do
        file="$OUT/themes/$theme-$mode-$font.png"
        [ -s "$file" ] && continue
        echo "== 外觀：$theme 背景$mode 字體$font"
        launch_theme "$id" "$theme" "$mode" "$font"
        sleep 7
        xcrun devicectl device capture screenshot --device "$id" --quiet --destination "$file"
        check_size "$file" 1206 2622
      done
    done
  done
}

capture_android() {
  echo "== 編譯 Android 展示版"
  (
    cd app
    bash tool/prepare_android.sh >/dev/null
    flutter pub get >/dev/null
    flutter build apk --release --target-platform android-arm64 -Pdemo=true \
      --dart-define=DEMO=true --dart-define=DEMO_FIRST="$ANDROID_WORD"
  )
  "$ADB" install -r app/build/app/outputs/flutter-apk/app-release.apk >/dev/null
  "$ADB" shell am force-stop "$BUNDLE"
  "$ADB" shell monkey -p "$BUNDLE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 8
  mkdir -p "$OUT/android"
  "$ADB" exec-out screencap -p > "$OUT/android/explore-$ANDROID_WORD.png"
  check_size "$OUT/android/explore-$ANDROID_WORD.png" 1440 3120
  # 截完就刪掉展示版，手機上只留平常用的 App
  "$ADB" uninstall "$BUNDLE" >/dev/null || true
}

case "$TARGET" in
  iphone) capture_iphone ;;
  android) capture_android ;;
  themes) capture_iphone themes ;;
  all) capture_iphone; capture_android ;;
  *) echo "用法：bash tools/capture_screens.sh [iphone|android|themes]" >&2; exit 2 ;;
esac
echo "== 完成：$OUT"
