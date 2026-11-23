#!/usr/bin/env bash
# 發一版開發版（含對戰）給內測的人。安裝檔放在 Supabase 的私人空間 dev-builds，外人拿不到：
# 內測名單（dev_testers）裡的帳號打開 App 會跳提醒下載；新同學用一次性連結
#   select public.dev_link_new('同學名字');
# 拿到 https://howweichi-app.github.io/JuanGo-dev/?t=… ，按一次下載就失效。
#
# 用法（在 repo 根目錄）：
#   1. bash tools/release_dev.sh build "這版改了什麼"
#      編號 +1、編譯 arm64 APK，印出第一段 SQL（暫時允許上傳這一個檔名），貼到 Supabase SQL Editor 執行
#   2. bash tools/release_dev.sh upload
#      上傳安裝檔，印出第二段 SQL（登記這一版、收回上傳權限），再貼去執行

set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/dist/dev"
URL="$(sed -n "s/.*static const url = '\(.*\)';/\1/p" app/lib/cloud.dart)"
KEY="$(sed -n "s/.*static const key = '\(.*\)';/\1/p" app/lib/cloud.dart)"
sq() { printf "%s" "$1" | sed "s/'/''/g"; }

case "${1:-}" in
build)
  grep -q "devGosPro = true" app/lib/pro.dart || { echo "這裡不是開發版（devGosPro 不是 true）" >&2; exit 1; }
  NOTES="${2:-}"
  VERSION="$(sed -n 's/^version: \([^+]*\)+.*/\1/p' app/pubspec.yaml)"
  # 內測版號照 devBuild +1（以前照 pubspec 的 +號，兩個不同步時會跳號）；Android versionCode 不能變小，所以取兩者較大的
  CODE="$(sed -n 's/^version: [^+]*+\(.*\)/\1/p' app/pubspec.yaml)"
  NEXT=$(( $(sed -n 's/^const devBuild = \([0-9]*\);/\1/p' app/lib/dev_update.dart) + 1 ))
  (( CODE < NEXT )) && CODE=$NEXT
  sed -i '' "s/^version: .*/version: $VERSION+$CODE/" app/pubspec.yaml
  sed -i '' "s/^const devBuild = .*/const devBuild = $NEXT;/" app/lib/dev_update.dart
  echo "== 開發版 $VERSION ($NEXT)"
  (cd app && flutter build apk --release --target-platform android-arm64 -Parm64only=true)
  mkdir -p "$OUT"
  NAME="build-$NEXT-$(openssl rand -hex 8).apk"
  cp app/build/app/outputs/flutter-apk/app-release.apk "$OUT/$NAME"
  printf 'NAME=%s\nBUILD=%s\nVERSION=%s\nNOTES=%q\n' "$NAME" "$NEXT" "$VERSION" "$NOTES" > "$OUT/pending.env"
  cat <<SQL

== 第一段 SQL：
drop policy if exists "dev build upload" on storage.objects;
create policy "dev build upload" on storage.objects for insert to anon
  with check (bucket_id = 'dev-builds' and name = '$NAME');
SQL
  ;;
upload)
  # shellcheck disable=SC1091
  source "$OUT/pending.env"
  curl -sf -X POST "$URL/storage/v1/object/dev-builds/$NAME" -H "apikey: $KEY" \
    -H "Content-Type: application/vnd.android.package-archive" --data-binary @"$OUT/$NAME" > /dev/null
  echo "== 已上傳 $NAME"
  cat <<SQL

== 第二段 SQL：
drop policy if exists "dev build upload" on storage.objects;
insert into public.dev_builds (build, version, notes, path)
values ($BUILD, '$VERSION', '$(sq "$NOTES")', '$NAME');
SQL
  ;;
*) sed -n '2,12p' "$0"; exit 1 ;;
esac
