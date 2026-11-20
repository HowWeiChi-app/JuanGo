import SwiftUI

/// Settings › 關於與授權: where the word lists and exam questions come from, their licences, and privacy.
struct AboutView: View {
    private struct Source {
        let title: String
        let body: String
        let links: [(String, String)]
    }

    private static let ceec = ("大考中心網站", "https://www.ceec.edu.tw")
    private static let sources: [Source] = [
        Source(title: "大考詞彙與分級",
               body: "大學入學考試中心《高中英文參考詞彙表》（111 學年度起適用），僅供非營利學習使用。",
               links: [ceec]),
        Source(title: "學測英文考古題",
               body: "大學入學考試中心公布的 113 到 115 學年度學科能力測驗英文考科試題與參考答案，僅供學習使用。",
               links: [ceec]),
        Source(title: "國中小 1200",
               body: "教育部《十二年國民基本教育課程綱要 語文領域－英語文》附錄五表一「基本 1,200 字」。",
               links: []),
        Source(title: "多益",
               body: "TOEIC Service List 1.2，作者 Browne, C. 與 Culligan, B.，以 CC BY-SA 4.0 授權。捲字裡由它而來的多益標記同樣以 CC BY-SA 4.0 提供。",
               links: [("TOEIC Service List", "https://newgeneralservicelist.com/toeic-service-list"),
                       ("CC BY-SA 4.0", "https://creativecommons.org/licenses/by-sa/4.0/")]),
        Source(title: "雅思、托福、中文解釋與音標",
               body: "整理自 ECDICT（作者 skywind3000），MIT 授權，並轉成繁體中文（台灣用語）。內容可能有誤，可以在單字頁自己修改。",
               links: [("ECDICT", "https://github.com/skywind3000/ECDICT")]),
        Source(title: "圖示與字型",
               body: "Apple SF Symbols 和 Apple 系統字型。",
               links: []),
    ]

    var body: some View {
        Form { Group {
            Section {
                Text("大考詞彙、分級和學測考古題永遠免費，不受任何付費限制。捲字 Pro 收的是 App 功能的費用，不是這些內容的費用。")
                    .font(.app(.subheadline))
            }
            Section("資料來源與授權") {
                ForEach(Self.sources, id: \.title) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.title).font(.app(.subheadline, .semibold))
                        Text(s.body).font(.app(.footnote)).foregroundStyle(.secondary)
                        if !s.links.isEmpty {
                            HStack(spacing: 16) {
                                ForEach(s.links, id: \.0) { Link($0.0, destination: URL(string: $0.1)!) }
                            }
                            .font(.app(.footnote, .semibold))
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Link("隱私權政策", destination: ProStore.privacyURL)
                Link("服務條款", destination: ProStore.termsURL)
                Link("原始碼（GitHub）", destination: URL(string: "https://github.com/HowWeiChi-app/JuanGo")!)
            } header: { Text("隱私") } footer: {
                Text("學習資料預設只存在這台裝置；登入後會同步到雲端，每個人只能讀寫自己的資料。設定自訂 API 後，字典沒有的字會傳到該 API 翻譯。")
            }
        }.listRowBackground(Color.cardFill) }
        .themedBackground()
        .navigationTitle("關於與授權")
    }
}
