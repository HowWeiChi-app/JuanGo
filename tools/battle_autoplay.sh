#!/bin/sh
# 在 iPhone 上用自動作答模式打開開發版（Debug 建置）：每題開始後 0.7 秒選正確答案，用來測試對戰。
#   sh tools/battle_autoplay.sh                 # 第一台連著的 iPhone，0.7 秒
#   sh tools/battle_autoplay.sh <裝置> 1.5       # 指定裝置（名稱或 UDID）和秒數
# 打開後照常進「單字對戰」開始一場；正確答案用內建字典判斷。
set -e
DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | grep 'iPhone' | grep 'physical' | grep -v 'unavailable' \
  | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)}
DELAY=${2:-0.7}
[ -n "$DEVICE" ] || { echo "找不到連著的 iPhone"; exit 1; }
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing \
  --environment-variables "{\"JUANGO_BATTLE_AUTOPLAY\": \"$DELAY\"}" io.github.howweichi.juango
echo "已在 $DEVICE 打開自動作答（每題 $DELAY 秒）"
