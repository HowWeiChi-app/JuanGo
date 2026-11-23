# 用 SideInstaller 在 iPhone 安裝捲字 JuanGo

捲字還沒有上架 App Store，所以要用「側載」的方式安裝：用你自己的 Apple 帳號替 App 簽名，再裝到 iPhone 上。SideInstaller 是一個免費、開放原始碼的工具，可以直接在 iPhone 上完成這件事，大部分情況不需要電腦。

第一次大約要 20～30 分鐘，之後更新捲字只要按一下連結。

## 先確認這幾件事

- **iPhone 的系統版本**：到「設定 › 一般 › 關於本機」看「iOS 版本」。捲字需要 **iOS 26 以上**。
  - iOS 27 以上：照下面的「A. iOS 27 以上（不用電腦）」做。
  - iOS 26：要先借用一台電腦做一次「配對檔」，照「B. iOS 26（要電腦一次）」做。
- **Wi-Fi**：第一次安裝要連 Wi-Fi。
- **Apple 帳號**：就是你登入 App Store 的帳號和密碼，免費帳號就可以。密碼只在你的手機上用來簽名，不會傳給捲字或 SideInstaller 的作者。
- **只從官方來源下載 SideInstaller**：官方網站是 [sideinstaller.net](https://sideinstaller.net/)，程式碼在 [GitHub](https://github.com/FrizzleM/SideInstaller)。**sideinstaller.com 是假網站**，可能會偷你的 Apple 帳號，不要用。

## A. iOS 27 以上（不用電腦）

### 第 1 步：從 App Store 下載兩個免費 App

| App | 用途 | 下載 |
| --- | --- | --- |
| Open Minis（1.16 以上） | 在手機上跑安裝 SideInstaller 的指令 | [App Store](https://apps.apple.com/app/id6759188481) |
| LocalDevVPN | 讓手機自己連到自己，安裝時要開著 | [App Store](https://apps.apple.com/app/id6755608044) |

### 第 2 步：打開開發者模式和定位權限

1. 到「設定 › 隱私權與安全性 › 開發者模式」，把開關打開，手機會要求重新開機。
2. 到「設定 › App › Open Minis › 位置」，選「永遠」。這只是讓 Open Minis 在背景繼續跑，不會收集你的位置。

### 第 3 步：在 Open Minis 安裝 SideInstaller

1. 在 iPhone 用 Safari 打開 [sideinstaller.net/install.html](https://sideinstaller.net/install.html)，看過並同意使用條款。
2. 打開 LocalDevVPN，按連線，讓它保持連線。
3. 打開 Open Minis，點右上角的終端機圖示，再點 **Shell Terminal**，會出現一個可以打字的畫面（終端機）。
4. 貼上這一行，按鍵盤上的「換行」執行：

   ```sh
   wget -qO- https://raw.githubusercontent.com/FrizzleM/siboot/main/minis/install.sh | sh
   ```

5. 照畫面上的說明做。手機會跳出一組配對碼，到「設定」出現的配對提示裡輸入；接著依序輸入你的 **Apple 帳號 email**、**密碼**，和手機或其他 Apple 裝置收到的 **6 位數驗證碼**。
6. 畫面說完成之前不要切走 Open Minis。
7. 到「設定 › 一般 › VPN 與裝置管理」，點你的 Apple 帳號，按「信任」。

### 第 4 步：用 SideInstaller 安裝 SideStore

1. 確認 LocalDevVPN 還是連線中。
2. 打開 SideInstaller，登入你的 Apple 帳號。
3. 點 **Install SideStore**（只裝 SideStore）或 **Install SideStore + LiveContainer**。

### 第 5 步：安裝捲字

1. 確認 LocalDevVPN 連線中。
2. 在 iPhone 用 Safari 打開這個連結：**[一鍵安裝捲字 JuanGo 0.2.0](https://sideinstaller.net/open.html?url=https%3A%2F%2Fgithub.com%2FHowWeiChi-app%2FJuanGo%2Freleases%2Fdownload%2Fv0.2.0%2FJuanGo-0.2.0.ipa)**
3. 網頁會顯示安裝檔來自 `github.com/HowWeiChi-app/JuanGo`，然後打開 SideInstaller。如果沒有自動打開，按網頁上的按鈕。
4. SideInstaller 問要不要安裝時按確定，等它下載、簽名、安裝完成，主畫面就會出現捲字。

也可以在 SideStore 或 LiveContainer 裡自己貼上安裝檔網址：

```text
https://github.com/HowWeiChi-app/JuanGo/releases/download/v0.2.0/JuanGo-0.2.0.ipa
```

## B. iOS 26（要電腦一次）

iOS 26 的 iPhone 要先用電腦做一個「配對檔」，之後就可以在手機上完成。

1. **安裝 SideInstaller**：在 iPhone 用 Safari 打開 [sideinstaller.net/install.html](https://sideinstaller.net/install.html)，展開最下面的 **Legacy（Enterprise certificates）**：先安裝 DNS 描述檔，並在「設定 › 一般 › VPN 與裝置管理 › DNS」選 SideInstaller；再按其中一個憑證的 **Install**，到「設定 › 一般 › VPN 與裝置管理」信任它（打不開就換另一個）。裝好 SideStore 之後，記得把 DNS 描述檔刪掉。
2. **在電腦做配對檔**：
   - iOS 26.4 以上：在 Mac 或 Windows 電腦下載 [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases/latest)，用線把 iPhone 接上電腦，iPhone 問要不要信任這台電腦時按「信任」。在 idevice_pair 選你的 iPhone，選 **Remote pairing**，按 **Create**，完成前 iPhone 不要鎖定，再按 **Save to file…** 存檔。
   - iOS 26.0～26.3：照 [SideStore 的配對檔說明](https://docs.sidestore.io/docs/advanced/alternative#pairing) 做。
3. 用 AirDrop、iCloud 雲碟或傳輸線把配對檔傳到 iPhone。
4. 從 App Store 安裝 [LocalDevVPN](https://apps.apple.com/app/id6755608044) 並連線。
5. 打開 SideInstaller，點 **Import pairing file**，選剛才的配對檔。
6. 到「設定 › 一般 › VPN 與裝置管理」信任 SideInstaller 的憑證，再接著做上面 A 的**第 4 步和第 5 步**。

## 常見問題

- **App 打不開，說「不受信任的開發者」**：到「設定 › 一般 › VPN 與裝置管理」，點你的 Apple 帳號，按「信任」。
- **7 天後打不開**：免費 Apple 帳號簽的 App 只能用 7 天。打開 SideStore 按重新整理（Refresh），或再按一次上面的一鍵安裝連結就好，學習紀錄不會消失。
- **說 App 數量已滿**：免費 Apple 帳號同時只能裝 3 個側載 App。可以刪掉不用的側載 App，或把捲字裝進 LiveContainer 裡。
- **安裝卡住或失敗**：確認 LocalDevVPN 有連線、手機連著 Wi-Fi，再試一次。
- **更新捲字**：新版出來時再按一次新版的一鍵安裝連結，直接覆蓋，學習紀錄都會留著。
