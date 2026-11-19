import SwiftUI

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @State private var page = 0
    @State private var test = LevelTest()
    /// the option just tapped (-1: 不知道), shown in colour for a moment before the next question
    @State private var shown: Int?
    @State private var unsupportedLanguage = false

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: languagePage
                case 1: testPage
                case 2: resultPage
                case 3: goalPage
                default: themePage
                }
            }
            .frame(maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            bottomBar.padding(.horizontal, 20)
            PageDots(count: 5, index: page).padding(.vertical, 14)
        }
        .animation(.spring(duration: 0.45), value: page)
        #if DEBUG
        // Debug hook: `SIMCTL_CHILD_JUANGO_ONBOARD=3` opens onboarding on that page.
        .task { if let p = Int(ProcessInfo.processInfo.environment["JUANGO_ONBOARD"] ?? ""), (0...4).contains(p) { page = p } }
        #endif
        .alert("目前只支援繁體中文解釋", isPresented: $unsupportedLanguage) { Button("好") {} } message: {
            Text("其他語言的解釋會在之後的版本加入。")
        }
    }

    // MARK: pages

    /// A page title on the left, like the heading of a worksheet, with one line on what the choice does.
    private func header(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(size: 34, .bold))
            Text(note).font(.app(.subheadline)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24).padding(.top, 36)
    }

    private static let languages: [(code: String, name: String, sample: String)] = [
        ("zh-Hant", "繁體中文", "有韌性的"), ("en", "English", "able to recover quickly"),
        ("ja", "日本語", "回復力のある"), ("ko", "한국어", "회복력 있는"),
    ]

    /// Rows on one sheet, each showing how "resilient" would be explained, with an answer-card box to mark.
    private var languagePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("解釋語言", "單字的意思會用這個語言顯示。")
            VStack(spacing: 0) {
                ForEach(Array(Self.languages.enumerated()), id: \.offset) { i, l in
                    let on = settings.language == l.code, ready = l.code == "zh-Hant"
                    Button {
                        if ready { settings.language = l.code } else { unsupportedLanguage = true }
                    } label: {
                        HStack(spacing: 14) {
                            MarkBox(on: on)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(l.name).font(.app(.headline))
                                    if !ready { SoonTag() }
                                }
                                Text("resilient  \(l.sample)").font(.app(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 70).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(ready ? 1 : 0.55)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    if i < Self.languages.count - 1 { Divider().padding(.leading, 54) }
                }
            }
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
    }

    /// One tap per question: four options on an answer card, in 附中's 天藍 (right) and 紫紅 (wrong).
    /// The next word is harder after a right answer and easier after a wrong one.
    private var testPage: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("第 \(min(test.index + 1, LevelTest.length)) 題").font(.app(.headline)).foregroundStyle(Color.hsnuNavy)
                    Text("/ \(LevelTest.length)").font(.app(.subheadline).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Text("單字程度測驗").font(.app(.caption, .bold)).foregroundStyle(.secondary)
                }
                AnswerStrip(test: test, live: true)
            }
            if let item = test.current {
                VStack(spacing: 14) {
                    prompt(item)
                    VStack(spacing: 10) {
                        ForEach(Array(item.options.enumerated()), id: \.offset) { i, o in optionRow(item, i, o) }
                    }
                    Button("不知道") { choose(-1, item) }
                        .font(.app(.subheadline, .semibold)).foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                        .allowsHitTesting(shown == nil)
                }
                .id(test.index)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 12)
        .animation(.snappy, value: test.index)
        .sensoryFeedback(trigger: shown) { _, new in
            guard settings.haptics, let new, let item = test.current else { return nil }
            return new == item.correct ? .success : .error
        }
    }

    @ViewBuilder private func prompt(_ item: LevelTest.Item) -> some View {
        switch item.kind {
        case .meaning:
            VStack(spacing: 6) {
                Text("選出正確的中文意思").font(.app(.caption, .semibold)).foregroundStyle(.secondary)
                Text(item.entry.w).font(.app(size: 40, .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                HStack(spacing: 8) {
                    if !item.entry.ipa.isEmpty { Text("/\(item.entry.ipa)/").font(.app(.footnote)).foregroundStyle(.secondary) }
                    SpeakButton(text: item.entry.w).font(.app(.footnote))
                }
            }
            .frame(minHeight: 120)
        case .cloze:
            VStack(alignment: .leading, spacing: 8) {
                Text("選出最適合填入空格的字").font(.app(.caption, .semibold)).foregroundStyle(.secondary)
                Text(item.sentence).font(.app(.title3, .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(Color.hsnuNavy.opacity(0.05)))
            .overlay(alignment: .leading) { Rectangle().fill(Color.hsnuNavy).frame(width: 3).padding(.vertical, 8) }
        }
    }

    private func optionRow(_ item: LevelTest.Item, _ i: Int, _ o: String) -> some View {
        let right = shown != nil && i == item.correct, wrong = shown == i && i != item.correct
        return Button { choose(i, item) } label: {
            HStack(spacing: 14) {
                // an answer-card box: empty until it is marked, then filled like a pencil mark
                Text(String(UnicodeScalar(65 + i)!)).font(.app(.subheadline, .bold)).monospaced()
                    .foregroundStyle(right || wrong ? Color.white : Color.hsnuNavy)
                    .frame(width: 30, height: 34)
                    .background(RoundedRectangle(cornerRadius: 6).fill(right ? Color.hsnuSky : wrong ? Color.hsnuMagenta : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.hsnuNavy.opacity(right || wrong ? 0 : 0.5), lineWidth: 1.5))
                Text(o).font(.app(.headline)).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if right { LIcon("checkmark").font(.app(.headline)).foregroundStyle(Color.hsnuSky).accessibilityLabel("正確答案") }
                else if wrong { LIcon("xmark").font(.app(.headline)).foregroundStyle(Color.hsnuMagenta).accessibilityLabel("答錯") }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(right ? Color.hsnuSkyFill : wrong ? Color.hsnuMagentaFill : Color.cardFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(shown == nil)
    }

    private func choose(_ i: Int, _ item: LevelTest.Item) {
        guard shown == nil else { return }
        withAnimation(.snappy(duration: 0.2)) { shown = i }
        if item.kind == .meaning || i == item.correct { Speech.say(item.entry.w) }
        Task {
            // long enough to see the right answer after a miss
            try? await Task.sleep(for: .seconds(i == item.correct ? 0.6 : 1.3))
            test.record(i < 0 ? nil : i)
            shown = nil
            if test.isDone { finishTest() }
        }
    }

    private var resultPage: some View {
        VStack(spacing: 12) {
            Text("你的推定程度").font(.app(.title2, .bold))
            Text(levelLabel(test.estimate)).font(.app(size: 64, .semibold)).foregroundStyle(Color.hsnuNavy)
            Text(LevelTest.blurb(test.estimate)).font(.app(.headline))
            VStack(spacing: 8) {
                AnswerStrip(test: test, live: false)
                Text("答對 \(test.correctCount) / \(test.picks.count) 題・最高答到第\(test.hardestRight)級").font(.app(.subheadline)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 4)
            Text("會從接近你程度的單字開始。").font(.app(.subheadline)).foregroundStyle(.secondary)
            Button("重新測驗") { test = LevelTest(); page = 1 }
                .font(.app(.subheadline, .semibold)).frame(minHeight: 44)
        }
    }

    /// One number to set with − and +, what it adds up to, and three quick presets underneath.
    private var goalPage: some View {
        @Bindable var settings = settings
        let goal = settings.dailyGoal
        return VStack(alignment: .leading, spacing: 18) {
            header("每日新字", "每天學幾個新字？要複習的字會另外排進來，之後隨時能改。")
            VStack(spacing: 14) {
                HStack(spacing: 20) {
                    stepButton("minus", "少一個", -1)
                    VStack(spacing: 0) {
                        Text("\(goal)").font(.app(size: 64, .bold)).monospacedDigit()
                            .contentTransition(.numericText(value: Double(goal)))
                        Text("個新字／天").font(.app(.subheadline)).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 120)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("每天 \(goal) 個新字")
                    .accessibilityAdjustableAction { d in
                        settings.dailyGoal = min(100, max(1, goal + (d == .increment ? 1 : -1)))
                    }
                    stepButton("plus", "多一個", 1)
                }
                Text("約 \(goal) 分鐘・30 天約 \(goal * 30) 字").font(.app(.subheadline, .semibold)).foregroundStyle(Color.themeAccent)
                HStack(spacing: 8) {
                    ForEach([(5, "輕鬆"), (10, "標準"), (20, "衝刺")], id: \.0) { n, name in
                        let on = goal == n
                        Button("\(name) \(n)") { withAnimation(.snappy) { settings.dailyGoal = n } }
                            .buttonStyle(PillButtonStyle(fill: on ? .themeAccent : nil, foreground: on ? .onAccent : nil, height: 44))
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16).padding(.vertical, 6)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .padding(.horizontal, 20)
            VStack(spacing: 10) {
                Toggle(isOn: $settings.reminderOn) { Label("學習與複習提醒", pulso: "bell.fill").font(.app(.headline)) }
                if settings.reminderOn {
                    DatePicker("提醒時間", selection: $settings.reminderDate, displayedComponents: .hourAndMinute)
                }
            }
            .card(padding: 16)
            .padding(.horizontal, 20)
            Spacer(minLength: 0)
        }
    }

    private func stepButton(_ icon: String, _ label: String, _ by: Int) -> some View {
        Button {
            withAnimation(.snappy) { settings.dailyGoal = min(100, max(1, settings.dailyGoal + by)) }
        } label: {
            LIcon(icon).font(.app(.title3, .bold)).frame(width: 30, height: 30)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        .disabled(by < 0 ? settings.dailyGoal <= 1 : settings.dailyGoal >= 100)
        .accessibilityLabel(label)
    }

    /// A live sample of the app on top, then light or dark, the font as marked rows, and the colour as dots.
    private var themePage: some View {
        @Bindable var settings = settings
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header("外觀", "字體和顏色會套用到整個 App，之後在設定也能改。")
                ThemePreview().padding(.horizontal, 20)
                Picker("外觀", selection: $settings.appearance) {
                    Text("跟隨系統").tag(0); Text("淺色").tag(1); Text("深色").tag(2)
                }
                .pickerStyle(.segmented).padding(.horizontal, 20)
                Text("字體").font(.app(.headline)).padding(.horizontal, 24).padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(AppFont.options.enumerated()), id: \.offset) { i, o in
                        let on = settings.fontStyle == i
                        Button { settings.fontStyle = i } label: {
                            HStack(spacing: 14) {
                                MarkBox(on: on)
                                Text(o.name).font(.app(.headline))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        if i < AppFont.options.count - 1 { Divider().padding(.leading, 54) }
                    }
                }
                .background(Color.cardFill, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .padding(.horizontal, 20)
                Text("主題色").font(.app(.headline)).padding(.horizontal, 24).padding(.top, 4)
                ThemeGrid(selection: $settings.themeID).padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .scrollIndicators(.hidden)
        .clipped()
    }

    // MARK: bottom bar

    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: 10) {
            if page > 0 {
                Button { back() } label: { LIcon("chevron.left").font(.app(.headline)) }.accessibilityLabel("上一步")
                    .buttonStyle(PillButtonStyle()).frame(width: 64)
            }
            switch page {
            case 0:
                Button("跳過") { page = 3 }.buttonStyle(PillButtonStyle()).frame(width: 88)
                Button("\(LevelTest.length) 題程度測驗・約 3 分鐘") { test = LevelTest(); page = 1 }
                    .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
            case 1:
                Button("撤銷") { test.undo() }.buttonStyle(PillButtonStyle(foreground: .secondary)).disabled(test.picks.isEmpty || shown != nil)
                Button("略過") { finishTest() }.buttonStyle(PillButtonStyle()).frame(width: 88)
            case 2:
                Button("設定學習目標") { page = 3 }.buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
            case 3:
                Button("繼續") { page = 4 }.buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
            default:
                Button("完成並開始使用") { settings.onboarded = true }
                    .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
            }
        }
    }

    private func back() {
        if page == 1, !test.picks.isEmpty, shown == nil { test.undo(); return }
        page = page == 3 && test.picks.isEmpty ? 0 : page - 1
    }

    private func finishTest() {
        if !test.picks.isEmpty { settings.level = test.estimate; page = 2 } else { page = 3 }
    }
}

struct ThemeGrid: View {
    @Binding var selection: String
    /// Swatches: a paper square with the theme colour as a band along the bottom (the same picker as BanGo).
    /// The name is written in the paper colour, which stays readable when dark mode lightens the band.
    var body: some View {
        StackGrid(items: AppTheme.all, columns: 3, spacing: 10) { t in
                Button { selection = t.id } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Aa").font(.app(.title3, .bold)).foregroundStyle(t.accent)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        Spacer(minLength: 0)
                        HStack {
                            Text(t.name).font(.app(.caption, .bold)).foregroundStyle(t.swatch)
                            Spacer()
                            if selection == t.id { LIcon("checkmark").font(.app(.caption, .bold)).foregroundStyle(t.swatch) }
                        }
                        .padding(.horizontal, 10).frame(height: 28).background(t.accent)
                    }
                    .frame(height: 76)
                    .background(t.swatch)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(selection == t.id ? Color.primary : .clear, lineWidth: 2))
                }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == t.id ? .isSelected : [])
        }
    }
}

/// A small sample of the app in the chosen font and colour: a word with its meaning and today's progress.
struct ThemePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("resilient").font(.app(size: 28, .bold)).lineLimit(1).minimumScaleFactor(0.6)
                Text("adj.").font(.app(.caption)).foregroundStyle(.secondary)
                Spacer()
                Text("第 3 級").font(.app(.caption, .bold)).foregroundStyle(Color.themeAccent)
            }
            Text("有韌性的；能迅速恢復的").font(.app(.body)).foregroundStyle(Color.themeAccent)
            HStack(spacing: 10) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.themeAccent.opacity(0.15))
                        Capsule().fill(Color.themeAccent).frame(width: g.size.width * 0.6)
                    }
                }
                .frame(height: 6)
                Text("今天 6 / 10").font(.app(.caption).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(18).padding(.leading, 5)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Color.cardFill
                Color.themeAccent.frame(width: 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("預覽")
    }
}

/// The answer-card box used for choices during onboarding: empty outline, filled and ticked when marked.
struct MarkBox: View {
    let on: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(on ? Color.themeAccent : .clear)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(on ? 0 : 0.6), lineWidth: 1.5))
            .overlay { if on { LIcon("checkmark").font(.app(size: 13, .bold)).foregroundStyle(Color.onAccent) } }
            .frame(width: 24, height: 28)
            .animation(.snappy(duration: 0.2), value: on)
            .accessibilityHidden(true)
    }
}

