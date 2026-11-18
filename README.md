# 捲字 JuanGo

捲字 JuanGo 是英文單字複習 App，用間隔複習幫你把單字從「初見」練到「精通」。單字範圍從國小、國中、大考一路到多益、雅思、托福。iPhone 版用 SwiftUI 製作，Android 版用 Flutter 製作，兩邊版面相同。

## 功能

- **主頁**：每日目標進度環、待複習數、連續天數，一鍵開始今日學習；「我的清單」每列顯示幾個字待複習，點一下就練那個清單，還有自動產生的「最近答錯」列表；今天練完會顯示明天有幾個字要複習；自由練習、學習紀錄
- **例句**：內建字庫多數都附有事先產生的例句和中文翻譯，少數由裝置端 Apple Intelligence 在背景補上；例句裡的單字會標出來。單字頁和字卡背面可以聽整句例句，不喜歡的例句可以「換一句」
- **探索**：左右滑的單字卡，點兩下收進「我的單字」
- **相似字詞**：字卡的例句下方列出約 3 個意思相近的字
- **程度測驗**：新手導覽的 18 題適應性測驗，答對變難、答錯變簡單，推定第 1 到第 6 級
- **大考考古題**：113 到 115 學年度學測英文選擇題，可以整份作答或依題型練習，答錯的單字能一次加入「我的單字」
- **新增**：輸入英文或中文查字；貼上從記事本或聊天複製的單字清單；拍照掃描課本，或從相簿和檔案（txt／csv）匯入
- **AI 翻譯**：字典沒有的字會自動翻成繁體中文。可填任何 OpenAI 相容的 API，預設是 [Agnes AI](https://platform.agnes-ai.com) 的免費模型；沒有 key 時用裝置上的 Apple Intelligence。關閉時用 Apple 翻譯
- **字庫**：我的單字、清單以及內建字庫：
    - 大考詞彙：基礎 2000、進階 4000、學測 6000+
    - 國中小 1200：教育部國中小基本字彙
    - 多益 TOEIC、雅思 IELTS、托福 TOEFL
- **練習**：翻卡片、英翻中、中翻英、克漏字、聽力、拼單字；自動安排或手動挑選題型、無盡模式
    - 片語照考試的方式出題
    - 選擇題可以按「不知道」直接看答案
    - 拼單字直接在字母格裡打字，連字號、撇號這類符號會先給；「提示」會補下一個字母；英式、美式拼法都算對；拼錯可以「再打一次」照著正確拼法打一遍
    - 聽力題可以「慢速再聽」
    - 結算頁先列出這輪的字，點字可看單字頁，也可以「只練答錯的字」
    - 複習以「天」為單位到期：昨晚練的字，今天早上就會出現在待複習
- **我的**：連續天數、學習日曆、熟練階梯、成就勳章
- **單字對戰**：登入後優先和積分相近的真人即時對戰，等 10 秒沒有真人就改配電腦，也能用 6 碼房間代碼邀請朋友。5 回合、每題 10 秒，答對越快分數越高，最後一題 1.5 倍。排位賽用 Elo 積分，每 200 分一級，對應單字第 1 到 6 級（400 分是高一程度的第 3 級，1000 分以上是第 6 級），題目難度跟著等級走；朋友對戰不計分
- **App 捷徑**：對 Siri 說「用 JuanGo 開始今日學習」，或從 Spotlight、捷徑 App、動作按鈕直接開始今天的練習
- **每日提醒**：設定的時間提醒複習，並說今天有幾個字到期；當天已經練過就不提醒
- **備份與分享**：設定 › 備份可匯出／還原全部資料；清單頁右上角可把清單分享成檔案或 8 碼分享代碼，別人在「新增 › 匯入檔案／輸入分享代碼」加入
- **帳號與同步**：用 Email 連結登入（Supabase），單字和進度自動備份到雲端，換手機登入就回來
- 7 組主題色，頁面底色與區塊跟著主題色調變化，支援深色模式
- 支援 VoiceOver（圖示按鈕、圖表、日曆、勳章都有完整說明）、大字體和「減少動態效果」

Android 版有帳號與同步，用同一個 Email 登入後，iPhone 和 Android 的單字和進度會合併。Android 版目前沒有拍照掃描、分享代碼、AI 翻譯、「換一句」、Siri 捷徑和圓體字型。

## 設計

- iPhone 版以原生 SwiftUI 元件為主（List、Liquid Glass 按鈕），搜尋框是自製的玻璃膠囊，規則寫在 `docs/DESIGN.md`
- Android 版用 Flutter 照同一套版面製作
- iPhone 版的圖示使用 Apple 的 SF Symbols，Android 版使用 Material Icons

## 專案結構

| 路徑 | 內容 |
|---|---|
| `ios/` | iPhone App（原生 SwiftUI），程式碼在 `ios/JuanGo/`。主頁在 `StudyTab.swift`，練習流程拆成 `StudyFlow`（設定）、`SessionEngine`（出題與排程）、`SessionView`、`Questions`（各題型）、`Summary`（結算、學習紀錄） |
| `app/` | Android App（Flutter）。`android/` 和字典檔由 `tool/prepare_android.sh` 產生，不進版本控制 |
| `ios/JuanGo/words.json` | 內建字典（10,492 個字，含分級、標記、例句和相似字詞），兩個平台共用 |
| `ios/JuanGo/exams.json` | 學測英文考古題，兩個平台共用 |
| `supabase/` | 雲端同步與單字對戰的資料表、權限規則。對戰要先在 SQL Editor 依序執行 `battle.sql`、`battle_words.sql` |
| `tools/examples/` | 在 Mac 上用 Apple Intelligence 批次產生例句，產生後用 `merge.py` 併進 `words.json`。比對單字的 `WordMatch.swift` 和 App 裡是同一套規則，修改時兩邊要一起改 |
| `tools/exams/` | 把大考中心公布的試題和答案 PDF 轉成 `exams.json` |
| `tools/similar/` | 產生相似字詞，寫進 `words.json` |
| `tools/battle/` | 從 `words.json` 產生對戰題庫 `supabase/battle_words.sql` |
| `tools/build_release.sh` | 編譯要發布的 APK 和 IPA |
| `docs/` | 介面設計規則（`DESIGN.md`） |
| `.github/workflows/` | 自動化流程：編譯 Android App、編譯 iPhone App |
| `dist/` | 本機的發版輸出，不進 repo |

## 安裝

### iPhone

- **自己編譯**：用 Xcode 26 打開 `ios/JuanGo.xcodeproj`，在 Signing \& Capabilities 換成自己的 Team，執行到 iPhone 或模擬器。
- **自己簽名安裝 IPA**：下載 Releases 裡的 IPA，用 [Sideloadly](https://sideloadly.io) 或 [AltStore](https://altstore.io) 以自己的 Apple ID 簽名安裝。iPhone 要打開「設定 › 隱私權與安全性 › 開發者模式」，並在「設定 › 一般 › VPN 與裝置管理」信任自己的 Apple ID。免費 Apple ID 簽的 App 每 7 天要重簽一次（資料不會消失）。

需求：iOS 26、Xcode 26。

### Android

- **安裝 APK**：下載 Releases 裡的 APK，打開後依畫面提示允許安裝未知來源的 App。
- **自己編譯**：需要 Flutter 3.50、JDK 21 和 Android SDK 36。

```bash
cd app
bash tool/prepare_android.sh
flutter test
flutter build apk --release
```

## 發版

1. 改版本號：`app/pubspec.yaml` 的 `version`（例如 `0.2.0+4`），以及 `ios/JuanGo.xcodeproj` 的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。兩個平台的版本要相同，`+` 後面的數字每版都要變大，手機才能直接更新。
2. 在 repo 根目錄編譯。指令會跑檢查和測試，再把 APK、IPA 放到 `dist/release/`，最後印出 SHA-256。

   ```bash
   bash tools/build_release.sh
   ```

3. 到 GitHub Releases 建立 `v` 開頭的版本，附上這兩個檔案。測試版要勾選 Pre-release。

Android 版要用同一把簽名金鑰編譯，已安裝的手機才能直接更新，所以發版都在同一台電腦上做。

## 資料來源與授權

- 大考詞彙與分級：大學入學考試中心《高中英文參考詞彙表》（111 學年度起適用），僅供非營利學習使用。
- 國中小 1200：教育部《十二年國民基本教育課程綱要 語文領域－英語文》附錄五表一「基本 1,200 字」。
- 多益：[TOEIC Service List 1.2](https://newgeneralservicelist.com/toeic-service-list)（Browne, C. \& Culligan, B.），[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)；`words.json` 中由它而來的 `toeic` 標記同樣以 CC BY-SA 4.0 釋出。
- 雅思、托福字表，以及中文解釋與音標：整理自 [ECDICT](https://github.com/skywind3000/ECDICT)（MIT License），並轉為繁體中文（台灣用語），內容可能有誤。
- 圖示：Apple SF Symbols（iPhone）、Material Icons（Android，Apache 2.0）。
- 學習資料預設只存在自己的裝置上；登入帳號後會同步到 JuanGo 的 Supabase 專案（每個人只能讀寫自己的資料，分享清單只能用代碼取得，資料表與權限規則見 `supabase/schema.sql`）。打開 API 翻譯並設定 key 後，字典沒有的單字會傳到該 API 的伺服器翻譯；key 存在裝置的鑰匙圈，不在程式碼裡。

這是一個高中自主學習專案。
