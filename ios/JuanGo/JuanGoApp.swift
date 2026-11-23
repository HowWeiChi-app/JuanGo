import SwiftUI
import SwiftData
import Translation

@main
struct JuanGoApp: App {
    @State private var settings = AppSettings.shared

    init() {
        AppFont.shared.applyAppearance()   // before the first screen, so its segmented controls pick it up
        #if DEBUG
        if ProcessInfo.processInfo.environment["JUANGO_BACKUP_SELFTEST"] != nil { Backup.selfTest() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                FontLoadingMask()
            }
                .environment(settings)
                .tint(settings.theme.accent)
                .fontDesign(settings.fontDesign)
                .font(.app(.body))
                .task { AppFont.shared.prepare(); AppFont.shared.applyAppearance() }
                .onChange(of: settings.fontStyle) { AppFont.shared.styleChanged() }
                .onChange(of: settings.themeID) { AppFont.shared.applyAppearance() }
                .preferredColorScheme(settings.colorScheme)
                .environment(\.locale, .zh)
        }
        .modelContainer(for: [Word.self, WordList.self, ReviewLog.self])
    }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var ctx
    @Environment(\.scenePhase) private var phase
    private var cloud: Cloud { .shared }
    /// juango://friend/… or juango://room/… opened the app
    @State private var battleLink: BattleLink?
    /// a friend's invite to their room (supabase/battle_lobby.sql)
    @State private var invite: BattleInvite?
    /// Debug hook: `SIMCTL_CHILD_JUANGO_ONBOARD=1` shows the onboarding again without resetting settings.
    static var forceOnboarding: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["JUANGO_ONBOARD"] != nil
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()
            if settings.onboarded && !Self.forceOnboarding {
                MainTabs().transition(.opacity)
            } else {
                OnboardingView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: settings.onboarded)
        .modifier(WordRepair())
        .modifier(QuotaReminders())
        // the emailed sign-in link comes back as juango://login-callback#access_token=…
        .onOpenURL { url in
            if let l = BattleLink(url: url) { battleLink = l; return }
            if cloud.handle(url), cloud.signedIn {
                Task { if let r = try? await cloud.sync(ctx) { cloud.notice = "已登入 \(cloud.session?.email ?? "")，\(r)" } }
            }
        }
        .fullScreenCover(item: $battleLink) { BattleView(link: $0).environment(settings) }
        // a friend tapped 邀請 in their room: check every 10 s while the app is open and no battle screen is up
        .task(id: phase) {
            while phase == .active, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if invite == nil, battleLink == nil, let i = await Social.nextInvite() { invite = i }
            }
        }
        .alert("\(invite?.name ?? "") 邀請你對戰", isPresented: Binding(get: { invite != nil }, set: { if !$0 { invite = nil } }),
               presenting: invite) { i in
            Button("加入") { battleLink = BattleLink(room: i.code) }
            Button("不要", role: .cancel) {}
        } message: { i in
            Text("房間代碼 \(i.code)")
        }
        .task { DevLog.add("app", "launch · \(DevLog.deviceSummary) · \(cloud.signedIn ? "signed in" : "signed out")") }
        .onChange(of: phase) { _, p in
            if p != .inactive { DevLog.add("app", p == .active ? "foreground" : "background") }
            if p == .background {
                cloud.backgroundPush(ctx)
                // skip today's reminder when today's practice is already done
                let start = Calendar.current.startOfDay(for: .now)
                let n = (try? ctx.fetchCount(FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.date >= start }))) ?? 0
                let due = ((try? ctx.fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.dueDate != nil }))) ?? [])
                    .filter { $0.inMyWords || !$0.lists.isEmpty }.compactMap(\.dueDate)
                Reminders.sync(settings, studiedToday: n > 0, dueDates: due)
            }
            if p == .active, cloud.signedIn { Task { try? await cloud.sync(ctx) } }
            if p == .active { Task { await WordReport.flush() } }
        }
        .alert(cloud.notice ?? "", isPresented: Binding(get: { cloud.notice != nil }, set: { if !$0 { cloud.notice = nil } })) {
            Button("好") { cloud.notice = nil }
        }
    }
}

enum AppTab: Hashable { case importing, explore, study, words, profile }

struct MainTabs: View {
    @Environment(AppSettings.self) private var settings
    @State private var tab: AppTab = MainTabs.debugTab ?? .study

    /// Debug hook: `SIMCTL_CHILD_JUANGO_TAB=study xcrun simctl launch …` opens that tab.
    static var debugTab: AppTab? {
        switch ProcessInfo.processInfo.environment["JUANGO_TAB"] {
        case "explore": .explore
        case "study": .study
        case "words": .words
        case "profile": .profile
        case "import": .importing
        default: nil
        }
    }

