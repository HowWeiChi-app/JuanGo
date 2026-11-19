import SwiftUI
import SwiftData

// MARK: - Server data

/// What supabase/battle.sql returns. The server keeps the answers, the clock and the scores;
/// the app only draws this and sends taps.
struct BattleState: Decodable {
    struct Side: Decodable { var name: String; var rating: Int; var tier: Int; var score: Int }
    struct Question: Decodable, Equatable { var n: Int; var toZh: Bool; var prompt: String; var options: [String] }
    struct Last: Decodable {
        var n: Int, answer: Int, term: String, zh: String
        var pick: Int?, points: Int, opponentPick: Int?, opponentPoints: Int
    }
    struct Word: Decodable, Identifiable { var term: String, zh: String, right: Bool; var id: String { term } }
    struct Outcome: Decodable { var outcome: String, reason: String, delta: Int, words: [Word] }

    var id: String, status: String, rated: Bool, code: String?, round: Int
    var now: Double
    var you: Side
    var opponent: Side?
    var starts: Double?, ends: Double?
    var answered: Bool?, opponentAnswered: Bool?
    var question: Question?
    var last: Last?
    var result: Outcome?
}

struct BattlePlayer: Decodable {
    var name: String, rating: Int, tier: Int, games: Int, wins: Int, losses: Int, draws: Int
}

private struct BattleTicket: Decodable { var match: String?; var code: String?; var waited: Int? }

// MARK: - Match flow

@MainActor @Observable
final class BattleModel {
    enum Phase: Equatable { case home, searching, room(String), playing, finished }

    private(set) var phase = Phase.home
    private(set) var me: BattlePlayer?
    private(set) var meFailed = false
    private(set) var state: BattleState?
    private(set) var waited = 0
    private(set) var current: BattleState.Question?
    private(set) var previous: BattleState.Question?
    private(set) var picks: [Int: Int] = [:]
    var error: String?

    /// server time minus this phone's time, from the request that came back fastest
    private var clockOffset: Double = 0
    private var bestTrip = Double.infinity
    private var loop: Task<Void, Never>?
    private let level: Int
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(level: String) { self.level = Int(level) ?? 3 }

    var serverNow: Double { Date.now.timeIntervalSince1970 * 1000 + clockOffset }

    private func call<T: Decodable>(_ name: String, _ args: [String: Any] = [:]) async throws -> T {
        try Self.decoder.decode(T.self, from: await Cloud.shared.rpc(name, args))
    }

    /// Returns what went wrong, or nil once the new name is saved.
    func rename(_ name: String) async -> String? {
        #if DEBUG
        if isDemo { me?.name = name; return nil }
        #endif
        do {
            me = try await call("battle_set_name", ["p_name": name, "p_level": level])
            return nil
        } catch {
            return error.localizedDescription.replacingOccurrences(of: "（\\d+）$", with: "", options: .regularExpression)
        }
    }

    func load() async {
        #if DEBUG
        if isDemo { return }
        #endif
        guard Cloud.shared.signedIn else { me = nil; return }
        do {
            me = try await call("battle_me", ["p_level": level])
            meFailed = false
        } catch {
            meFailed = true
            self.error = error.localizedDescription
        }
    }