struct SoonTag: View {
    var body: some View {
        Text("之後推出").font(.app(.caption2, .bold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.14)))
    }
}

struct PageDots: View {
    let count: Int
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(i <= index ? Color.themeAccent : Color.secondary.opacity(0.3))
                    .frame(maxWidth: .infinity).frame(height: 4)
            }
        }
        .animation(.snappy, value: index)
    }
}

/// The test's progress as a row of answer-card boxes: 天藍 right, 紫紅 wrong or 不知道, the current one outlined.
struct AnswerStrip: View {
    let test: LevelTest
    let live: Bool
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<(live ? LevelTest.length : max(1, test.picks.count)), id: \.self) { i in
                let done = i < test.picks.count
                RoundedRectangle(cornerRadius: 3)
                    .fill(done ? (test.isCorrect(i) ? Color.hsnuSky : Color.hsnuMagenta) : Color.secondary.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.hsnuNavy, lineWidth: live && i == test.picks.count ? 1.5 : 0))
                    .frame(maxWidth: .infinity).frame(height: 16)
            }
        }
        .animation(.snappy, value: test.picks.count)
        .accessibilityElement()
        .accessibilityLabel("答對 \(test.correctCount) 題，共答 \(test.picks.count) 題")
    }
}

// MARK: - Level test model

