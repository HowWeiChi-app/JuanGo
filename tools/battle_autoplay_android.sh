#!/bin/sh
# 在 Android（BlueStacks 或接線的手機）上自動打排位對戰（開發版），用來測試對戰：
# 打開 App 後自己進「單字對戰」配對，每題開始後 0.7 秒選正確答案，打完一場 5 秒後再開下一場，
# 每一題、每一場的結果都印在這個終端機。按 Ctrl-C 停止（App 也會關掉；打到一半的那場算離開）。
#   sh tools/battle_autoplay_android.sh                   # BlueStacks（emulator-5554），0.7 秒
#   sh tools/battle_autoplay_android.sh <裝置序號> 1.5      # 指定裝置（adb devices 的序號）和秒數
# 正確答案用內建字典判斷。App 要先登入、做過程度測驗。只會改 App 的開啟方式，不會動到 App 裡的資料。
ADB=$(command -v adb || echo /Applications/BlueStacks.app/Contents/MacOS/hd-adb)
DEVICE=${1:-emulator-5554}
DELAY=${2:-0.7}
PKG=io.github.howweichi.juango
A="$ADB -s $DEVICE"
$A get-state >/dev/null 2>&1 || { echo "找不到 $DEVICE（BlueStacks 要先打開，或用 adb devices 看序號）"; exit 1; }
stop() {
  $A shell setprop debug.juango.autoplay "''" >/dev/null 2>&1
  $A shell am force-stop $PKG >/dev/null 2>&1
  echo; echo "已停止自動對戰"
  exit 0
}
trap stop INT TERM
echo "在 $DEVICE 開始自動對戰（每題 $DELAY 秒），按 Ctrl-C 停止"
$A shell setprop debug.juango.autoplay "$DELAY"
$A shell am force-stop $PKG
$A logcat -c
$A shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
$A logcat -v raw -s flutter:I | grep --line-buffered "JuanGo 自動對戰" | sed -u 's/^\[JuanGo 自動對戰 /[/'
stop
