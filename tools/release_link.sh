#!/usr/bin/env bash
# 把 Android 安裝檔（arm64）放到 Supabase 私人空間 dev-builds，登記在 dev_builds。
# 只給舊的 1.0.0 開發版抓更新用（它們向 dev_latest() 查新版）；0.2.0 build 11 以後的 App 改讀 release/latest.json。
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
  # ML Kit 會把 x86_64、armeabi-v7a 的檔案也放進來，拿掉再用同一把金鑰重簽，才不會超過 50 MB
  BT="$(ls -d "$HOME"/Library/Android/sdk/build-tools/* | sort -V | tail -1)"
  JAVA_HOME="${JAVA_HOME:-$(flutter config --list | sed -n 's/.*jdk-dir: //p')}"
  export JAVA_HOME PATH="$JAVA_HOME/bin:$PATH"
  TMP="$(mktemp -d)"
  cp app/build/app/outputs/flutter-apk/app-release.apk "$TMP/in.apk"
  zip -q -d "$TMP/in.apk" 'lib/x86_64/*' 'lib/armeabi-v7a/*' 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/MANIFEST.MF' || true
  "$BT/zipalign" -f -p 4 "$TMP/in.apk" "$TMP/aligned.apk"
  # 用發版金鑰重簽（~/.juango/key.properties，tools/make_release_key.sh 建的），不再用 debug.keystore
  KP="${JUANGO_KEY_PROPERTIES:-$HOME/.juango/key.properties}"
  [ -f "$KP" ] || { echo "找不到發版金鑰 $KP：先跑 bash tools/make_release_key.sh" >&2; exit 1; }
  kp() { sed -n "s/^$1=//p" "$KP"; }
  KS_PASS="$(kp storePassword)" KEY_PASS="$(kp keyPassword)"
  export KS_PASS KEY_PASS
  "$BT/apksigner" sign --ks "$(kp storeFile)" --ks-pass env:KS_PASS \
    --ks-key-alias "$(kp keyAlias)" --key-pass env:KEY_PASS --out "$OUT/$NAME" "$TMP/aligned.apk"
  rm -rf "$TMP"
  echo "== $(du -h "$OUT/$NAME" | cut -f1) $NAME"
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
