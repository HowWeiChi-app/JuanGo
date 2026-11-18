// 官網截圖用的展示模式，由 tools/capture_screens.sh 用 --dart-define=DEMO=true 編譯。
// 一般編譯時 demoOn 是 false，下面的設定不會進到 App。展示版另用 .demo 套件 ID，碰不到平常使用的捲字。

const demoOn = bool.fromEnvironment('DEMO');

/// 探索頁第一張卡片的單字
const demoFirstWord = String.fromEnvironment('DEMO_FIRST');