/// An adaptive test: each answer moves an ability estimate up or down (in steps that shrink as the
/// test goes on), and the next word is picked one notch above it, so most of the 18 questions land
/// near the edge of what the learner knows. Distractors share the word's level and part of speech,
/// and from level 2 up about half the questions are 學測-style sentence blanks with English options.
struct LevelTest {
    enum Kind { case meaning, cloze }
    struct Item {
        let entry: DictEntry
        let kind: Kind
        let sentence: String
        let options: [String]
        let correct: Int
        var level: Int { Int(entry.lv) ?? 1 }
    }
    static let length = 18

    private(set) var items: [Item] = []
    /// the option picked for each question; nil for 不知道
    private(set) var picks: [Int?] = []
    private var thetas: [Double] = [3]
    private var theta: Double { thetas[thetas.count - 1] }

    @MainActor init() {
        if let first = Self.item(level: 3, avoid: []) { items = [first] }
    }

    var index: Int { picks.count }
    var current: Item? { index < Self.length && index < items.count ? items[index] : nil }
    var isDone: Bool { picks.count >= Self.length || current == nil }
    func isCorrect(_ i: Int) -> Bool { i < picks.count && picks[i] == items[i].correct }
    var correctCount: Int { picks.indices.filter(isCorrect).count }
    var hardestRight: Int { picks.indices.filter(isCorrect).map { items[$0].level }.max() ?? 0 }