    private func tabIcon(_ title: String, _ symbol: String) -> some View {
        Image(systemName: symbol).accessibilityLabel(title)
    }

    var body: some View {
        // the old screen dissolves into the new one instead of cutting over
        TabView(selection: Binding(get: { tab }, set: { new in if new != tab { TabCrossfade.run() }; tab = new })) {
            // icons only, no titles under them; the name is still read out by VoiceOver
            Tab(value: AppTab.study) { StudyTab(onFindWords: { tab = .explore }) } label: { tabIcon("主頁", "house.fill") }
            Tab(value: AppTab.explore) { ExploreTab() } label: { tabIcon("探索", "sparkles.rectangle.stack.fill") }
            Tab(value: AppTab.importing) { ImportTab() } label: { tabIcon("新增", "plus.circle.fill") }
            Tab(value: AppTab.words) { WordsTab() } label: { tabIcon("字庫", "character.book.closed.fill") }
            Tab(value: AppTab.profile) { ProfileTab() } label: { tabIcon("我的", "person.crop.circle.fill") }
        }
        .tabBarMinimizeBehavior(.never)   // the tab bar always stays full size
        // 開始今日學習 from Siri / Spotlight / Shortcuts: the home tab takes it from here
        .onChange(of: AppRouter.shared.startToday, initial: true) { _, go in if go { tab = .study } }
        .task {
            migrateLevels()
            tidyScannedWords()
            redoExamplesWithoutTheWord()
            ExampleStore.shared.container = ctx.container
            ExampleStore.shared.warmUp()   // load the model now, not when the first card asks for a sentence
            // saved words are filled in a moment later, so a card opened right away isn't queued behind them
            try? await Task.sleep(for: .seconds(3))
            ExampleStore.shared.backfill((try? ctx.fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.example == "" }))) ?? [])
        }
    }

    @Environment(\.modelContext) private var ctx
    /// Word-list scans used to save OCR leftovers: level marks and legends in the meanings ("藝術形式 *5"),
    /// half-width 、, cut-off brackets, and phonetics glued onto the word ("accuracy takjoresi"). Clean those up.
    private func tidyScannedWords() {
        guard let words = try? ctx.fetch(FetchDescriptor<Word>()) else { return }
        let terms = Set(words.map(\.term))
        var changed = false
        for w in words {
            let meanings = w.meanings   // a colon between two meanings ("重要性:意義") is a separator, like ；
                .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ":：")) }
                .map { GlossaryParser.tidy($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let deduped = meanings.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if deduped != w.meanings { w.meanings = deduped; changed = true }
            // the dictionary's phonetics were cleaned up (^ɔd → ɡɔd, ' → ˈ, Cyrillic ә → ə): copies saved
            // in the old notation take the new one
            if w.ipa.contains(where: { "'ә^\\є".contains($0) }), let e = Dictionary_.lookup(w.term),
               e.w.lowercased() == w.term.lowercased(), !e.ipa.isEmpty, e.ipa != w.ipa {
                w.ipa = e.ipa; changed = true
            }
            let fixed = GlossaryParser.cleanTerm(w.term)
            guard fixed != w.term, !terms.contains(fixed) else { continue }
            let old = w.term
            w.term = fixed
            for log in (try? ctx.fetch(FetchDescriptor<ReviewLog>(predicate: #Predicate { $0.term == old }))) ?? [] { log.term = fixed }
            if let e = Dictionary_.lookup(fixed) {
                if w.meanings.isEmpty { w.meanings = e.zh }
                if w.ipa.isEmpty { w.ipa = e.ipa }
                if w.pos.isEmpty { w.pos = e.pos }
            }
            changed = true
        }
        if changed { try? ctx.save() }
    }

    /// Examples written under the old, looser check may not use the word at all ("famed": "She gained fame…"),
    /// which also leaves cloze questions without a blank. Clear those so the backfill below writes new ones
    /// (only where this device can write them), and trim the run-on junk some translations ended with.
    private func redoExamplesWithoutTheWord() {
        guard let words = try? ctx.fetch(FetchDescriptor<Word>(predicate: #Predicate { $0.example != "" })) else { return }
        var changed = false
        for w in words {
            let zh = ExampleStore.cleanZh(w.exampleZh)
            if zh != w.exampleZh { w.exampleZh = zh; changed = true }
            if (ExampleStore.onDevice && !WordMatch.found(w.term, in: w.example)) || GlossaryParser.cleanTerm(w.term) != w.term {
                w.example = ""; w.exampleZh = ""; changed = true
            }
        }
        if changed { try? ctx.save() }
    }

    /// Words saved before v1.1 carry CEFR levels; move them onto the 大考 1–6 scale.
    private func migrateLevels() {
        guard let words = try? ctx.fetch(FetchDescriptor<Word>()) else { return }
        var changed = false
        for w in words where cefrToExam[w.cefr] != nil || w.cefr == "—" {
            if let e = Dictionary_.lookup(w.term) { w.cefr = e.lv } else if let lv = cefrToExam[w.cefr] { w.cefr = lv } else { continue }
            changed = true
        }
        if changed { try? ctx.save() }
    }
}

/// Screen background with the theme tint; used by each tab's NavigationStack.
struct ThemedBackground: ViewModifier {
    @Environment(AppSettings.self) private var settings
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden)
            .background(settings.theme.background.ignoresSafeArea())
    }
}
extension View { func themedBackground() -> some View { modifier(ThemedBackground()) } }


/// A short dissolve between tabs: a picture of the tab being left, laid under the tab bar, fades out over the new one.
/// A plain theme-coloured cover over the first screen while the Chinese face picked in 字體 (圓體 or 宋體) loads, so the text doesn't
/// draw in 蘋方 and then jump. Gives up after a few seconds (no network on the first download) and fades out.
struct FontLoadingMask: View {
    @Environment(AppSettings.self) private var settings
    @State private var gone = false
    private var font: AppFont { .shared }

    var body: some View {
        ZStack {
            if !gone && !font.ready {
                settings.theme.background
                    .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: font.ready)
        .animation(.easeOut(duration: 0.35), value: gone)
        .allowsHitTesting(!gone && !font.ready)
        .task {
            try? await Task.sleep(for: .seconds(4))
            gone = true
        }
    }
}

@MainActor enum TabCrossfade {
    static func run() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let tabs = find(window.rootViewController),
              let page = tabs.selectedViewController?.view,
              let container = page.superview,
              let picture = page.snapshotView(afterScreenUpdates: false) else { return }
        picture.isUserInteractionEnabled = false
        picture.frame = page.frame
        container.addSubview(picture)
        // The new page is added to the same container after this call; lift the picture over it on the next
        // pass, but keep it under the tab bar (and whatever holds it) so the bar itself never fades.
        DispatchQueue.main.async {
            if let bar = container.subviews.first(where: { tabs.tabBar.isDescendant(of: $0) }) {
                container.insertSubview(picture, belowSubview: bar)
            } else {
                container.bringSubviewToFront(picture)
            }
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                picture.alpha = 0
            } completion: { _ in picture.removeFromSuperview() }
        }
    }

    private static func find(_ vc: UIViewController?) -> UITabBarController? {
        guard let vc else { return nil }
        if let t = vc as? UITabBarController { return t }
        for c in vc.children { if let t = find(c) { return t } }
        return nil
    }
}

/// Tidies saved words once the app opens:
/// - meanings a word-list photo was misread with are fixed against the dictionary (once per repair version)
/// - words saved with no meaning at all get one, from the AI translator when it's on, otherwise from
///   Apple Translation when its English→Chinese files are already on the device (no download prompt)
struct WordRepair: ViewModifier {
    @Environment(\.modelContext) private var ctx
    @State private var config: TranslationSession.Configuration?
    @State private var empty: [Word] = []
    private static let version = 1

    func body(content: Content) -> some View {
        content
            .task { await start() }
            .translationTask(config) { session in
                let words = empty
                let requests = words.map { TranslationSession.Request(sourceText: $0.term, clientIdentifier: $0.term) }
                guard let replies = try? await session.translations(from: requests) else { return }
                var done: [Word] = []
                for r in replies {
                    let m = r.targetText.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.")))
                    guard !m.isEmpty, m.lowercased() != r.sourceText.lowercased(),
                          let w = words.first(where: { $0.term == r.clientIdentifier }), w.meanings.isEmpty else { continue }
                    w.meanings = [m]
                    done.append(w)
                }
                try? ctx.save()
                if !done.isEmpty { ExampleStore.shared.backfill(done) }
            }
    }

    private func start() async {
        guard let words = try? ctx.fetch(FetchDescriptor<Word>()) else { return }
        let key = "wordRepair.misread"
        if UserDefaults.standard.integer(forKey: key) < Self.version {
            for w in words {
                let fixed = Dictionary_.repairMisread(w.meanings, term: w.term)
                if fixed != w.meanings && !fixed.isEmpty { w.meanings = fixed }
            }
            try? ctx.save()
            UserDefaults.standard.set(Self.version, forKey: key)
        }
        let missing = words.filter { $0.meanings.isEmpty }
        guard !missing.isEmpty else { return }
        if WordTranslator.shared.provider != .none { WordTranslator.shared.fill(missing, in: ctx); return }
        let from = Locale.Language(identifier: "en"), to = Locale.Language(identifier: "zh-Hant")
        guard await LanguageAvailability().status(from: from, to: to) == .installed else { return }
        empty = missing
        config = .init(source: from, target: to)
    }
}
