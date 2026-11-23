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

# 2. 帳號同步要連網路，每日提醒要通知權限
for perm in ["android.permission.INTERNET", "android.permission.POST_NOTIFICATIONS", "android.permission.RECEIVE_BOOT_COMPLETED"]:
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

# 帳號登入：信件裡的連結會回到 juango://login-callback（和 iOS 版相同）
login = """
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="juango" android:host="login-callback"/>
            </intent-filter>
            <meta-data android:name="flutter_deeplinking_enabled" android:value="false"/>"""
if 'android:scheme="juango"' not in m:
    m = m.replace("</activity>", login + "\n        </activity>", 1)

# 好友和房間的連結（連結、QR code、限動圖片都用這個）：juango://friend/<好友代碼>、juango://room/<房間代碼>
share = """
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="juango" android:host="friend"/>
                <data android:scheme="juango" android:host="room"/>
            </intent-filter>"""
if 'android:host="friend"' not in m:
    m = m.replace("</activity>", share + "\n        </activity>", 1)

# 分享到 Instagram 限動：要能看到 Instagram（Android 11 以上的套件可見性），並把圖片用 content:// 給它讀
ig = """
        <package android:name="com.instagram.android" />
        <intent>
            <action android:name="com.instagram.share.ADD_TO_STORY" />
            <data android:mimeType="image/*" />
        </intent>"""
if "com.instagram.share.ADD_TO_STORY" not in m:
    m = m.replace("<queries>", "<queries>" + ig, 1)
provider = """
        <provider android:name=".StoryProvider" android:authorities="${applicationId}.story"
            android:exported="false" android:grantUriPermissions="true" />"""
if ".StoryProvider" not in m:
    m = m.replace("</application>", provider + "\n    </application>", 1)

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

# 分享到 Instagram 限動（Meta 的「分享到限時動態」）：Flutter 端在 lib/friends.dart 的 shareToStory。
# 圖片在 App 的暫存資料夾，StoryProvider 只把那個資料夾裡的檔案唯讀給 Instagram。
cat > android/app/src/main/kotlin/io/github/howweichi/juango/MainActivity.kt <<'KT'
package io.github.howweichi.juango

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "juango/instagram").setMethodCallHandler { call, result ->
            if (call.method != "shareStory") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = File(call.argument<String>("path") ?: "").name
            val appId = call.argument<String>("appId") ?: ""
            val uri = Uri.parse("content://$packageName.story/$name")
            val intent = Intent("com.instagram.share.ADD_TO_STORY").apply {
                setDataAndType(uri, "image/png")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                // 2023 年起一定要帶 Meta App ID，不然 Instagram 會說「不支援分享到限時動態」
                putExtra("source_application", appId)
            }
            when {
                packageManager.resolveActivity(intent, 0) == null -> result.success("notInstalled")
                appId.isEmpty() -> result.success("noAppId")
                else -> try {
                    grantUriPermission("com.instagram.android", uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    startActivity(intent)
                    result.success("opened")
                } catch (e: Exception) {
                    result.error("share", e.message, null)
                }
            }
        }
    }
}

class StoryProvider : ContentProvider() {
    private fun file(uri: Uri): File? {
        val dir = context?.cacheDir ?: return null
        val f = File(dir, File(uri.lastPathSegment ?: return null).name)
        return if (f.isFile && f.canonicalPath.startsWith(dir.canonicalPath)) f else null
    }

    override fun onCreate() = true
    override fun getType(uri: Uri) = "image/png"
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? =
        file(uri)?.let { ParcelFileDescriptor.open(it, ParcelFileDescriptor.MODE_READ_ONLY) }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
                       selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val f = file(uri) ?: return null
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
            addRow(arrayOf<Any>(f.name, f.length()))
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
KT

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
# 官網截圖用的展示版：編譯時帶 -Pdemo 就換成另一個套件 ID，資料和平常安裝的 App 分開
if 'hasProperty("demo")' not in g:
    g = g.replace("defaultConfig {", 'defaultConfig {\n        if (project.hasProperty("demo")) applicationIdSuffix = ".demo"', 1)
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

# 8. 課文書架：單字表要用中文辨識器，模型要另外加；日文、韓文、印地文辨識器沒用到，告訴 R8 不用找
python3 - android/app/build.gradle.kts <<'PY'
import sys
path = sys.argv[1]
g = open(path, encoding="utf-8").read()
if "text-recognition-chinese" not in g:
    g += '\ndependencies {\n    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")\n}\n'
open(path, "w", encoding="utf-8").write(g)
print("build.gradle.kts 已加中文辨識")
PY
cat > android/app/proguard-rules.pro <<'TXT'
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
TXT