    @MainActor mutating func record(_ pick: Int?) {
        guard let item = current else { return }
        picks.append(pick)
        let right = pick == item.correct
        // chance of a right answer at this level: two in three when the estimate equals it
        let p = 1 / (1 + exp(-(1.6 * (theta - Double(item.level)) + 0.7)))
        let step = max(0.45, 2.0 * pow(0.82, Double(picks.count - 1)))
        thetas.append(min(6.6, max(0.6, theta + (right ? step * (1 - p) : -step * p))))
        guard picks.count < Self.length else { return }
        let target = min(6, max(1, Int((theta + 0.4).rounded())))
        if let next = Self.item(level: target, avoid: Set(items.map(\.entry.w))) { items.append(next) }
    }

    mutating func undo() {
        guard !picks.isEmpty else { return }
        picks.removeLast(); thetas.removeLast()
        items = Array(items.prefix(picks.count + 1))
    }

    var estimate: String { String(min(6, max(1, Int(theta.rounded())))) }

    @MainActor private static func item(level: Int, avoid: Set<String>) -> Item? {
        let pool = Dictionary_.entries(level: String(level))
            .filter { !$0.zh.isEmpty && $0.w.count > 3 && !$0.w.contains(" ") && !avoid.contains($0.w) }
        for e in pool.shuffled().prefix(30) {
            if level >= 2, Bool.random(), let s = blanked(e), let (o, c) = options(for: e, level: level, cloze: true) {
                return Item(entry: e, kind: .cloze, sentence: s, options: o, correct: c)
            }
            if let (o, c) = options(for: e, level: level, cloze: false) {
                return Item(entry: e, kind: .meaning, sentence: "", options: o, correct: c)
            }
        }
        return nil
    }

