#!/usr/bin/env bash
# 產生 Android 專案檔（android/ 資料夾），並補上這個 App 需要的設定。做法和 BanGo 相同：
# android/ 是 flutter create 自動產生的，不 commit，每次用這個腳本重新產生。
#
# 用法：在 app 資料夾裡跑  bash tool/prepare_android.sh

set -euo pipefail
cd "$(dirname "$0")/.."

# 1. 字典和考古題：iOS 版的檔案是唯一來源，這裡只複製，不另外維護一份
mkdir -p assets
cp ../ios/JuanGo/words.json ../ios/JuanGo/exams.json assets/

flutter create --platforms=android --org io.github.howweichi --project-name juango .
# flutter create 會補一個預設測試，這個專案用不到，留著反而編譯失敗
rm -f test/widget_test.dart
grep -qs "A new Flutter project" README.md && rm README.md

python3 - android/app/src/main/AndroidManifest.xml <<'PY'
import re
import sys
path = sys.argv[1]
m = open(path, encoding="utf-8").read()

# 2. 每日提醒要用的權限
for perm in ["android.permission.POST_NOTIFICATIONS", "android.permission.RECEIVE_BOOT_COMPLETED"]:
    if perm not in m:
        i = m.index(">", m.index("<manifest")) + 1
        m = m[:i] + f'\n    <uses-permission android:name="{perm}"/>' + m[i:]

# 3. Android 11 以上要先宣告會用語音引擎，才念得出單字
tts = """
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>"""
if "TTS_SERVICE" not in m:
    if "<queries>" in m:
        m = m.replace("<queries>", "<queries>" + tts, 1)
    else:
        m = m.replace("</manifest>", "    <queries>" + tts + "\n    </queries>\n</manifest>")

# 4. 排程通知的接收器（重開機後也要留著提醒）
receivers = """
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>"""
if "ScheduledNotificationReceiver" not in m:
    m = m.replace("</application>", receivers + "\n    </application>", 1)

# 5. 桌面上顯示的名稱：中文系統是「捲字」，其他語言是 JuanGo（和 iOS 版相同）
m = re.sub(r'android:label="[^"]*"', 'android:label="@string/app_name"', m, count=1)
open(path, "w", encoding="utf-8").write(m)
print("AndroidManifest.xml 已更新")
PY

mkdir -p android/app/src/main/res/values
printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string name="app_name">JuanGo</string>\n</resources>\n' \
  > android/app/src/main/res/values/strings.xml
# Android 把 values-zh 當成簡體，台灣和香港的手機要另外列出來才會顯示中文名稱
for dir in values-zh values-zh-rTW values-zh-rHK values-b+zh+Hant; do
  mkdir -p "android/app/src/main/res/$dir"
  printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string name="app_name">捲字</string>\n</resources>\n' \
    > "android/app/src/main/res/$dir/strings.xml"
done

# 6. flutter_local_notifications 需要 core library desugaring
python3 - android/app/build.gradle.kts <<'PY'
import re
import sys
path = sys.argv[1]
g = open(path, encoding="utf-8").read()
if "isCoreLibraryDesugaringEnabled" not in g:
    g = g.replace("compileOptions {", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", 1)
if "desugar_jdk_libs" not in g:
    g += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
open(path, "w", encoding="utf-8").write(g)
print("build.gradle.kts 已更新")
PY

# 7. App 圖示：tool/icon/ 由 tool/make_android_icon.swift 從 iOS 版的鳳凰圖產生
for dir in tool/icon/mipmap-*; do
  mkdir -p "android/app/src/main/res/$(basename "$dir")"
  cp "$dir"/* "android/app/src/main/res/$(basename "$dir")/"
done
# 通知圖示只在程式裡用名字引用，要告訴打包工具別把它當沒用到的資源刪掉
mkdir -p android/app/src/main/res/raw
cat > android/app/src/main/res/raw/keep.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="@mipmap/ic_notification" />
XML
echo "App 圖示已更新"
