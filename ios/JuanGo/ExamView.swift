import SwiftUI
import SwiftData

// MARK: - Past papers (大考考古題)

/// One year's 學測英文 multiple-choice part, from exams.json (tools/exams/parse.py): the 大考中心 papers and
/// their official answers. Questions whose options are pictures, the 混合題 and the written part are left out.
struct Exam: Decodable, Identifiable, Hashable {
    let year: Int
    let title: String
    let groups: [ExamGroup]
    var id: Int { year }
    var questionCount: Int { groups.reduce(0) { $0 + $1.questions.count } }
}

struct ExamGroup: Decodable, Hashable {
    let section: String
    let kind: String          // vocab, cloze, fill, structure, reading
    /// paragraphs split by a blank line; a numbered blank is written ⟨n⟩
    let passage: String?
    /// 文意選填 and 篇章結構: one set of options for every blank in the group
    let shared: [String]?
    let questions: [ExamQuestion]
}

struct ExamQuestion: Decodable, Hashable {
    let n: Int
    let stem: String
    let options: [String]
    let answer: Int
}

@MainActor enum ExamStore {
    static let all: [Exam] = {
        guard let url = Bundle.main.url(forResource: "exams", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Exam].self, from: data) else { return [] }
        return list
    }()
    static let sections = ["詞彙題", "綜合測驗", "文意選填", "篇章結構", "閱讀測驗"]

    /// The years a word was an option in a 詞彙, 綜合測驗 or 文意選填 question (the words the papers test).
    static let years: [String: [Int]] = {
        var m: [String: Set<Int>] = [:]
        for e in all {
            for g in e.groups where ["vocab", "cloze", "fill"].contains(g.kind) {
                let options = (g.shared ?? []) + g.questions.flatMap(\.options)
                for o in options where !o.contains(" ") {
                    if let d = Dictionary_.lookup(o) { m[d.w.lowercased(), default: []].insert(e.year) }
                }
            }
        }
        return m.mapValues { $0.sorted(by: >) }
    }()
    static func years(for term: String) -> [Int] { years[term.lowercased()] ?? [] }

    // last score per year and section, "答對/題數"
    private static let key = "examScores"
    static func score(_ year: Int, _ section: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?["\(year)-\(section)"]
    }
    static func save(_ year: Int, _ section: String, right: Int, of total: Int) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d["\(year)-\(section)"] = "\(right)/\(total)"
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// "115 學測" tags for a word that the papers tested.
struct ExamYearsTag: View {
    let term: String
    var body: some View {
        let ys = ExamStore.years(for: term)
        if !ys.isEmpty {
            Text("考過 " + ys.map(String.init).joined(separator: "・") + " 學測")
                .font(.app(.caption, .bold)).foregroundStyle(Color.hsnuMagenta)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Color.hsnuMagentaFill))
        }
    }
}

// MARK: - Exam screen

struct ExamView: View {
    let exam: Exam
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx
    @Environment(AppSettings.self) private var settings