    func find() {
        reset(.searching)
        loop = Task {
            var failures = 0
            while !Task.isCancelled {
                do {
                    let t: BattleTicket = try await call("battle_find", ["p_level": level])
                    failures = 0
                    waited = t.waited ?? waited
                    if let id = t.match { play(id); return }
                } catch {
                    failures += 1
                    if failures >= 4 { fail(error); return }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func createRoom() {
        reset(.searching)
        loop = Task {
            do {
                let t: BattleTicket = try await call("battle_create_room", ["p_level": level])
                guard let id = t.match, let code = t.code else { return }
                phase = .room(code)
                await poll(id)
            } catch { fail(error) }
        }
    }

    func join(_ code: String) {
        reset(.searching)
        loop = Task {
            do {
                let t: BattleTicket = try await call("battle_join", ["p_code": code, "p_level": level])
                if let id = t.match { play(id) }
            } catch { fail(error) }
        }
    }

    private func play(_ id: String) {
        loop?.cancel()
        loop = Task { await poll(id) }
    }

    /// Fetches the match about twice a second until it ends.
    private func poll(_ id: String) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let sent = Date.now.timeIntervalSince1970 * 1000
                let s: BattleState = try await call("battle_state", ["p_match": id])
                failures = 0
                apply(s, sent: sent)
                if s.status == "finished" { return }
            } catch {
                failures += 1
                if failures >= 16 { fail(error); return }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func apply(_ s: BattleState, sent: Double) {
        // an answer and a poll can cross on the network: an older state must not replace a newer one
        guard !Task.isCancelled, s.now >= state?.now ?? 0 else { return }
        let received = Date.now.timeIntervalSince1970 * 1000
        if received - sent < bestTrip {
            bestTrip = received - sent
            clockOffset = s.now - (sent + received) / 2
        }
        state = s
        if let q = s.question, q.n != current?.n { previous = current; current = q }
        if s.status == "playing" {
            phase = .playing
        } else if s.status == "finished", s.result != nil, phase != .finished {
            if case .room = phase { phase = .home; return }
            // the last answer stays on screen for a moment before the result
            let played = s.last != nil && s.result?.reason == "score"
            Task {
                if played { try? await Task.sleep(for: .seconds(3)) }
                phase = .finished
                await load()
            }
        }
    }

    func answer(_ i: Int) {
        guard let s = state, let q = current, q.n == s.round, picks[q.n] == nil, let starts = s.starts else { return }
        picks[q.n] = i
        let ms = max(0, Int(serverNow - starts))
        Task {
            let sent = Date.now.timeIntervalSince1970 * 1000
            if let r: BattleState = try? await call("battle_answer", ["p_match": s.id, "p_round": q.n, "p_pick": i, "p_ms": ms]) {
                apply(r, sent: sent)
            }
        }
    }

    /// Stops whatever is running. During a match this loses it.
    func leave() {
        let id = state?.status == "finished" ? nil : state?.id
        let searching = phase == .searching
        loop?.cancel()
        reset(.home)
        Task {
            if let id { _ = try? await Cloud.shared.rpc("battle_quit", ["p_match": id]) }
            else if searching { _ = try? await Cloud.shared.rpc("battle_cancel_find") }
            await load()
        }
    }

    func leaveRoom(_ code: String) {
        let id = roomID
        loop?.cancel()
        reset(.home)
        if let id { Task { _ = try? await Cloud.shared.rpc("battle_quit", ["p_match": id]) } }
    }
    private var roomID: String? { state?.id }

    private func reset(_ p: Phase) {
        loop?.cancel()
        phase = p; state = nil; current = nil; previous = nil; picks = [:]; waited = 0; error = nil
        bestTrip = .infinity
    }

    private func fail(_ e: Error) {
        guard !Task.isCancelled else { return }
        reset(.home)
        error = e.localizedDescription
    }

    #if DEBUG
    private(set) var isDemo = false

    /// JUANGO_BATTLE=home | search | room | count | question | reveal | result draws a screen without the server.
    func demo(_ step: String) {
        isDemo = true
        let opp = BattleState.Side(name: "電腦石虎", rating: 668, tier: 4, score: step == "result" ? 332 : 170)
        let you = BattleState.Side(name: "勇敢的水獺08", rating: 640, tier: 4, score: step == "result" ? 405 : 188)
        let q = BattleState.Question(n: 3, toZh: true, prompt: "persuade", options: ["說服", "猶豫", "承認", "避免"])
        let now = Date.now.timeIntervalSince1970 * 1000
        me = BattlePlayer(name: you.name, rating: you.rating, tier: you.tier, games: 12, wins: 7, losses: 4, draws: 1)
        guard step != "home" else { return }
        if step == "search" { phase = .searching; waited = 6; return }
        if step == "room" { phase = .room("K7Q3P9"); return }
        current = q
        var s = BattleState(id: "demo", status: "playing", rated: true, code: nil, round: 3, now: now, you: you, opponent: opp,
                            starts: now - 3200, ends: now + 6800, answered: false, opponentAnswered: true, question: q)
        phase = .playing
        if step == "count" { s.round = 1; s.starts = now + 60_000; s.question = nil; current = nil }
        if step == "reveal" {
            picks[3] = 0
            s.round = 4; s.starts = now + 60_000; s.ends = now + 70_000; s.question = nil
            s.last = .init(n: 3, answer: 0, term: "persuade", zh: "說服", pick: 0, points: 84, opponentPick: 2, opponentPoints: 0)
        }
        if step == "result" {
            s.status = "finished"
            s.result = .init(outcome: "win", reason: "score", delta: 18, words: [
                .init(term: "persuade", zh: "說服", right: true), .init(term: "reluctant", zh: "不情願的", right: false),
                .init(term: "abandon", zh: "放棄", right: true), .init(term: "vivid", zh: "生動的", right: true),
                .init(term: "scarce", zh: "稀少的", right: false)])
            phase = .finished
        }
        state = s
    }
    #endif
}

// MARK: - Screens

struct BattleView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model: BattleModel?

    var body: some View {
        Group {
            if let model { content(model) } else { Color.clear }
        }
        .themedBackground()
        .onAppear {
            guard model == nil else { return }
            let m = BattleModel(level: settings.level)
            model = m
            #if DEBUG
            if let step = ProcessInfo.processInfo.environment["JUANGO_BATTLE"] { m.demo(step); return }
            #endif
            Task { await m.load() }
        }
        .onChange(of: model?.phase) { _, p in UIApplication.shared.isIdleTimerDisabled = p == .playing }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder private func content(_ m: BattleModel) -> some View {
        switch m.phase {
        case .home: BattleHome(model: m) { dismiss() }
        case .searching: BattleSearching(model: m)
        case .room(let code): BattleRoom(code: code, model: m)
        case .playing: BattleGame(model: m)
        case .finished: BattleResult(model: m)
        }
    }
}

private struct BattleHome: View {
    let model: BattleModel
    let close: () -> Void
    @State private var code = ""
    @State private var renaming = false
    @FocusState private var typing: Bool
    private var cloud: Cloud { .shared }
    private var cleanCode: String { code.uppercased().filter { $0.isLetter || $0.isNumber } }

    var body: some View {
        NavigationStack {
            List { Group {
                if cloud.signedIn || model.me != nil {
                    Section { playerCard }
                    Section {
                        Button { model.find() } label: { Label("開始配對", pulso: "bolt.fill") }
                            .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("優先配對積分相近的真人，等 15 秒沒有真人就和電腦對戰。5 回合，每題 10 秒，答對越快分數越高，最後一題 1.5 倍。")
                    }
                    Section("和朋友對戰") {
                        Button { model.createRoom() } label: { Label("建立房間", pulso: "person.2.fill") }
                        HStack {
                            TextField("輸入 6 碼房間代碼", text: $code)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .focused($typing).submitLabel(.join)
                                .onSubmit { if cleanCode.count == 6 { model.join(cleanCode) } }
                            Button("加入") { model.join(cleanCode) }.disabled(cleanCode.count != 6)
                        }
                    }
                } else {
                    Section {
                        NavigationLink { AccountView() } label: { Text("登入後就能對戰") }
                    } footer: {
                        Text("對手只會看到你的對戰名稱和積分，不會看到 Email。")
                    }
                }
            }.listRowBackground(Color.cardFill) }
            .font(.app(.body))
            .scrollDismissesKeyboard(.immediately)
            .themedBackground()
            .navigationTitle("單字對戰")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close, action: close) } }
            .task(id: cloud.signedIn) { await model.load() }
            .sheet(isPresented: $renaming) { BattleRename(model: model) }
            .alert("無法對戰", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(model.error ?? "") }
        }
    }

    @ViewBuilder private var playerCard: some View {
        if let p = model.me {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.name).font(.app(.headline))
                    Button { renaming = true } label: {
                        LIcon("pencil").font(.app(.subheadline, .semibold)).foregroundStyle(Color.themeAccent)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("修改對戰名稱")
                    Spacer()
                    Text(levelLabel(String(p.tier))).font(.app(.subheadline, .semibold)).foregroundStyle(Color.themeAccent)
                }
                Text(verbatim: String(p.rating)).font(.app(size: 44, .bold)).monospacedDigit()
                Text("\(p.wins) 勝　\(p.losses) 敗　\(p.draws) 和").font(.app(.subheadline)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
        } else if model.meFailed {
            Button("讀不到積分，再試一次") { Task { await model.load() } }
        } else {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
        }
    }
}

private struct BattleRename: View {
    let model: BattleModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var problem: String?
    @FocusState private var typing: Bool

