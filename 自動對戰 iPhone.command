#!/bin/sh
# 點兩下就在連著的 iPhone 上自動打排位對戰（每題 0.7 秒），關掉這個視窗或按 Ctrl-C 停止
cd "$(dirname "$0")" && exec sh tools/battle_autoplay.sh