    private struct Item: Hashable { let group: Int; let q: ExamQuestion }
    @State private var run: [Item] = []
    @State private var section = ""
    @State private var index = 0
    @State private var picks: [Int: Int] = [:]     // question number → option picked (-1: 不知道)
    @State private var finished = false
    @State private var lookup: LookupTerm?
    @State private var added = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if run.isEmpty { menu } else if finished { results } else { question }
        }
        .themedBackground()
        .sheet(item: $lookup) { WordConfirmSheet(term: $0.term) }
        .sensoryFeedback(trigger: picks.count) { _, _ in
            guard settings.haptics, let item = current, let p = picks[item.q.n] else { return nil }
            return p == item.q.answer ? .success : .error
        }
    }

    private var current: Item? { index < run.count ? run[index] : nil }

    private var header: some View {
        HStack(spacing: 12) {
            Button { if run.isEmpty || finished { dismiss() } else { run = [] } } label: {
                LIcon(run.isEmpty || finished ? "xmark" : "chevron.left").font(.app(.headline)).frame(width: 36, height: 36)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .accessibilityLabel(run.isEmpty || finished ? "關閉" : "回到題型")
            VStack(alignment: .leading, spacing: 1) {
                Text(exam.title).font(.app(.headline))
                if !run.isEmpty && !finished {
                    Text("\(section)・第 \(min(index + 1, run.count)) / \(run.count) 題").font(.app(.caption).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    // MARK: choosing a part

    private var menu: some View {
        List {
            Section {
                Button { start(nil) } label: {
                    Label("整份作答・\(exam.questionCount) 題", pulso: "doc.text.fill")
                }
                .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            } footer: {
                Text("選擇題部分，題目與答案取自大考中心公布的試題。選項是圖片的題目、混合題與非選擇題不收錄。")
            }
            Section("依題型練習") {
                ForEach(ExamStore.sections, id: \.self) { s in
                    let n = exam.groups.filter { $0.section == s }.reduce(0) { $0 + $1.questions.count }
                    if n > 0 {
                        Button { start(s) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s).foregroundStyle(.primary)
                                    Text("\(n) 題" + (ExamStore.score(exam.year, s).map { "・上次答對 \($0)" } ?? ""))
                                        .font(.app(.caption)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                LIcon("chevron.right").font(.app(.footnote, .semibold)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color.cardFill)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func start(_ s: String?) {
        section = s ?? "整份"
        run = exam.groups.enumerated().filter { s == nil || $0.element.section == s }
            .flatMap { i, g in g.questions.map { Item(group: i, q: $0) } }
        index = 0; picks = [:]; finished = false; added = false
    }

    // MARK: a question

    @ViewBuilder private var question: some View {
        if let item = current {
            let g = exam.groups[item.group]
            GeometryReader { geo in
                VStack(spacing: 12) {
                    if let passage = g.passage {
                        passageView(passage, group: item.group, current: item.q.n)
                            .frame(height: geo.size.height * (g.kind == "reading" ? 0.5 : 0.42))
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            prompt(item, g)
                            options(item, g)
                            next(item)
                        }
                        .padding(.horizontal, 20).padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .id(index)
                }
            }
        }
    }

    private func passageView(_ passage: String, group: Int, current: Int) -> some View {
        let paras = passage.components(separatedBy: "\n\n")
        var filled: [Int: (String, Bool)] = [:]
        let g = exam.groups[group]
        for q in g.questions {
            if let p = picks[q.n] {
                let opts = g.shared ?? q.options
                filled[q.n] = (opts.indices.contains(q.answer) ? opts[q.answer] : "", p == q.answer)
            }
        }
        let here = paras.firstIndex { $0.contains("⟨\(current)⟩") }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(paras.enumerated()), id: \.offset) { i, p in
                        PassageText(text: p, current: g.kind == "reading" ? nil : current, filled: filled) { lookup = LookupTerm(term: $0) }
                            .id(i)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.cardFill))
            .overlay(alignment: .leading) { Rectangle().fill(Color.hsnuNavy).frame(width: 3).padding(.vertical, 14) }
            .padding(.horizontal, 20)
            .onAppear { if let here { proxy.scrollTo(here, anchor: .top) } }
            .onChange(of: current) { if let here { withAnimation { proxy.scrollTo(here, anchor: .top) } } }
        }
    }

    @ViewBuilder private func prompt(_ item: Item, _ g: ExamGroup) -> some View {
        Text("第 \(item.q.n) 題・\(g.section)").font(.app(.caption, .bold)).foregroundStyle(Color.hsnuNavy)
        switch g.kind {
        case "cloze", "fill", "structure":
            Text("選出最適合填入空格 (\(item.q.n)) 的選項").font(.app(.headline))
        default:
            PassageText(text: item.q.stem, current: nil, filled: [:], font: .app(.title3, .semibold)) { lookup = LookupTerm(term: $0) }
        }
    }

    @ViewBuilder private func options(_ item: Item, _ g: ExamGroup) -> some View {
        let opts = g.shared ?? item.q.options
        let picked = picks[item.q.n]
        // a 文意選填 option that already filled an earlier blank is dimmed, as on paper it is used once
        let used = Set(g.questions.filter { $0.n != item.q.n && picks[$0.n] != nil }.map(\.answer))
        let rows = ForEach(Array(opts.enumerated()), id: \.offset) { i, o in
            AnswerOption(letter: String(UnicodeScalar(65 + i)!), text: o,
                         state: picked == nil ? (used.contains(i) ? .used : .idle) : i == item.q.answer ? .right : picked == i ? .wrong : .idle) {
                choose(i, item)
            }
            .allowsHitTesting(picked == nil)
        }
        if g.kind == "fill" {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) { rows }
        } else {
            VStack(spacing: 10) { rows }
        }
        if picked == nil {
            Button("不知道") { choose(-1, item) }
                .font(.app(.subheadline, .semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    @ViewBuilder private func next(_ item: Item) -> some View {
        if let p = picks[item.q.n], p != item.q.answer {
            Button(index + 1 < run.count ? "下一題" : "看結果") { advance() }
                .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
                .padding(.top, 6)
        }
    }

    private func choose(_ i: Int, _ item: Item) {
        guard picks[item.q.n] == nil else { return }
        withAnimation(.snappy(duration: 0.2)) { picks[item.q.n] = i }
        if i == item.q.answer {
            // a right answer moves on by itself; a wrong one waits so the right option can be read
            let at = index
            Task { try? await Task.sleep(for: .seconds(0.8)); if index == at { advance() } }
        }
    }

    private func advance() {
        if index + 1 < run.count { withAnimation(.snappy) { index += 1 } } else { finish() }
    }

    private func finish() {
        let right = run.count { picks[$0.q.n] == $0.q.answer }
        ExamStore.save(exam.year, section, right: right, of: run.count)
        for s in ExamStore.sections {
            let part = run.filter { exam.groups[$0.group].section == s }
            if section == "整份", !part.isEmpty {
                ExamStore.save(exam.year, s, right: part.count { picks[$0.q.n] == $0.q.answer }, of: part.count)
            }
        }
        finished = true
    }

    // MARK: results

    /// The right answers of missed 詞彙 / 綜合 / 文意 questions that are dictionary words.
    private var missedWords: [DictEntry] {
        var seen = Set<String>()
        return run.compactMap { item -> DictEntry? in
            let g = exam.groups[item.group]
            guard ["vocab", "cloze", "fill"].contains(g.kind), picks[item.q.n] != item.q.answer else { return nil }
            let opts = g.shared ?? item.q.options
            guard opts.indices.contains(item.q.answer), let e = Dictionary_.lookup(opts[item.q.answer]),
                  seen.insert(e.w).inserted else { return nil }
            return e
        }
    }

    private var results: some View {
        let right = run.count { picks[$0.q.n] == $0.q.answer }
        let missed = missedWords
        return ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(section == "整份" ? "整份作答" : section).font(.app(.headline)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(right)").font(.app(size: 64, .semibold)).foregroundStyle(Color.hsnuNavy)
                        Text("/ \(run.count) 題").font(.app(.title3, .semibold)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 20)
                HStack(spacing: 3) {
                    ForEach(run, id: \.self) { item in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(picks[item.q.n] == item.q.answer ? Color.hsnuSky : Color.hsnuMagenta)
                            .frame(maxWidth: .infinity).frame(height: 14)
                    }
                }
                .accessibilityHidden(true)
                VStack(spacing: 0) {
                    ForEach(ExamStore.sections, id: \.self) { s in
                        let part = run.filter { exam.groups[$0.group].section == s }
                        if !part.isEmpty {
                            HStack {
                                Text(s)
                                Spacer()
                                Text("\(part.count { picks[$0.q.n] == $0.q.answer }) / \(part.count)").monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.app(.body)).padding(.vertical, 10)
                            Divider()
                        }
                    }
                }
                if !missed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("答錯的單字").font(.app(.subheadline, .bold))
                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(missed) { e in
                                Button { lookup = LookupTerm(term: e.w) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                                        Text(e.w).font(.app(.subheadline, .semibold)).foregroundStyle(.primary)
                                        Text(e.zh.first ?? "").font(.app(.caption)).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(Color.hsnuMagentaFill))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button(added ? "已加入我的單字" : "全部加入我的單字") {
                            for e in missed { _ = Library.add(e, in: ctx) }
                            try? ctx.save(); added = true
                        }
                        .buttonStyle(PillButtonStyle())
                        .disabled(added)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button("其他題型") { run = [] }.buttonStyle(PillButtonStyle())
                    Button("完成") { dismiss() }.buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
    }
}

/// An answer-card option: the letter in a box that fills like a pencil mark, 天藍 when right, 紫紅 when wrong.
struct AnswerOption: View {
    enum State { case idle, used, right, wrong }
    let letter: String
    let text: String
    let state: State
    var action: () -> Void

    var body: some View {
        let marked = state == .right || state == .wrong
        Button(action: action) {
            HStack(spacing: 12) {
                Text(letter).font(.app(.subheadline, .bold)).monospaced()
                    .foregroundStyle(marked ? Color.white : Color.hsnuNavy)
                    .frame(width: 30, height: 34)
                    .background(RoundedRectangle(cornerRadius: 6).fill(state == .right ? Color.hsnuSky : state == .wrong ? Color.hsnuMagenta : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.hsnuNavy.opacity(marked ? 0 : 0.5), lineWidth: 1.5))
                Text(text).font(.app(.headline)).multilineTextAlignment(.leading)
                    .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if state == .right { LIcon("checkmark").font(.app(.headline)).foregroundStyle(Color.hsnuSky).accessibilityLabel("正確答案") }
                else if state == .wrong { LIcon("xmark").font(.app(.headline)).foregroundStyle(Color.hsnuMagenta).accessibilityLabel("答錯") }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(state == .right ? Color.hsnuSkyFill : state == .wrong ? Color.hsnuMagentaFill : Color.cardFill))
            .opacity(state == .used ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A paragraph of a paper: every word can be tapped to look it up, and ⟨n⟩ is drawn as the numbered
/// blank, highlighted while it is the question, and filled with the answer once answered.
struct PassageText: View {
    let text: String
    let current: Int?
    let filled: [Int: (String, Bool)]
    var font: Font = .app(.body)
    var onTap: (String) -> Void

    var body: some View {
        Text(attributed)
            .font(font)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                if url.host() == "w", let w = url.lastPathComponent.removingPercentEncoding { onTap(w) }
                return .handled
            })
            .accessibilityLabel(text.replacing(/⟨(\d+)⟩/) { "第\($0.1)題空格" })
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for (i, raw) in text.split(separator: " ").enumerated() {
            if i > 0 { out += AttributedString(" ") }
            let s = String(raw)
            if let m = s.firstMatch(of: /⟨(\d+)⟩/), let n = Int(m.1) {
                out += AttributedString(String(s[..<m.range.lowerBound]))
                var b: AttributedString
                if let (t, ok) = filled[n] {
                    b = AttributedString("(\(n)) \(t)")
                    b.foregroundColor = ok ? .hsnuSky : .hsnuMagenta
                } else {
                    b = AttributedString(" (\(n)) ______ ")
                    b.foregroundColor = .hsnuNavy
                    if n == current { b.backgroundColor = .hsnuSkyFill }
                }
                b.inlinePresentationIntent = .stronglyEmphasized
                out += b
                out += AttributedString(String(s[m.range.upperBound...]))
            } else {
                var run = AttributedString(s)
                let word = s.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                if !word.isEmpty, word.rangeOfCharacter(from: .letters) != nil,
                   let enc = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    run.link = URL(string: "juango-exam://w/\(enc)")
                }
                run.foregroundColor = .primary
                out += run
            }
        }
        return out
    }
}
