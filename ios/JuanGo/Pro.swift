import SwiftUI
import StoreKit

// MARK: - Build flags

nonisolated enum DevFlags {
    /// The dev build (the local battle branch) has every paid feature unlocked as GOs PRO. Always false on main.
    static let gosPro = true
}

// MARK: - Plans

/// 捲字 Pro unlocks this app; GOs PRO unlocks every HowWeiChi app, including ones released later.
enum ProPlan: String, CaseIterable, Identifiable {
    case juango, gos
    var id: String { rawValue }
    var name: String { self == .gos ? "GOs PRO" : "捲字 Pro" }
    var blurb: String { self == .gos ? "捲字與 GOs PRO 合作服務" : "只有捲字" }
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

/// The plans folded under 更多方案: they don't renew.
enum ProExtra: String, CaseIterable, Identifiable {
    /// 180 天大考衝刺包: a non-renewing subscription on iOS (a prepaid plan on Google Play); bought again, the days add up
    case pass180
    /// 火星贊助者: a consumable tip that unlocks nothing but the 🚀 badge, and can be bought again
    case tipMars
    var id: String { rawValue }
    var productID: String { self == .pass180 ? "juango_pass_180" : "juango_tip_mars" }
    var name: String { self == .pass180 ? "180 天大考衝刺包" : "火星贊助者" }
    var price: Int { self == .pass180 ? 300 : 30 }
    var blurb: String {
        self == .pass180 ? "捲字 Pro 180 天，不自動續訂，沒有試用。再買一次天數會往後加。"
                         : "單次贊助，不解鎖功能，獲得「🚀 火星贊助者」徽章，可以重複贊助。"
    }
}

// MARK: - Status

/// The paid features that already exist, each of which the dev build can switch off (開發者選項).
enum ProFeature: String, CaseIterable, Identifiable {
    case words, battles, textbook
    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: "「我的單字」不限個數"
        case .battles: "單字對戰不限場次"
        case .textbook: "課文書架不限課數和 AI 修正"
        }
    }
}

/// What the player owns. Purchases will come through RevenueCat (entitlement `juango_pro`, unlocked by
/// `juango_pro_*` and `gos_pro_*`); until the store is set up, buying and restoring report that it isn't open yet.
@MainActor @Observable
final class ProStore {
    static let shared = ProStore()

    /// the plan bought in the store (RevenueCat, not connected yet)
    private var bought: ProPlan?
    /// what the account has: the dev build's GOs PRO while signed in, otherwise what was bought
    var plan: ProPlan? { devUnlocked ? .gos : bought }
    private(set) var period: ProPeriod?
    private(set) var expires: Date?
    /// The dev build unlocks Pro for the signed-in account only: signing out locks every Pro feature again,
    /// with the dev texts and 開發者選項 hidden, exactly like the free version.
    var devUnlocked: Bool { DevFlags.gosPro && Cloud.shared.signedIn }

    var isPro: Bool { plan != nil }

    /// features switched off in 開發者選項, to try the free version without leaving the dev build
    private(set) var devOff: Set<ProFeature> = Set((UserDefaults.standard.stringArray(forKey: "dev.proOff") ?? []).compactMap(ProFeature.init))

    func has(_ f: ProFeature) -> Bool { isPro && !devOff.contains(f) }

    func setDev(_ f: ProFeature, on: Bool) {
        if on { devOff.remove(f) } else { devOff.insert(f) }
        UserDefaults.standard.set(devOff.map(\.rawValue), forKey: "dev.proOff")
        // the daily battle limit is counted on the server, for test accounts listed in battle_unlimited
        if f == .battles { Task { _ = try? await Cloud.shared.rpc("battle_dev_limit", ["p_paused": !on], timeout: 10) } }
    }

    struct NotOpen: LocalizedError {
        var errorDescription: String? { "商店還沒開通，App 上架後就能訂閱。" }
    }

    private init() {}

    /// Whether this Apple Account can still get the 7-day free trial. One trial per subscription group for life,
    /// so the paywall shows 免費試用 only when StoreKit says yes (App Store Guideline 3.1.2); while the products
    /// aren't in App Store Connect yet this stays false.
    private(set) var introEligible = false

