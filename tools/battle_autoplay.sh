#!/bin/sh
# 在 iPhone 上自動打排位對戰（開發版 Debug 建置），用來測試對戰：
# 打開 App 後自己進「單字對戰」配對，每題開始後 0.7 秒選正確答案，打完一場 5 秒後再開下一場，
# 每一題、每一場的結果都印在這個終端機。按 Ctrl-C 停止（App 也會關掉；打到一半的那場算離開）。
#   sh tools/battle_autoplay.sh                 # 第一台連著的 iPhone，0.7 秒
#   sh tools/battle_autoplay.sh <裝置> 1.5       # 指定裝置（名稱或 UDID）和秒數
# 正確答案用內建字典判斷。手機要先登入、做過程度測驗。
DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | grep 'iPhone' | grep 'physical' | grep -v 'unavailable' \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)}
DELAY=${2:-0.7}
[ -n "$DEVICE" ] || { echo "找不到連著的 iPhone（要解鎖，並和 Mac 在同一個網路或接線）"; exit 1; }
echo "在 $DEVICE 開始自動對戰（每題 $DELAY 秒），按 Ctrl-C 停止"
exec xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console \
  --environment-variables "{\"JUANGO_BATTLE_AUTOPLAY\": \"$DELAY\"}" io.github.howweichi.juango
