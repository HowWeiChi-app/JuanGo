# 捲字 JuanGo

捲字 JuanGo 是英文單字複習 App，用間隔複習幫你把單字從「初見」練到「精通」。單字範圍從國小、國中、大考一路到多益、雅思、托福。iPhone 版用 SwiftUI 製作，Android 版用 Flutter 製作，兩邊版面相同。

## 功能

最新版本是 [0.2.0 測試版](https://github.com/HowWeiChi-app/JuanGo/releases/tag/v0.2.0)（build 10），這一版加入單字對戰、好友、課文書架和雲端 AI。

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
- **回報單字問題**：單字頁的選單按「回報問題」，可以回報解釋、音標、詞性、例句、發音或分級錯誤；沒網路時先存著，下次打開 App 再送出
- **考前倒數**：設定考試名稱和日期，主頁顯示倒數，並依剩下的天數調整每日新字
- **我的**：連續天數、學習日曆、熟練階梯、成就勳章
- **捲字 Pro 方案頁**：可以先看方案和價格（捲字 Pro、GOs PRO、180 天大考衝刺包），商店開通後才能購買
- **單字對戰**：登入並做完 18 題程度測驗後，和積分相近的玩家即時對戰
    - 一局 10 題、每題 10 秒，英翻中和中翻英各半；答對越快分數越高
    - 排位賽有六個段位和賽季排行，題目難度跟著雙方積分走；等太久會改配電腦
    - 免費版每天 10 場排位賽，捲字 Pro 不限；用房間代碼和朋友對戰不計分、不限場次
    - 完整規則見 `docs/單字對戰規則.md`
- **好友**：用好友代碼、連結或 QR code 加好友，可以開公開房間，也能把對戰結果做成 Instagram 限動圖片
- **課文書架**：拍下課本或從相簿匯入，整篇課文變成可以點字查詢的電子書，依「書 › 課 › 頁」整理，登入後同步；免費版可以建 1 課（最多 3 頁）
- **雲端 AI（捲字 Pro）**：登入的 Pro 用戶可以用伺服器上的 AI，每月有使用次數上限，App 裡不放任何 AI 金鑰
- **App 捷徑**：對 Siri 說「用 JuanGo 開始今日學習」，或從 Spotlight、捷徑 App、動作按鈕直接開始今天的練習
- **每日提醒**：設定的時間提醒複習，並說今天有幾個字到期；當天已經練過就不提醒
- **備份與分享**：設定 › 備份可匯出／還原全部資料；清單頁右上角可把清單分享成檔案或 8 碼分享代碼，別人在「新增 › 匯入檔案／輸入分享代碼」加入
- **帳號與同步**：用 Email 連結登入（Supabase），單字和進度自動備份到雲端，換手機登入就回來
- 7 組主題色，頁面底色與區塊跟著主題色調變化，支援深色模式
- 支援 VoiceOver（圖示按鈕、圖表、日曆、勳章都有完整說明）、大字體和「減少動態效果」

Android 版有帳號與同步，用同一個 Email 登入後，iPhone 和 Android 的單字和進度會合併。Android 版也有單字對戰、好友、課文書架（用 Google ML Kit 辨識文字）和分享代碼；目前沒有拍照抓單字、「換一句」、Siri 捷徑和圓體字型，AI 功能用捲字 Pro 的雲端 AI。

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
| `supabase/` | 雲端同步、單字對戰、好友、課文書架、訂閱和 AI 配額的資料表與權限規則；對戰相關檔案的執行順序寫在 `docs/單字對戰規則.md` |
| `tools/examples/` | 在 Mac 上用 Apple Intelligence 批次產生例句，產生後用 `merge.py` 併進 `words.json`。比對單字的 `WordMatch.swift` 和 App 裡是同一套規則，修改時兩邊要一起改 |
| `tools/exams/` | 把大考中心公布的試題和答案 PDF 轉成 `exams.json` |
| `tools/similar/` | 產生相似字詞，寫進 `words.json` |
| `tools/battle/` | 從 `words.json` 產生對戰題庫 `supabase/battle_words.sql` |
| `tools/build_release.sh` | 編譯要發布的 APK 和 IPA |
| `tools/release_link.sh` | 把 Android 安裝檔放上 Supabase，給一次性下載連結用（說明在 `docs/下載連結.md`） |
| `docs/` | 介面設計規則（`DESIGN.md`）、單字對戰規則（`單字對戰規則.md`）、下載連結（`下載連結.md`）、iPhone 安裝教學（`iPhone安裝教學.md`） |
| `.github/workflows/` | 自動化流程：編譯 Android App、編譯 iPhone App |
| `dist/` | 本機的發版輸出，不進 repo |

## 安裝

### iPhone

- **自己編譯**：用 Xcode 26 打開 `ios/JuanGo.xcodeproj`，在 Signing \& Capabilities 換成自己的 Team，執行到 iPhone 或模擬器。
- **自己簽名安裝 IPA**：下載 Releases 裡的 IPA，用 [Sideloadly](https://sideloadly.io) 或 [AltStore](https://altstore.io) 以自己的 Apple ID 簽名安裝。iPhone 要打開「設定 › 隱私權與安全性 › 開發者模式」，並在「設定 › 一般 › VPN 與裝置管理」信任自己的 Apple ID。免費 Apple ID 簽的 App 每 7 天要重簽一次（資料不會消失）。

需求：iOS 26、Xcode 26。

**用 SideInstaller 安裝（給第一次側載的人）：** 下面一步一步照著做就可以。

捲字還沒有上架 App Store，所以要用「側載」的方式安裝：用你自己的 Apple 帳號替 App 簽名，再裝到 iPhone 上。SideInstaller 是一個免費、開放原始碼的工具，可以直接在 iPhone 上完成這件事，大部分情況不需要電腦。

第一次大約要 20～30 分鐘，之後更新捲字只要按一下連結。

#### 先確認這幾件事

- **iPhone 的系統版本**：到「設定 › 一般 › 關於本機」看「iOS 版本」。捲字需要 **iOS 26 以上**。
  - iOS 27 以上：照下面的「A. iOS 27 以上（不用電腦）」做。
  - iOS 26：要先借用一台電腦做一次「配對檔」，照「B. iOS 26（要電腦一次）」做。
- **Wi-Fi**：第一次安裝要連 Wi-Fi。
- **Apple 帳號**：就是你登入 App Store 的帳號和密碼，免費帳號就可以。密碼只在你的手機上用來簽名，不會傳給捲字或 SideInstaller 的作者。
- **只從官方來源下載 SideInstaller**：官方網站是 [sideinstaller.net](https://sideinstaller.net/)，程式碼在 [GitHub](https://github.com/FrizzleM/SideInstaller)。**sideinstaller.com 是假網站**，可能會偷你的 Apple 帳號，不要用。

#### A. iOS 27 以上（不用電腦）

##### 第 1 步：從 App Store 下載三個免費 App

| App | 用途 | 下載 |
| --- | --- | --- |
| rootshell | 在手機上跑配對用的指令 | [App Store](https://apps.apple.com/app/rootshell-local-terminal-ssh/id6755794662) |
| Open Minis | 在手機上跑安裝 SideInstaller 的指令 | [App Store](https://apps.apple.com/app/id6759188481) |
| LocalDevVPN | 讓手機自己連到自己，安裝時要開著 | [App Store](https://apps.apple.com/app/id6755608044) |

##### 第 2 步：在 rootshell 配對

1. 打開 rootshell，進到 **Settings › Location Diary Mode**，選 **Session Only**。
2. 回到主畫面，點 **Local Shell**，再點右上角的 **Open**，會出現一個可以打字的黑色畫面（終端機）。
3. 下面三行**一次貼一行**，每貼一行就按鍵盤上的「換行」執行，等它跑完再貼下一行：

   ```sh
   curl -fsSLO https://raw.githubusercontent.com/FrizzleM/siboot/main/rootshell/bin/siboot-pair.wasm
   ```

   ```sh
   ifconfig en0 > ifconfig.txt
   ```

   ```sh
   ./siboot-pair.wasm
   ```

4. 跑完第三行後，rootshell 會顯示一組配對碼。**不要關掉 rootshell**，切到「設定 › 隱私權與安全性 › 開發者模式」，滑到最下面，點 **Pair with siboot**，輸入手機密碼和 rootshell 上的配對碼。

##### 第 3 步：在 Open Minis 安裝 SideInstaller

1. 打開 LocalDevVPN，按連線，讓它保持連線。
2. 打開 Open Minis，點右上角的終端機圖示，再點 **Shell Terminal**。
3. 貼上這一行並執行：

   ```sh
   wget -qO- https://raw.githubusercontent.com/FrizzleM/siboot/main/minis/install.sh | sh
   ```

4. 依序輸入它問的東西：
   - rootshell 顯示的**傳輸碼**（只有第一次要輸入）
   - 你的 **Apple 帳號 email**
   - **Apple 帳號密碼**
   - 手機或其他 Apple 裝置收到的 **6 位數驗證碼**
5. 畫面說完成之前不要切走 Open Minis。
6. 到「設定 › 一般 › VPN 與裝置管理」，點你的 Apple 帳號，按「信任」。

如果「設定 › 隱私權與安全性」裡找不到「開發者模式」開關，配對完成後在 Open Minis 執行下面這行，它會幫你打開：

```sh
siboot developer-mode --turn-on
```

##### 第 4 步：用 SideInstaller 安裝 SideStore

1. 確認 LocalDevVPN 還是連線中。
2. 打開 SideInstaller，登入你的 Apple 帳號。
3. 點 **Install SideStore**（只裝 SideStore）或 **Install SideStore + LiveContainer**。

##### 第 5 步：安裝捲字

1. 確認 LocalDevVPN 連線中。
2. 在 iPhone 用 Safari 打開這個連結：**[一鍵安裝捲字 JuanGo 0.2.0](https://sideinstaller.net/open.html?url=https%3A%2F%2Fgithub.com%2FHowWeiChi-app%2FJuanGo%2Freleases%2Fdownload%2Fv0.2.0%2FJuanGo-0.2.0.ipa)**
3. 網頁會顯示安裝檔來自 `github.com/HowWeiChi-app/JuanGo`，然後打開 SideInstaller。如果沒有自動打開，按網頁上的按鈕。
4. SideInstaller 問要不要安裝時按確定，等它下載、簽名、安裝完成，主畫面就會出現捲字。

也可以在 SideStore 或 LiveContainer 裡自己貼上安裝檔網址：

```text
https://github.com/HowWeiChi-app/JuanGo/releases/download/v0.2.0/JuanGo-0.2.0.ipa
```

#### B. iOS 26（要電腦一次）

iOS 26 的 iPhone 要先用電腦做一個「配對檔」，之後就可以在手機上完成。

1. **安裝 SideInstaller**：在 iPhone 用 Safari 打開 [sideinstaller.net/#legacy](https://sideinstaller.net/#legacy)，照網頁上的說明用其中一個企業憑證安裝 SideInstaller。
2. **在電腦做配對檔**：
   - iOS 26.4 以上：在 Mac 或 Windows 電腦下載 [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases/latest)，用線把 iPhone 接上電腦，iPhone 問要不要信任這台電腦時按「信任」。在 idevice_pair 選你的 iPhone，選 **Remote pairing**，按 **Create**，完成前 iPhone 不要鎖定，再按 **Save to file…** 存檔。
   - iOS 26.0～26.3：照 [SideStore 的配對檔說明](https://docs.sidestore.io/docs/advanced/alternative#pairing) 做。
3. 用 AirDrop、iCloud 雲碟或傳輸線把配對檔傳到 iPhone。
4. 從 App Store 安裝 [LocalDevVPN](https://apps.apple.com/app/id6755608044) 並連線。
5. 打開 SideInstaller，點 **Import pairing file**，選剛才的配對檔。
6. 到「設定 › 一般 › VPN 與裝置管理」信任 SideInstaller 的憑證，再接著做上面 A 的**第 4 步和第 5 步**。

#### 常見問題

- **App 打不開，說「不受信任的開發者」**：到「設定 › 一般 › VPN 與裝置管理」，點你的 Apple 帳號，按「信任」。
- **7 天後打不開**：免費 Apple 帳號簽的 App 只能用 7 天。打開 SideStore 按重新整理（Refresh），或再按一次上面的一鍵安裝連結就好，學習紀錄不會消失。
- **說 App 數量已滿**：免費 Apple 帳號同時只能裝 3 個側載 App。可以刪掉不用的側載 App，或把捲字裝進 LiveContainer 裡。
- **安裝卡住或失敗**：確認 LocalDevVPN 有連線、手機連著 Wi-Fi，再試一次。
- **更新捲字**：新版出來時再按一次新版的一鍵安裝連結，直接覆蓋，學習紀錄都會留著。

這份教學也放在 [`docs/iPhone安裝教學.md`](docs/iPhone安裝教學.md)。

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

## 授權

程式碼以 [PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0) 授權（全文見 `LICENSE`）：可以免費使用、修改和分享，但不能用在商業用途。下方列出的單字資料、字表和圖示，仍各自依原本的授權使用。

## 資料來源與授權

- 大考詞彙與分級：大學入學考試中心《高中英文參考詞彙表》（111 學年度起適用），僅供非營利學習使用。
- 國中小 1200：教育部《十二年國民基本教育課程綱要 語文領域－英語文》附錄五表一「基本 1,200 字」。
- 多益：[TOEIC Service List 1.2](https://newgeneralservicelist.com/toeic-service-list)（Browne, C. \& Culligan, B.），[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)；`words.json` 中由它而來的 `toeic` 標記同樣以 CC BY-SA 4.0 釋出。
- 雅思、托福字表，以及中文解釋與音標：整理自 [ECDICT](https://github.com/skywind3000/ECDICT)（MIT License），並轉為繁體中文（台灣用語），內容可能有誤。
- 圖示：Apple SF Symbols（iPhone）、Material Icons（Android，Apache 2.0）。
- 學習資料預設只存在自己的裝置上；登入帳號後會同步到 JuanGo 的 Supabase 專案（每個人只能讀寫自己的資料，分享清單只能用代碼取得，資料表與權限規則見 `supabase/schema.sql`）。打開 API 翻譯並設定 key 後，字典沒有的單字會傳到該 API 的伺服器翻譯；key 存在裝置的鑰匙圈，不在程式碼裡。

這是一個高中自主學習專案。
