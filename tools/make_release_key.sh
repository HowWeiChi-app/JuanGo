#!/usr/bin/env bash
# 建立 Android 發版金鑰（只要做一次）。請自己在終端機跑：bash tools/make_release_key.sh
# 會問你密碼（輸入時不會顯示）。金鑰和密碼都放在 ~/.juango/，不在專案裡、不會進 Git。
#
# 一定要備份 ~/.juango/juango-release.jks 和密碼（例如放密碼管理器）：
# 金鑰不見就再也不能更新已經裝的 App，只能請大家刪掉重裝。
set -euo pipefail

dir="$HOME/.juango"
jks="$dir/juango-release.jks"
props="$dir/key.properties"
alias_name="juango"

if [ -e "$jks" ] || [ -e "$props" ]; then
  echo "已經有發版金鑰了：$jks"
  echo "不要重建（重建等於換金鑰，大家都要重裝）。要換請先自己把舊檔移走。"
  exit 1
fi

# macOS 的 /usr/bin/keytool 只是空殼，沒裝 Java 會失敗；先找 Flutter 設定的 JDK（flutter config 的 jdk-dir，Gradle 編譯也是用它）
keytool=""
flutter_jdk=$(flutter config --list 2>/dev/null | awk '/jdk-dir:/{print $2}' || true)
for k in ${JAVA_HOME:+"$JAVA_HOME/bin/keytool"} ${flutter_jdk:+"$flutter_jdk/bin/keytool"} \
  /opt/homebrew/opt/openjdk@21/bin/keytool /opt/homebrew/opt/openjdk/bin/keytool /usr/local/opt/openjdk/bin/keytool \
  "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" \
  "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" \
  "$(/usr/libexec/java_home 2>/dev/null)/bin/keytool" \
  "$(command -v keytool 2>/dev/null)"; do
  if [ -n "$k" ] && [ -x "$k" ] && "$(dirname "$k")/java" -version >/dev/null 2>&1; then keytool="$k"; break; fi
done
[ -n "$keytool" ] || { echo "找不到能用的 keytool：請先裝 Android Studio（或 JDK）"; exit 1; }
echo "用 $keytool"

read -r -s -p "設定金鑰密碼（至少 8 個字）：" pw; echo
read -r -s -p "再輸入一次：" pw2; echo
[ "$pw" = "$pw2" ] || { echo "兩次不一樣"; exit 1; }
[ ${#pw} -ge 8 ] || { echo "太短了"; exit 1; }

export JUANGO_PW="$pw"
mkdir -p "$dir"
chmod 700 "$dir"
"$keytool" -genkeypair -v -keystore "$jks" -storetype PKCS12 -alias "$alias_name" \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass:env JUANGO_PW -keypass:env JUANGO_PW \
  -dname "CN=JuanGo, O=howweichi, C=TW"

umask 077
cat > "$props" <<EOF
storeFile=$jks
storePassword=$pw
keyAlias=$alias_name
keyPassword=$pw
EOF
chmod 600 "$jks" "$props"

echo
echo "完成：$jks"
echo "憑證指紋（之後可用來確認 APK 是不是你簽的）："
"$keytool" -list -v -keystore "$jks" -storepass:env JUANGO_PW -alias "$alias_name" | grep -E "SHA256:" || true
echo
echo "記得備份 $jks 和密碼。"
