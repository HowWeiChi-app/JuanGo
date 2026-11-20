#!/bin/sh
# 點兩下就在 BlueStacks 上自動打排位對戰（每題 0.7 秒），按 Ctrl-C 停止
cd "$(dirname "$0")" && exec sh tools/battle_autoplay_android.sh
