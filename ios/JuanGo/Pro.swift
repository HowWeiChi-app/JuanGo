import SwiftUI
import StoreKit

// MARK: - Build flags

enum DevFlags {
    /// The dev build (the local battle branch) has every paid feature unlocked as GOs PRO. Always false on main.
    static let gosPro = false
}

// MARK: - Plans

/// 捲字 Pro unlocks this app; GOs PRO unlocks every HowWeiChi app, including ones released later.
enum ProPlan: String, CaseIterable, Identifiable {
    case juango, gos
    var id: String { rawValue }
    var name: String { self == .gos ? "GOs PRO" : "捲字 Pro" }
    var blurb: String { self == .gos ? "捲字、校板和未來所有 App" : "只有捲字" }
    func price(_ p: ProPeriod) -> Int {
        switch (self, p) {
        case (.juango, .monthly): 60
        case (.juango, .yearly): 600
        case (.gos, .monthly): 80
        case (.gos, .yearly): 800
        }
    }
    /// the store product ID (the same on the App Store and Google Play)
    func productID(_ p: ProPeriod) -> String { "\(self == .gos ? "gos" : "juango")_pro_\(p.rawValue)" }
}

enum ProPeriod: String, CaseIterable, Identifiable {
    case monthly, yearly
    var id: String { rawValue }
    var unit: String { self == .yearly ? "年" : "月" }
}

// MARK: - Status

/// What the player owns. Purchases will come through RevenueCat (entitlement `juango_pro`, unlocked by
/// `juango_pro_*` and `gos_pro_*`); until the store is set up, buying and restoring report that it isn't open yet.
@MainActor @Observable
final class ProStore {
    static let shared = ProStore()

    private(set) var plan: ProPlan?
    private(set) var period: ProPeriod?
    private(set) var expires: Date?
    /// unlocked by the dev build rather than bought
    private(set) var devUnlocked = false

    var isPro: Bool { plan != nil }

    struct NotOpen: LocalizedError {
        var errorDescription: String? { "商店還沒開通，App 上架後就能訂閱。" }
    }

    private init() {
        if DevFlags.gosPro {
            plan = .gos
            devUnlocked = true
        }
    }

    func purchase(_ plan: ProPlan, _ period: ProPeriod) async throws { throw NotOpen() }
    func restore() async throws { throw NotOpen() }

    static let termsURL = URL(string: "https://howweichi-app.github.io/terms/")!
    static let privacyURL = URL(string: "https://howweichi-app.github.io/privacy/")!
}

// MARK: - Paywall

