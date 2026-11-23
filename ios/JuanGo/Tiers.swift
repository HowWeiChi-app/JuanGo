// 段位詳細：自己的勝率和名次百分比、這個賽季的分數分布、各段位的人數和平均勝率。
// 點單字對戰首頁戰績卡上的段位名稱打開。和 Android 版 app/lib/battle.dart 的 TierDetailPage 相同。
// 伺服器端是 supabase/battle_social.sql 的 battle_tier_detail（只回統計數字，不回任何人的名字）。

import SwiftUI

struct TierDetail: Decodable {
    struct Tier: Decodable, Identifiable {
        var index: Int, name: String, from: Int
        var next: Int?
        var win: Int, loss: Int, players: Int
        /// 賽季結束時停在這個段位，下賽季從幾分開始
        var reset: Int?
        var winRate: Double?
        /// 這個段位的真人還不多，勝率是理論值（loss ÷ (win + loss)）
        var estimated: Bool?
        var id: Int { index }
    }
    struct Bucket: Decodable { var from: Int, n: Int }
    struct Me: Decodable {
        var rating: Int, games: Int, wins: Int, losses: Int, draws: Int
        var winRate: Double
        var percentile: Double?
    }
    var season: String?
    /// 這個賽季最後一天，例如 "2026-12-31"
    var seasonEnd: String?
    var players: Int
    var tiers: [Tier]
    var histogram: [Bucket]
    var me: Me?

    /// 1 是最低的段位；用和伺服器一樣的規則（from 小於等於積分的最後一個）
    func tier(of rating: Int) -> Int { (tiers.lastIndex { rating >= $0.from } ?? 0) + 1 }

    #if DEBUG
    /// 示範模式（截圖用，數字是假的），和 Android 版 demoTierDetail 相同
    static let demo = TierDetail(season: "2026 S6", seasonEnd: "2026-12-31", players: 214, tiers: [
        Tier(index: 1, name: "尊貴鉑金", from: 0, next: 1100, win: 28, loss: 14, players: 52, reset: 900, winRate: 0.333, estimated: true),
        Tier(index: 2, name: "永恆鑽石", from: 1100, next: 1200, win: 25, loss: 17, players: 61, reset: 1000, winRate: 0.405, estimated: true),
        Tier(index: 3, name: "至尊星耀", from: 1200, next: 1400, win: 20, loss: 20, players: 58, reset: 1100, winRate: 0.5, estimated: true),
        Tier(index: 4, name: "無雙卷哥", from: 1400, next: 1600, win: 18, loss: 22, players: 27, reset: 1200, winRate: 0.55, estimated: true),
        Tier(index: 5, name: "璀璨卷王", from: 1600, next: 1800, win: 16, loss: 24, players: 12, reset: 1300, winRate: 0.6, estimated: true),
        Tier(index: 6, name: "傳奇卷神", from: 1800, next: nil, win: 15, loss: 25, players: 4, reset: 1400, winRate: 0.625, estimated: true),
    ], histogram: [(900, 6), (950, 9), (1000, 15), (1050, 22), (1100, 30), (1150, 31), (1200, 27), (1250, 18),
                   (1300, 9), (1350, 4), (1400, 10), (1450, 8), (1500, 5), (1550, 4), (1600, 5), (1650, 4),
                   (1700, 2), (1750, 1), (1800, 2), (1850, 2)].map { Bucket(from: $0.0, n: $0.1) },
    me: Me(rating: 1218, games: 12, wins: 7, losses: 4, draws: 1, winRate: 0.583, percentile: 0.551))
    #endif
}

struct TierDetailView: View {
    let model: BattleModel
    @State private var detail: TierDetail?
    @State private var failed: String?

    private static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }

    var body: some View {
        List { Group {
            if let d = detail {
                content(d)
            } else if let failed {
                Section {
                    Button("讀不到段位資料，再試一次") { Task { await load() } }
                    Text(failed).font(.app(.footnote)).foregroundStyle(.secondary)
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
            }
        }.listRowBackground(Color.cardFill) }
        .font(.app(.body))
        .themedBackground()
        .navigationTitle("段位")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { detail = try await model.tierDetail(); failed = nil } catch { failed = BattleModel.clean(error) }
    }

    @ViewBuilder private func content(_ d: TierDetail) -> some View {
        let rating = d.me?.rating ?? model.me?.rating
        let myTier = rating.map { d.tier(of: $0) }
        let mine = myTier.flatMap { t in d.tiers.first { $0.index == t } }
        // "2026-12-31" → "12/31"
        let end: String? = d.seasonEnd.flatMap { s in
            let p = s.split(separator: "-").compactMap { Int($0) }
            return p.count == 3 ? "\(p[1])/\(p[2])" : nil
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(mine?.name ?? model.me.map { tierText($0.tierName, $0.tier) } ?? "")
                    .font(.app(.title2, .bold)).foregroundStyle(Color.themeAccent)
                if let rating { Text(verbatim: "\(rating) 分").font(.app(.headline)) }
                if let me = d.me {
                    HStack(alignment: .top) {
                        stat("我的勝率", Self.pct(me.winRate))
                        stat("贏過玩家", Self.pct(me.percentile))
                    }
                    .padding(.top, 10)
                }
                if let reset = mine?.reset {
                    Text(verbatim: "下賽季從 \(reset) 分開始")
                        .font(.app(.subheadline)).foregroundStyle(.secondary)
                        .padding(.top, 10)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("\(d.season ?? "") 我的段位".trimmingCharacters(in: .whitespaces))
        }

        // 分數分布併在這裡：每個段位占全部玩家（含電腦）的比例。勝率在真人不夠多時是理論值，前面加「約」
        Section("各段位詳細資料") {
            ForEach(d.tiers) { t in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).foregroundStyle(t.index == myTier ? Color.themeAccent : .primary)
                        Text(verbatim: "\(t.next.map { "\(t.from)–\($0 - 1) 分" } ?? "\(t.from) 分以上")・占 \(d.players == 0 ? "—" : Self.pct(Double(t.players) / Double(d.players)))")
                            .font(.app(.footnote)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(verbatim: "勝率 \(t.estimated == true ? "約 " : "")\(Self.pct(t.winRate))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }

        // 重置分數：和伺服器的 battle_season_reset 同一條規則（依賽季最後的積分所在段位）
        Section {
            ForEach(d.tiers.filter { $0.reset != nil }) { t in
                HStack {
                    Text(t.name).foregroundStyle(t.index == myTier ? Color.themeAccent : .primary)
                    Spacer()
                    Text(verbatim: "\(t.reset ?? 0) 分").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text(verbatim: end.map { "賽季重置（\($0)）" } ?? "賽季重置")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.app(.footnote)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.app(size: 28, .bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