    init(model: BattleModel) {
        self.model = model
        _name = State(initialValue: model.me?.name ?? "")
    }

    private var clean: String { name.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private var valid: Bool { (2...12).contains(clean.unicodeScalars.count) }

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    TextField("對戰名稱", text: $name)
                        .autocorrectionDisabled().focused($typing).submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    Text(problem ?? "2 到 12 個字，對手會看到這個名稱。")
                }
            }.listRowBackground(Color.cardFill) }
            .font(.app(.body))
            .themedBackground()
            .navigationTitle("對戰名稱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(role: .confirm, action: save).disabled(!valid || saving) }
            }
            .onAppear { typing = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard valid, !saving else { return }
        saving = true
        Task {
            problem = await model.rename(clean)
            saving = false
            if problem == nil { dismiss() }
        }
    }
}

private struct BattleSearching: View {
    let model: BattleModel
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("正在尋找對手").font(.app(.title3, .semibold))
            Text("已等待 \(model.waited) 秒，15 秒內沒有真人會改配電腦")
                .font(.app(.subheadline)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Button("取消") { model.leave() }.buttonStyle(PillButtonStyle())
        }
        .padding(24)
    }
}

private struct BattleRoom: View {
    let code: String
    let model: BattleModel
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("房間代碼").font(.app(.subheadline)).foregroundStyle(.secondary)
            Text(code).font(.app(size: 44, .bold)).monospaced().kerning(4).textSelection(.enabled)
            Text("請朋友到「單字對戰」輸入代碼，加入後立刻開始。朋友對戰不影響積分。")
                .font(.app(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ShareLink(item: "來捲字 JuanGo 和我對戰，房間代碼：\(code)") { Label("傳給朋友", pulso: "square.and.arrow.up") }
                .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
            Spacer()
            Button("關閉房間") { model.leaveRoom(code) }.buttonStyle(PillButtonStyle())
        }
        .padding(24)
    }
}