    func checkIntroEligibility() async {
        let ids = ProPlan.allCases.flatMap { p in ProPeriod.allCases.map { p.productID($0) } }
        guard let products = try? await Product.products(for: ids), !products.isEmpty else { introEligible = false; return }
        var eligible = false
        for p in products where p.subscription?.introductoryOffer != nil {
            if await p.subscription?.isEligibleForIntroOffer == true { eligible = true; break }
        }
        introEligible = eligible
    }

    func purchase(_ plan: ProPlan, _ period: ProPeriod) async throws { throw NotOpen() }
    func purchase(_ extra: ProExtra) async throws { throw NotOpen() }
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
    @State private var moreOpen = false
    /// after a purchase while signed out: offer to sign in so Pro also unlocks on the other platform
    @State private var offerSync = false
    @State private var signingIn = false
    private var pro: ProStore { .shared }
    /// the plan bought; the dev build's unlock is left out so the paywall shows in full for demos
    private var held: ProPlan? { pro.devUnlocked ? nil : pro.plan }
    private var trial: Bool { pro.introEligible && held == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    if held == .gos {
                        owned
                    } else {
                        Picker("週期", selection: $period) {
                            Text("月繳").tag(ProPeriod.monthly)
                            Text("年繳").tag(ProPeriod.yearly)
                        }
                        .pickerStyle(.segmented)
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(ProPlan.allCases) { card($0) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Text("解鎖捲字 Pro 與 GOs PRO 合作服務完整功能，並享有未來新服務優先體驗權。")
                            .font(.app(.footnote)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    features
                    if held != .gos { buy }
                    more
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
            .alert("要同步到其他裝置嗎？", isPresented: $offerSync) {
                Button("登入 Email") { signingIn = true }
                Button("之後再說", role: .cancel) {}
            } message: {
                Text("若需在 iPhone 與 Android 之間同步 Pro 資格（含 GOs PRO 套裝）與學習進度，請登入 Email 帳號綁定。")
            }
            .sheet(isPresented: $signingIn) { NavigationStack { AccountView() } }
            .offerCodeRedemption(isPresented: $redeeming) { _ in }
            .onAppear { if held == .juango { plan = .gos } }
            .task { await pro.checkIntroEligibility() }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            LIcon("sparkles").font(.app(size: 40, .bold)).foregroundStyle(Color.themeAccent)
            Text(held == .juango ? "升級到 GOs PRO" : "解鎖捲字 Pro").font(.app(.title, .bold))
            Text("大考詞彙和考古題永遠免費，捲字 Pro 包含額外進階功能。")
                .font(.app(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var owned: some View {
        VStack(spacing: 6) {
            Text("你已經有 GOs PRO").font(.app(.headline))
            Text(pro.devUnlocked ? "開發版已解鎖所有 Pro 功能。" : "捲字 Pro 與 GOs PRO 合作服務的完整功能都能使用。")
                .font(.app(.subheadline)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.cardFill))
    }

    private func card(_ p: ProPlan) -> some View {
        let selected = plan == p
        let current = held == p
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
                Spacer(minLength: 6)
                Text("NT$\(price)").font(.app(size: 26, .bold)).monospacedDigit()
                Text(period == .yearly ? "每年・約 NT$\(price / 12) / 月" : "每月").font(.app(.caption)).foregroundStyle(.secondary)
                if current {
                    Text("目前方案").font(.app(.caption, .bold)).foregroundStyle(Color.themeAccent)
                } else if trial {
                    Text("7 天免費試用").font(.app(.caption, .bold)).foregroundStyle(Color.themeAccent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            feature("infinity", "「我的單字」不限個數", "免費版最多 1000 個")
            feature("character.bubble", "AI 智慧引擎", "無上限智慧例句生成、課文掃描自動校對與免填 Key 翻譯")
            feature("bolt.fill", "單字對戰不限場次", "免費版每天 10 場")
            feature("books.vertical.fill", "課文書架不限課數", "掃描課文變成電子書，免費版可試用 1 課（最多 3 頁）")
            feature("chart.bar.xaxis", "進階統計", "每週報告、常錯字、學測詞彙涵蓋率")
            feature("paintpalette.fill", "額外主題色和 App 圖示", "即將推出")
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

    private func run(_ f: @escaping () async throws -> Void) {
        busy = true
        Task {
            do {
                try await f()
                if !Cloud.shared.signedIn { offerSync = true }
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private var buy: some View {
        VStack(spacing: 8) {
            Button { run { try await pro.purchase(plan, period) } } label: {
                Text(held == .juango ? "升級到 GOs PRO" : trial ? "免費試用 7 天" : "訂閱 \(plan.name)")
            }
            .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
            .disabled(busy)
            Text(held == .juango ? "改成 NT$\(plan.price(period)) / \(period.unit)，剩下的捲字 Pro 費用由 App Store 按比例退還。"
                 : trial ? "試用 7 天後 NT$\(plan.price(period)) / \(period.unit)，自動續訂。"
                 : "NT$\(plan.price(period)) / \(period.unit)，自動續訂。")
                .font(.app(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    /// 更多方案, folded by default so the paywall stays two choices
    private var more: some View {
        DisclosureGroup(isExpanded: $moreOpen) {
            VStack(spacing: 12) {
                ForEach(ProExtra.allCases) { e in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.name).font(.app(.subheadline, .semibold))
                            Text(e.blurb).font(.app(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("NT$\(e.price)") { run { try await pro.purchase(e) } }
                            .font(.app(.subheadline, .bold)).buttonStyle(.bordered).tint(Color.themeAccent)
                            .disabled(busy)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Text("更多方案").font(.app(.subheadline, .semibold))
        }
        .tint(.primary)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.cardFill))
    }

    private var extras: some View {
        HStack(spacing: 22) {
            Button("恢復購買") { run { try await pro.restore() } }
            Button("有兌換碼？") { redeeming = true }
        }
        .font(.app(.subheadline, .semibold))
    }

    private var legal: some View {
        VStack(spacing: 8) {
            Text((trial ? "首次訂閱可免費試用 7 天，試用結束才開始扣款。" : "")
                 + "月繳和年繳會自動續訂：目前期間結束前 24 小時內自動扣款續訂，可隨時在 iPhone 的「設定 › Apple 帳號 › 訂閱項目」取消。180 天大考衝刺包和火星贊助者不會自動扣款。")
            Text("Pro 到期後不會刪除任何單字：超過 1000 個時暫停新增，原有單字照常瀏覽和複習。")
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
                if pro.plan != .gos || pro.devUnlocked {
                    Button(pro.devUnlocked ? "查看付費牆（展示用）" : pro.plan == .juango ? "升級到 GOs PRO" : "查看 Pro 方案") { paywall = true }
                }
                if pro.isPro && !pro.devUnlocked {
                    Button("管理訂閱") { managing = true }
                }
            } footer: {
                Text("大考詞彙和學測考古題不受付費限制。")
            }
            if pro.devUnlocked {
                Section {
                    ForEach(ProFeature.allCases) { f in
                        Toggle(f.title, isOn: Binding(get: { !pro.devOff.contains(f) }, set: { pro.setDev(f, on: $0) }))
                    }
                    Button(pro.devOff.count == ProFeature.allCases.count ? "全部打開" : "全部關閉") {
                        let on = pro.devOff.count == ProFeature.allCases.count
                        for f in ProFeature.allCases { pro.setDev(f, on: on) }
                    }
                } header: {
                    Text("開發者選項")
                } footer: {
                    Text("關掉的功能會照免費版運作，方便測試。對戰場次只對測試帳號有效。開發版的 Pro 綁在登入的帳號上，登出就恢復免費版。")
                }
                Section {
                    NavigationLink { DevLogView() } label: { Label("Log 紀錄", pulso: "doc.text.magnifyingglass") }
                    NavigationLink { DevReportView() } label: { Label("回報問題", pulso: "exclamationmark.bubble") }
                } footer: {
                    Text("Log 只存在這支手機，按「回報問題」送出時才會連同你的說明一起上傳。")
                }
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