struct ProPaywall: View {
    @Environment(\.dismiss) private var dismiss
    @State private var plan = ProPlan.gos
    @State private var period = ProPeriod.yearly
    @State private var busy = false
    @State private var message: String?
    @State private var redeeming = false
    private var pro: ProStore { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if pro.plan == .gos {
                        owned
                    } else {
                        Picker("週期", selection: $period) {
                            Text("月繳").tag(ProPeriod.monthly)
                            Text("年繳・送 2 個月").tag(ProPeriod.yearly)
                        }
                        .pickerStyle(.segmented)
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(ProPlan.allCases) { card($0) }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("訂閱 GOs PRO，包含所有未來推出的 App。")
                            Text("現在是早鳥優惠價 NT$800／年（NT$80／月），只用捲字和校板也比分開買兩個 Pro 便宜。之後推出更多 App 時，新訂閱的價格會調高；早鳥期間訂閱的人，只要不中斷，續訂都維持早鳥價。")
                        }
                        .font(.app(.footnote)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    features
                    if pro.plan != .gos { buy }
                    extras
                    legal
                }
                .padding(20)
            }
            .themedBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
            .alert("無法完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(message ?? "") }
            .offerCodeRedemption(isPresented: $redeeming) { _ in }
            .onAppear { if pro.plan == .juango { plan = .gos } }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            LIcon("sparkles").font(.app(size: 40, .bold)).foregroundStyle(Color.themeAccent)
            Text(pro.plan == .juango ? "升級到 GOs PRO" : "解鎖捲字 Pro").font(.app(.title, .bold))
            Text("大考詞彙和學測考古題永遠免費，Pro 收的是 App 功能的費用。")
                .font(.app(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var owned: some View {
        VStack(spacing: 6) {
            Text("你已經有 GOs PRO").font(.app(.headline))
            Text(pro.devUnlocked ? "開發版已解鎖所有 Pro 功能。" : "捲字、校板和之後推出的 App 都能用 Pro 功能。")
                .font(.app(.subheadline)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.cardFill))
    }

    private func card(_ p: ProPlan) -> some View {
        let selected = plan == p
        let current = pro.plan == p
        let price = p.price(period)
        return Button { if !current { plan = p } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(p.name).font(.app(.headline))
                    Spacer(minLength: 4)
                    if p == .gos && !current {
                        Text("推薦").font(.app(.caption2, .bold)).foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.themeAccent))
                    }
                }
                Text(p.blurb).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text("NT$\(price)").font(.app(size: 26, .bold)).monospacedDigit()
                Text(period == .yearly ? "每年・約 NT$\(price / 12) / 月" : "每月").font(.app(.caption)).foregroundStyle(.secondary)
                if p == .gos && !current { Text("早鳥優惠價").font(.app(.caption, .bold)).foregroundStyle(Color.themeAccent) }
                if current { Text("目前方案").font(.app(.caption, .bold)).foregroundStyle(Color.themeAccent) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(selected ? Color.themeAccent : .clear, lineWidth: 2.5))
            .opacity(current ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            feature("infinity", "「我的單字」不限個數", "免費版最多 1000 個，大考詞彙不算")
            feature("character.bubble", "內建 AI 翻譯與例句", "不用自己填 API key")
            feature("bolt.fill", "單字對戰不限場次", "免費版每天 3 場")
            feature("chart.bar.xaxis", "進階統計", "每週報告、常錯字、學測詞彙涵蓋率")
            feature("paintpalette.fill", "額外主題色和 App 圖示", "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.cardFill))
    }

    private func feature(_ icon: String, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            LIcon(icon).font(.app(.body, .semibold)).foregroundStyle(Color.themeAccent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(.subheadline, .semibold))
                if !sub.isEmpty { Text(sub).font(.app(.caption)).foregroundStyle(.secondary) }
            }
        }
    }

    private var buy: some View {
        VStack(spacing: 8) {
            Button {
                busy = true
                Task {
                    do { try await pro.purchase(plan, period) } catch { message = error.localizedDescription }
                    busy = false
                }
            } label: {
                Text(pro.plan == .juango ? "升級到 GOs PRO" : "免費試用 7 天")
            }
            .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
            .disabled(busy)
            Text(pro.plan == .juango ? "改成 NT$\(plan.price(period)) / \(period.unit)，剩下的捲字 Pro 費用由 App Store 按比例退還。"
                 : "試用結束後 NT$\(plan.price(period)) / \(period.unit)，自動續訂。")
                .font(.app(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var extras: some View {
        HStack(spacing: 22) {
            Button("恢復購買") {
                Task { do { try await pro.restore() } catch { message = error.localizedDescription } }
            }
            Button("有兌換碼？") { redeeming = true }
        }
        .font(.app(.subheadline, .semibold))
    }

    private var legal: some View {
        VStack(spacing: 8) {
            Text("訂閱會自動續訂。首次訂閱可免費試用 7 天，試用結束才開始扣款。目前週期結束前 24 小時沒有取消就會續訂，可以隨時在 iPhone 的「設定 › Apple 帳號 › 訂閱項目」取消。")
            Text("Pro 到期後，超過 1000 個的單字會在 30 天後從最早加入的開始刪除，刪除前會通知你。")
            HStack(spacing: 16) {
                Link("服務條款", destination: ProStore.termsURL)
                Link("隱私權政策", destination: ProStore.privacyURL)
            }
            .font(.app(.footnote, .semibold))
        }
        .font(.app(.caption)).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
}

// MARK: - Settings › Pro

struct ProSettingsView: View {
    @State private var paywall = false
    @State private var managing = false
    private var pro: ProStore { .shared }

    var body: some View {
        Form { Group {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pro.plan?.name ?? "免費版").font(.app(.title2, .bold))
                    Text(status).font(.app(.subheadline)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                if pro.plan != .gos {
                    Button(pro.plan == .juango ? "升級到 GOs PRO" : "查看 Pro 方案") { paywall = true }
                }
                if pro.isPro && !pro.devUnlocked {
                    Button("管理訂閱") { managing = true }
                }
            } footer: {
                Text("大考詞彙和學測考古題不受付費限制。")
            }
        }.listRowBackground(Color.cardFill) }
        .themedBackground()
        .navigationTitle("捲字 Pro")
        .sheet(isPresented: $paywall) { ProPaywall() }
        .manageSubscriptionsSheet(isPresented: $managing)
    }

    private var status: String {
        if pro.devUnlocked { return "開發版：已解鎖所有 Pro 功能" }
        guard let plan = pro.plan else { return "「我的單字」最多 1000 個，大考詞彙不算" }
        let renew = pro.expires.map { "・\($0.formatted(.dateTime.year().month().day().locale(.zh))) 續訂" } ?? ""
        return "\(plan.blurb)\(renew)"
    }
}