private struct BattleGame: View {
    let model: BattleModel
    @Environment(AppSettings.self) private var settings
    @State private var confirmLeave = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if let s = model.state { page(s, now: model.serverNow) }
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .confirmationDialog("離開這場對戰？", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("離開並判負", role: .destructive) { model.leave() }
        } message: { Text("對戰進行中離開會算輸。") }
        .sensoryFeedback(trigger: model.state?.last?.n) { _, _ in
            guard settings.haptics, let l = model.state?.last else { return nil }
            return l.pick == l.answer ? .success : .error
        }
    }

    @ViewBuilder private func page(_ s: BattleState, now: Double) -> some View {
        let reveal = revealing(s, now: now)
        VStack(spacing: 14) {
            header(s, reveal: reveal)
            scoreboard(s)
            if let r = reveal {
                timeBar(0)
                question(r.q, s: s, last: r.last)
                pointsLine(r.last)
            } else if let q = model.current, q.n == s.round, let starts = s.starts, now >= starts, let ends = s.ends {
                timeBar(max(0, min(1, (ends - now) / 10_000)))
                question(q, s: s, last: nil)
                waitingLine(s, timeUp: now >= ends, picked: model.picks[q.n] != nil)
            } else {
                Spacer()
                let left = max(1, Int(ceil(((s.starts ?? now) - now) / 1000)))
                Text("\(left)").font(.app(size: 72, .bold)).monospacedDigit().contentTransition(.numericText())
                Text(s.round == 1 ? "準備開始" : "下一題").font(.app(.headline)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    /// The closed round stays up until the next one starts (and after the last one, until the result).
    private func revealing(_ s: BattleState, now: Double) -> (q: BattleState.Question, last: BattleState.Last)? {
        guard let l = s.last, s.status == "finished" || now < (s.starts ?? 0),
              let q = [model.current, model.previous].compactMap({ $0 }).first(where: { $0.n == l.n }) else { return nil }
        return (q, l)
    }

    private func header(_ s: BattleState, reveal: (q: BattleState.Question, last: BattleState.Last)?) -> some View {
        let n = reveal?.q.n ?? s.round
        return HStack {
            Button { confirmLeave = true } label: { LIcon("xmark").frame(width: 44, height: 44).contentShape(.circle) }
                .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle).accessibilityLabel("離開對戰")
            Spacer()
            Text(n == 5 ? "最後一題 ×1.5" : "第 \(n) / 5 題")
                .font(.app(.headline)).foregroundStyle(n == 5 ? Color.themeAccent : .primary)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func scoreboard(_ s: BattleState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            side(s.you, trailing: false, done: false)
            Text("VS").font(.app(.caption, .bold)).foregroundStyle(.tertiary).padding(.top, 8)
            if let o = s.opponent { side(o, trailing: true, done: s.opponentAnswered == true && s.last?.n != s.round) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.cardFill))
    }

    private func side(_ p: BattleState.Side, trailing: Bool, done: Bool) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(p.name).font(.app(.caption, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text("\(p.score)").font(.app(size: 30, .bold)).monospacedDigit().contentTransition(.numericText())
            Text(verbatim: done ? "已作答" : "\(levelLabel(String(p.tier)))・\(p.rating)")
                .font(.app(.caption)).foregroundStyle(done ? Color.themeAccent : .secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    private func timeBar(_ left: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.themeAccent.opacity(0.14))
                Capsule().fill(left < 0.3 ? Color.hsnuMagenta : Color.themeAccent).frame(width: g.size.width * left)
            }
        }
        .frame(height: 8)
        .accessibilityLabel("剩餘 \(Int(ceil(left * 10))) 秒")
    }

    private func question(_ q: BattleState.Question, s: BattleState, last: BattleState.Last?) -> some View {
        VStack(spacing: 10) {
            Text(q.prompt).font(.app(size: q.toZh ? 40 : 32, .bold)).lineLimit(2).minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 110)
            ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                AnswerOption(letter: String(UnicodeScalar(65 + i)!), text: o, state: optionState(i, q: q, last: last)) {
                    model.answer(i)
                }
                .allowsHitTesting(last == nil && model.picks[q.n] == nil && q.n == s.round)
            }
        }
    }

    private func optionState(_ i: Int, q: BattleState.Question, last: BattleState.Last?) -> AnswerOption.State {
        let mine = last?.pick ?? model.picks[q.n]
        if let last { return i == last.answer ? .right : i == mine ? .wrong : .used }
        guard let mine else { return .idle }
        return i == mine ? .idle : .used
    }

    private func pointsLine(_ l: BattleState.Last) -> some View {
        VStack(spacing: 2) {
            Text(l.points > 0 ? "+\(l.points)" : l.pick == nil ? "時間到" : "答錯了")
                .font(.app(.title2, .bold)).foregroundStyle(l.points > 0 ? Color.hsnuSky : Color.hsnuMagenta)
            Text("對手 +\(l.opponentPoints)").font(.app(.subheadline)).foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    private func waitingLine(_ s: BattleState, timeUp: Bool, picked: Bool) -> some View {
        Text(timeUp ? "時間到" : picked ? "等對手作答" : " ")
            .font(.app(.subheadline)).foregroundStyle(.secondary)
            .frame(maxHeight: .infinity)
    }
}

private struct BattleResult: View {
    let model: BattleModel
    @Environment(\.modelContext) private var ctx
    @State private var saved = false

    var body: some View {
        if let s = model.state, let r = s.result {
            List { Group {
                Section {
                    VStack(spacing: 8) {
                        Text(title(r)).font(.app(size: 36, .bold))
                        if r.reason == "left" { Text(r.outcome == "win" ? "對手離開了" : "你離開了這場對戰").font(.app(.subheadline)).foregroundStyle(.secondary) }
                        HStack(spacing: 18) {
                            Text("\(s.you.score)").font(.app(size: 40, .bold)).foregroundStyle(Color.themeAccent)
                            Text(":").font(.app(.title2)).foregroundStyle(.tertiary)
                            Text("\(s.opponent?.score ?? 0)").font(.app(size: 40, .bold))
                        }.monospacedDigit()
                        Text(s.opponent?.name ?? "").font(.app(.caption)).foregroundStyle(.secondary)
                        Text(ratingLine(s, r)).font(.app(.subheadline, .semibold)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                if !r.words.isEmpty {
                    Section("這場的單字") {
                        ForEach(r.words) { w in
                            HStack(spacing: 12) {
                                LIcon(w.right ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(w.right ? Color.hsnuSky : Color.hsnuMagenta)
                                    .accessibilityLabel(w.right ? "答對" : "答錯")
                                Text(w.term).font(.app(.headline))
                                Spacer()
                                Text(w.zh).font(.app(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }.listRowBackground(Color.cardFill) }
            .font(.app(.body))
            .safeAreaInset(edge: .bottom) { actions(r).padding(.horizontal, 20).padding(.bottom, 8) }
            .sensoryFeedback(r.outcome == "win" ? .success : .warning, trigger: true)
        }
    }

    private func actions(_ r: BattleState.Outcome) -> some View {
        let missed = r.words.filter { !$0.right }
        return VStack(spacing: 10) {
            if !missed.isEmpty {
                Button(saved ? "已加入我的單字" : "把答錯的字加入我的單字") {
                    for w in missed { if let e = Dictionary_.lookup(w.term) { Library.add(e, in: ctx) } }
                    try? ctx.save()
                    saved = true
                }
                .buttonStyle(PillButtonStyle()).disabled(saved)
            }
            Button("完成") { model.leave() }
                .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
        }
    }

    private func title(_ r: BattleState.Outcome) -> String {
        r.reason == "abandoned" ? "對戰中斷" : r.outcome == "win" ? "獲勝" : r.outcome == "loss" ? "落敗" : "平手"
    }

    private func ratingLine(_ s: BattleState, _ r: BattleState.Outcome) -> String {
        guard s.rated else { return "這場不計分" }
        return "積分 \(s.you.rating)（\(r.delta >= 0 ? "+" : "")\(r.delta)）・\(levelLabel(String(s.you.tier)))"
    }
}