    /// The example with the word blanked, when the example has the word as written (not "decided" for decide).
    private static func blanked(_ e: DictEntry) -> String? {
        guard !e.ex.isEmpty, let p = WordMatch.pattern(for: e.w),
              let r = e.ex.range(of: p, options: [.regularExpression, .caseInsensitive]),
              e.ex[r].lowercased() == e.w.lowercased() else { return nil }
        return e.ex.replacingCharacters(in: r, with: "______")
    }

    /// Three distractors of the same level and part of speech (the next levels when short), none sharing a meaning.
    @MainActor private static func options(for e: DictEntry, level: Int, cloze: Bool) -> ([String], Int)? {
        let label: (DictEntry) -> String = { cloze ? $0.w : $0.zh.prefix(2).joined(separator: "；") }
        let tags = Set(e.posTags), meanings = Set(e.zh), mine = label(e)
        var picks: [String] = []
        for lv in [level, level - 1, level + 1] where (1...6).contains(lv) && picks.count < 3 {
            let pool = Dictionary_.entries(level: String(lv)).filter { o in
                o.w != e.w && !o.zh.isEmpty && !o.w.contains(" ") && !tags.isDisjoint(with: o.posTags)
                    && meanings.isDisjoint(with: o.zh) && (!cloze || (o.posTags == e.posTags && abs(o.w.count - e.w.count) <= 3))
            }
            for o in pool.shuffled() where picks.count < 3 {
                let l = label(o)
                if l != mine, !picks.contains(l) { picks.append(l) }
            }
        }
        guard picks.count == 3 else { return nil }
        let c = Int.random(in: 0...3)
        picks.insert(mine, at: c)
        return (picks, c)
    }

    static func blurb(_ lv: String) -> String {
        switch lv {
        case "1": "國中基礎字，從最常用的開始"
        case "2": "累積日常生活情境的單字"
        case "3": "高一程度・校園與生活常用字"
        case "4": "高二程度・挑戰抽象詞彙"
        case "5": "高三程度・學測進階字"
        default: "學測頂標・最難的第六級"
        }
    }
}
