#!/usr/bin/env bash
# 把測試版的 Android 安裝檔（arm64）放到 Supabase 私人空間 dev-builds，給一次性下載連結用：
#   select public.dev_link_new('名字');
# 拿到 https://howweichi-app.github.io/juango/download/?t=… ，按一次下載就失效，下載到的一律是最新登記的那一版。
#
# 用法（在 repo 根目錄，先跑過 tools/build_release.sh）：
#   1. bash tools/release_link.sh build "這版改了什麼"
#      編譯 arm64 APK（Supabase 免費方案單檔上限 50 MB，所以不用通用版），印出第一段 SQL，貼到 SQL Editor 執行
#   2. bash tools/release_link.sh upload
#      上傳安裝檔，印出第二段 SQL（登記這一版、收回上傳權限），再貼去執行

set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/dist/test"
URL="$(sed -n "s/.*static const url = '\(.*\)';/\1/p" app/lib/cloud.dart)"
KEY="$(sed -n "s/.*static const key = '\(.*\)';/\1/p" app/lib/cloud.dart)"
sq() { printf "%s" "$1" | sed "s/'/''/g"; }

case "${1:-}" in
build)
  NOTES="${2:-}"
  VERSION="$(sed -n 's/^version: \([^+]*\)+.*/\1/p' app/pubspec.yaml)"
  BUILD="$(sed -n 's/^version: [^+]*+\(.*\)/\1/p' app/pubspec.yaml)"
  echo "== 測試版 $VERSION ($BUILD)"
  (cd app && flutter build apk --release --target-platform android-arm64)
  mkdir -p "$OUT"
  NAME="build-$BUILD-$(openssl rand -hex 8).apk"
  cp app/build/app/outputs/flutter-apk/app-release.apk "$OUT/$NAME"
  # %q mangles Chinese in macOS's bash 3.2, so quote by hand
  printf "NAME=%s\nBUILD=%s\nVERSION=%s\nNOTES='%s'\n" "$NAME" "$BUILD" "$VERSION" "$(printf "%s" "$NOTES" | sed "s/'/'\\\\''/g")" > "$OUT/pending.env"
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
*) sed -n '2,10p' "$0"; exit 1 ;;
esac
