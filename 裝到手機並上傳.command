#!/bin/sh
# 點兩下就檢查、測試，裝到 BlueStacks 和連著的 iPhone，最後問要不要 commit、push
cd "$(dirname "$0")" && exec bash tools/deploy_dev.sh "$@"
