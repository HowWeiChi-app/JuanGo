import SwiftUI
import SwiftData

// MARK: - Server data

/// What supabase/battle.sql returns. The server keeps the answers, the clock and the scores;
/// the app only draws this and sends taps.
struct BattleState: Decodable {
    struct Side: Decodable {
        var name: String; var rating: Int; var tier: Int; var score: Int
        var pid: String? = nil
        var tierName: String? = nil
    }
    struct Question: Decodable, Equatable { var n: Int; var toZh: Bool; var prompt: String; var options: [String] }
    struct Last: Decodable {
        var n: Int, answer: Int, term: String, zh: String
        var pick: Int?, points: Int, opponentPick: Int?, opponentPoints: Int
    }
    struct Word: Decodable, Identifiable { var term: String, zh: String, right: Bool; var id: String { term } }
    /// one line of how the rating changed: 基本 +20, 對手較強 +2…
    struct Part: Decodable, Hashable { var label: String; var value: Int }
    struct Outcome: Decodable {
        var outcome: String, reason: String, delta: Int, words: [Word]
        var breakdown: [Part]? = nil
        var tierFrom: Int? = nil, tierNext: Int? = nil, nextName: String? = nil
    }

    var id: String, status: String, rated: Bool, code: String?, round: Int
    var now: Double
    var you: Side
    var opponent: Side?
    var starts: Double?, ends: Double?
    var answered: Bool?, opponentAnswered: Bool?
    var question: Question?
    var last: Last?
    var result: Outcome?
    var rounds: Int? = nil, roundMs: Int? = nil
    /// shown on the countdown, e.g. 你們今天已經對戰 3 場，這場不計分
    var note: String? = nil
}

struct BattlePlayer: Decodable {
    struct Badge: Decodable, Hashable { var season: String; var name: String }
    var name: String, rating: Int, tier: Int, games: Int, wins: Int, losses: Int, draws: Int
    var pid: String? = nil
    var tierName: String? = nil
    var tierFrom: Int? = nil, tierNext: Int? = nil, nextName: String? = nil
    /// "2026 S6", and on a season's last day the notice about tonight's settling
    var season: String? = nil, seasonNotice: String? = nil
    var open: Bool? = nil
    /// ranked matches left today on the free plan; nil with Pro
    var freeLeft: Int? = nil
    var hidden: Bool? = nil
    var badges: [Badge]? = nil
}

/// 第 2 級 used to be shown for the tier; the server now names it (尊貴鉑金…傳奇卷神).
func tierText(_ name: String?, _ tier: Int) -> String { name ?? levelLabel(String(tier)) }

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
    /// when this search began, for the clock on the search screen (the server's count only arrives once a second)
    private(set) var searchStarted = Date.now
    private(set) var current: BattleState.Question?
    private(set) var previous: BattleState.Question?
    private(set) var picks: [Int: Int] = [:]
    var error: String?

    /// server time minus this phone's time, from the request that came back fastest
    private var clockOffset: Double = 0
    private var bestTrip = Double.infinity
    private var loop: Task<Void, Never>?
    /// nil until the 18-question level test is done; the server then refuses to match the player
    private let level: Int?
    private var levelArg: Any { level.map { $0 as Any } ?? NSNull() }
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(level: String, tested: Bool) { self.level = tested ? Int(level) ?? 3 : nil }

    var serverNow: Double { Date.now.timeIntervalSince1970 * 1000 + clockOffset }

    /// A short timeout: one stuck request used to hold up the whole match (the countdown sat still until it gave up).
    private func call<T: Decodable>(_ name: String, _ args: [String: Any] = [:]) async throws -> T {
        try Self.decoder.decode(T.self, from: await Cloud.shared.rpc(name, args, timeout: 5))
    }

    /// Returns what went wrong, or nil once the new name is saved.
    func rename(_ name: String) async -> String? {
        #if DEBUG
        if isDemo { me?.name = name; return nil }
        #endif
        do {
            me = try await call("battle_set_name", ["p_name": name, "p_level": levelArg])
            return nil
        } catch {
            return Self.clean(error)
        }
    }

    static let reportReasons = [("vulgar", "不雅"), ("offensive", "冒犯"), ("impersonation", "冒充他人"), ("other", "其他")]

    /// Returns what went wrong, or nil once the report is in.
    func report(_ pid: String, _ reason: String) async -> String? {
        #if DEBUG
        if isDemo { return nil }
        #endif
        do { _ = try await Cloud.shared.rpc("battle_report", ["p_pid": pid, "p_reason": reason], timeout: 10); return nil }
        catch { return Self.clean(error) }
    }

    func block(_ pid: String) async -> String? {
        #if DEBUG
        if isDemo { return nil }
        #endif
        do { _ = try await Cloud.shared.rpc("battle_block", ["p_pid": pid], timeout: 10); return nil }
        catch { return Self.clean(error) }
    }

    func board() async throws -> BattleBoard {
        #if DEBUG
        if isDemo { return .demo }
        #endif
        return try await call("battle_board")
    }

    static func clean(_ e: Error) -> String {
        e.localizedDescription.replacingOccurrences(of: "（\\d+）$", with: "", options: .regularExpression)
    }

    func load() async {
        #if DEBUG
        if isDemo { return }
        #endif
        guard Cloud.shared.signedIn else { me = nil; return }
        do {
            me = try await call("battle_me", ["p_level": levelArg])
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
                    let t: BattleTicket = try await call("battle_find", ["p_level": levelArg])
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
                let t: BattleTicket = try await call("battle_create_room", ["p_level": levelArg])
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
                let t: BattleTicket = try await call("battle_join", ["p_code": code, "p_level": levelArg])
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
            try? await Task.sleep(for: .milliseconds(nextPoll()))
        }
    }

    /// Half a second, or sooner when the next question becomes available (a second before it starts) or the
    /// round's time runs out, so the countdown never sits on 1 waiting for the next fetch.
    private func nextPoll() -> Int {
        guard let s = state, s.status == "playing" else { return 500 }
        let now = serverNow
        let marks = [s.starts.map { $0 - 900 }, s.ends.map { $0 + 60 }].compactMap { $0 }.filter { $0 > now }
        guard let next = marks.min() else { return 500 }
        return Int(min(500, max(80, next - now)))
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
        #if DEBUG
        autoReport(s)
        #endif
        if let q = s.question, q.n != current?.n {
            previous = current; current = q
            #if DEBUG
            autoplay(q, starts: s.starts)
            #endif
        }
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
                #if DEBUG
                autoNext()
                #endif
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

    #if DEBUG
    // MARK: Auto-play for testing (tools/battle_autoplay.sh)
    // `JUANGO_BATTLE_AUTOPLAY=0.7` opens 單字對戰, finds a ranked match, picks the right answer 0.7 s after each
    // question opens, and starts the next match a few seconds after each one ends, until the app is stopped.
    // Every step is written to stderr, which `devicectl … --console` shows in the terminal.

    static let autoDelay: Double? = ProcessInfo.processInfo.environment["JUANGO_BATTLE_AUTOPLAY"].flatMap(Double.init)
    @ObservationIgnored private var reported = 0
    @ObservationIgnored private var games = 0
    @ObservationIgnored private var wins = 0

    static func log(_ line: String) {
        let t = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        FileHandle.standardError.write(Data("[\(t)] \(line)\n".utf8))
    }

    func autoFind() {
        guard Self.autoDelay != nil else { return }
        guard Cloud.shared.signedIn else { Self.log("沒有登入，不能對戰：先在 App 裡登入"); return }
        games += 1
        Self.log("—— 第 \(games) 場：開始配對 ——")
        reported = 0
        find()
    }

    private func autoNext() {
        guard Self.autoDelay != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if phase == .finished { autoFind() }
        }
    }

    private func autoplay(_ q: BattleState.Question, starts: Double?) {
        guard let delay = Self.autoDelay else { return }
        let options = q.options.enumerated().map { "\(Character(UnicodeScalar(65 + $0.offset)!)) \($0.element)" }.joined(separator: "  ")
        guard let pick = Self.rightOption(q) else {
            Self.log("第 \(q.n) 題：\(q.prompt)｜\(options)｜字典判斷不出答案，不作答")
            return
        }
        Task {
            let wait = (starts ?? serverNow) + delay * 1000 - serverNow
            if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait))) }
            answer(pick)
            Self.log("第 \(q.n) 題：\(q.prompt)｜\(options)｜選 \(Character(UnicodeScalar(65 + pick)!)) \(q.options[pick])")
        }
    }

    /// Logs the opponent once the match starts, each round's result as it closes, and the outcome.
    private func autoReport(_ s: BattleState) {
        guard Self.autoDelay != nil else { return }
        if reported == 0, let o = s.opponent {
            reported = -1
            Self.log("配對到 \(o.name)（\(tierText(o.tierName, o.tier))・\(o.rating)），\(s.rated ? "排位" : "不計分")")
        }
        if let l = s.last, l.n > max(reported, 0) {
            reported = l.n
            let mine = l.points > 0 ? "答對 +\(l.points)" : l.pick == nil ? "沒作答" : "答錯（正解 \(l.term) \(l.zh)）"
            Self.log("　→ \(mine)｜對手 +\(l.opponentPoints)｜比分 \(s.you.score) : \(s.opponent?.score ?? 0)")
        }
        if s.status == "finished", let r = s.result, reported != Int.max {
            reported = Int.max
            if r.outcome == "win" { wins += 1 }
            let word = ["win": "贏了", "loss": "輸了", "draw": "平手"][r.outcome] ?? r.outcome
            let delta = r.delta > 0 ? "+\(r.delta)" : "\(r.delta)"
            Self.log("結果：\(word)（\(r.reason)），積分 \(delta) → \(s.you.rating + r.delta)｜目前 \(wins) 勝 / \(games) 場，5 秒後下一場")
        }
    }

    /// The right option worked out from the dictionary, since the server only says which it was afterwards.
    static func rightOption(_ q: BattleState.Question) -> Int? {
        func meanings(_ term: String) -> [String] { Dictionary_.lookup(term)?.zh ?? [] }
        func matches(_ zh: String, _ list: [String]) -> Bool {
            list.contains { $0 == zh || $0.contains(zh) || zh.contains($0) }
        }
        if q.toZh {
            let zh = meanings(q.prompt)
            return q.options.firstIndex { matches($0, zh) }
        }
        return q.options.firstIndex { matches(q.prompt, meanings($0)) }
    }
    #endif

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
        phase = p; state = nil; current = nil; previous = nil; picks = [:]; waited = 0; error = nil; searchStarted = .now
        bestTrip = .infinity
    }

    private func fail(_ e: Error) {
        guard !Task.isCancelled else { return }
        reset(.home)
        error = e.localizedDescription
        #if DEBUG
        if Self.autoDelay != nil {
            Self.log("出錯了：\(Self.clean(e))，10 秒後重新配對")
            Task { try? await Task.sleep(for: .seconds(10)); if phase == .home { autoFind() } }
        }
        #endif
    }

    #if DEBUG
    private(set) var isDemo = false

    /// JUANGO_BATTLE=home | search | room | count | question | reveal | result draws a screen without the server.
    func demo(_ step: String) {
        isDemo = true
        let opp = BattleState.Side(name: "柚子", rating: 1236, tier: 3, score: step == "result" ? 612 : 170, pid: "demo-opp", tierName: "至尊星耀")
        let you = BattleState.Side(name: "勇敢的水獺08", rating: 1218, tier: 3, score: step == "result" ? 705 : 188, pid: "demo-me", tierName: "至尊星耀")
        let q = BattleState.Question(n: 3, toZh: true, prompt: "persuade", options: ["說服", "猶豫", "承認", "避免"])
        let now = Date.now.timeIntervalSince1970 * 1000
        me = BattlePlayer(name: you.name, rating: you.rating, tier: you.tier, games: 12, wins: 7, losses: 4, draws: 1,
                          pid: "demo-me", tierName: "至尊星耀", tierFrom: 1200, tierNext: 1400, nextName: "無雙卷哥",
                          season: "2026 S6", open: true, freeLeft: 7, hidden: false)
        guard step != "home" else { return }
        if step == "search" { phase = .searching; waited = 6; searchStarted = .now.addingTimeInterval(-6); return }
        if step == "room" { phase = .room("K7Q3"); return }
        current = q
        var s = BattleState(id: "demo", status: "playing", rated: true, code: nil, round: 3, now: now, you: you, opponent: opp,
                            starts: now - 3200, ends: now + 6800, answered: false, opponentAnswered: true, question: q,
                            rounds: 10, roundMs: 10_000)
        phase = .playing
        if step == "count" { s.round = 1; s.starts = now + 60_000; s.question = nil; current = nil }
        if step == "reveal" {
            picks[3] = 0
            s.round = 4; s.starts = now + 60_000; s.ends = now + 70_000; s.question = nil
            s.last = .init(n: 3, answer: 0, term: "persuade", zh: "說服", pick: 0, points: 84, opponentPick: 2, opponentPoints: 0)
        }
        if step == "result" {
            s.status = "finished"
            s.result = .init(outcome: "win", reason: "score", delta: 27, words: [
                .init(term: "persuade", zh: "說服", right: true), .init(term: "reluctant", zh: "不情願的", right: false),
                .init(term: "abandon", zh: "放棄", right: true), .init(term: "vivid", zh: "生動的", right: true),
                .init(term: "scarce", zh: "稀少的", right: false)],
                breakdown: [.init(label: "基本", value: 20), .init(label: "對手較強", value: 2), .init(label: "表現", value: 3),
                            .init(label: "3 連勝", value: 2)],
                tierFrom: 1200, tierNext: 1400, nextName: "無雙卷哥")
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
    /// showing the level test (kept up through its result page, after levelTested is already set)
    @State private var placing = false

    var body: some View {
        Group {
            if placing {
                placement
            } else if let model { content(model) } else { Color.clear }
        }
        .themedBackground()
        .onAppear {
            placing = !settings.levelTested
            #if DEBUG
            if ProcessInfo.processInfo.environment["JUANGO_BATTLE"] != nil { placing = false }
            #endif
            if !placing { start() }
        }
        .onChange(of: model?.phase) { _, p in UIApplication.shared.isIdleTimerDisabled = p == .playing }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// Everyone takes the 18-question level test once before their first battle, so ratings start where they belong.
    private var placement: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("對戰前先測程度").font(.app(.title2, .bold))
                    Text("做完 18 題，積分會從你的程度開始。").font(.app(.subheadline)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { GlassCircleIcon(systemName: "xmark") }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
            }
            .padding(.horizontal, 20).padding(.top, 16)
            OnboardingView(testOnly: true) { _ in placing = false; start() }
        }
    }

    private func start() {
        guard model == nil else { return }
        let m = BattleModel(level: settings.level, tested: settings.levelTested)
        model = m
        #if DEBUG
        if let step = ProcessInfo.processInfo.environment["JUANGO_BATTLE"] { m.demo(step); return }
        if BattleModel.autoDelay != nil {
            BattleModel.log("自動對戰開始，每題 \(BattleModel.autoDelay!) 秒後作答；按 Ctrl-C 停止")
            Task { await m.load(); m.autoFind() }
            return
        }
        #endif
        Task { await m.load() }
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
                    if let n = model.me?.seasonNotice {
                        Section { Label(n, pulso: "moon.stars.fill").font(.app(.subheadline, .semibold)) }
                    }
                    Section {
                        playerCard
                        NavigationLink { BattleBoardView(model: model) } label: { Label("賽季排行", pulso: "list.number") }
                    } header: {
                        if let season = model.me?.season { Text(season) }
                    }
                    Section {
                        Button { model.find() } label: { Label("開始配對", pulso: "bolt.fill") }
                            .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
                            .disabled(model.me?.open == false || model.me?.freeLeft == 0)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("配對積分相近的對手，一共 10 題，每題 10 秒。答對 25 分，越快最多再加 75 分。")
                            if let left = model.me?.freeLeft {
                                Text(left > 0 ? "免費版今天還能打 \(left) 場排名賽。" : "今天的 10 場免費排名賽打完了，升級 Pro 就不限場次。")
                            }
                        }
                    }
                    Section("和朋友對戰") {
                        Button { model.createRoom() } label: { Label("建立房間", pulso: "person.2.fill") }
                        HStack {
                            TextField("輸入 4 碼房間代碼", text: $code)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                                .focused($typing).submitLabel(.join)
                                .onSubmit { if cleanCode.count == 4 { model.join(cleanCode) } }
                            Button("加入") { model.join(cleanCode) }.disabled(cleanCode.count != 4)
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
                    Text(tierText(p.tierName, p.tier)).font(.app(.subheadline, .semibold)).foregroundStyle(Color.themeAccent)
                }
                Text(verbatim: String(p.rating)).font(.app(size: 44, .bold)).monospacedDigit()
                TierProgress(rating: p.rating, from: p.tierFrom, next: p.tierNext, nextName: p.nextName)
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

/// Radar rings around the player, the clock and the rating range the search covers right now.
/// The clock runs on the phone, so it ticks every second whatever the network does.
private struct BattleSearching: View {
    let model: BattleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSince(model.searchStarted)
            VStack(spacing: 18) {
                Spacer()
                radar(t)
                VStack(spacing: 6) {
                    Text("正在尋找對手").font(.app(.title2, .bold))
                    Text(clock(t)).font(.app(.title3, .semibold)).monospacedDigit().foregroundStyle(Color.themeAccent)
                        .contentTransition(.numericText())
                }
                rangeChip(t)
                Spacer()
                Button("取消") { model.leave() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(24)
    }

    private func clock(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func radar(_ t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                // each ring grows out and fades over 2.4 s, a third of a cycle behind the one before
                let f = reduceMotion ? 0.35 + Double(i) * 0.25 : (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Circle().stroke(Color.themeAccent.opacity(0.5 * (1 - f)), lineWidth: 2)
                    .frame(width: 96 + 150 * f, height: 96 + 150 * f)
            }
            Circle().fill(Color.themeAccent.opacity(0.12)).frame(width: 120, height: 120)
            // a sweeping beam
            if !reduceMotion {
                Circle().trim(from: 0, to: 0.18)
                    .stroke(AngularGradient(colors: [Color.themeAccent.opacity(0), Color.themeAccent.opacity(0.55)], center: .center),
                            style: StrokeStyle(lineWidth: 60))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(t * 150))
                    .mask(Circle().frame(width: 120, height: 120))
            }
            Circle().fill(Color.themeAccent).frame(width: 76, height: 76)
                .overlay { Text(initial).font(.app(size: 30, .bold)).foregroundStyle(Color.onAccent) }
                .scaleEffect(reduceMotion ? 1 : 1 + 0.04 * sin(t * 4))
        }
        .frame(width: 250, height: 250)
        .accessibilityHidden(true)
    }

    private var initial: String { String(model.me?.name.first ?? "我") }

    /// The server starts at ±10 and widens the window by 10 a second, up to ±100.
    @ViewBuilder private func rangeChip(_ t: Double) -> some View {
        let s = Int(t)
        Group {
            if let r = model.me?.rating {
                let w = min(100, 10 + 10 * s)
                Text("積分 \(max(0, r - w))–\(r + w)").monospacedDigit()
            } else {
                Text("尋找積分相近的對手")
            }
        }
        .font(.app(.subheadline, .semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(Color.cardFill))
        .animation(.snappy, value: s)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                timeBar(nil, length: Double(s.roundMs ?? 10_000))
                question(r.q, s: s, last: r.last)
                pointsLine(r.last)
            } else if let q = model.current, q.n == s.round, let starts = s.starts, now >= starts, let ends = s.ends {
                timeBar(ends, length: Double(s.roundMs ?? 10_000))
                question(q, s: s, last: nil)
                waitingLine(s, timeUp: now >= ends, picked: model.picks[q.n] != nil)
            } else {
                Spacer()
                let left = max(1, Int(ceil(((s.starts ?? now) - now) / 1000)))
                if s.round == 1, s.last == nil { BattleIntro(you: s.you, opponent: s.opponent) }
                ZStack {
                    Text("\(left)").font(.app(size: 72, .bold)).monospacedDigit()
                        .id(left)
                        .transition(reduceMotion ? .opacity : .scale(scale: 1.8).combined(with: .opacity))
                }
                .animation(.spring(duration: 0.35, bounce: 0.4), value: left)
                Text(s.round == 1 ? "準備開始" : "下一題").font(.app(.headline)).foregroundStyle(.secondary)
                if s.round == 1, s.last == nil, let note = s.note {
                    Text(note).font(.app(.subheadline, .semibold)).foregroundStyle(Color.themeAccent)
                        .multilineTextAlignment(.center).padding(.top, 8)
                }
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
            Text("第 \(n) / \(s.rounds ?? 10) 題").font(.app(.headline)).monospacedDigit()
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
                .animation(.spring(duration: 0.6), value: p.score)
            Text(verbatim: done ? "已作答" : "\(tierText(p.tierName, p.tier))・\(p.rating)")
                .font(.app(.caption)).foregroundStyle(done ? Color.themeAccent : .secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    /// Redraws on every screen refresh (120 Hz on ProMotion) so the bar slides smoothly.
    private func timeBar(_ ends: Double?, length: Double) -> some View {
        TimelineView(.animation(paused: ends == nil)) { _ in
            let left = ends.map { max(0, min(1, ($0 - model.serverNow) / length)) } ?? 0
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.themeAccent.opacity(0.14))
                    Capsule().fill(left < 0.3 ? Color.hsnuMagenta : Color.themeAccent).frame(width: g.size.width * left)
                }
            }
            .frame(height: 8)
            .accessibilityLabel("剩餘 \(Int(ceil(left * length / 1000))) 秒")
        }
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
                .modifier(StaggerIn(index: i, key: q.n))
            }
        }
        .modifier(StaggerIn(index: -1, key: q.n))
    }

    private func optionState(_ i: Int, q: BattleState.Question, last: BattleState.Last?) -> AnswerOption.State {
        let mine = last?.pick ?? model.picks[q.n]
        if let last { return i == last.answer ? .right : i == mine ? .wrong : .used }
        guard let mine else { return .idle }
        return i == mine ? .idle : .used
    }

    private func pointsLine(_ l: BattleState.Last) -> some View {
        VStack(spacing: 2) {
            PopIn(key: l.n) {
                Text(l.points > 0 ? "+\(l.points)" : l.pick == nil ? "時間到" : "答錯了")
                    .font(.app(.title2, .bold)).foregroundStyle(l.points > 0 ? Color.hsnuSky : Color.hsnuMagenta)
                    .monospacedDigit().lineLimit(1).fixedSize()   // "+83" was cut to "+…"
            }
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
    @State private var practice: StudyRequest?

    var body: some View {
        if let s = model.state, let r = s.result {
            List { Group {
                Section {
                    VStack(spacing: 8) {
                        PopIn(key: 0) {
                            VStack(spacing: 6) {
                                if r.outcome == "win" && r.reason != "abandoned" {
                                    LIcon("trophy.fill").font(.app(size: 40)).foregroundStyle(Color.themeAccent)
                                }
                                Text(title(r)).font(.app(size: 36, .bold))
                            }
                        }
                        if r.reason == "left" { Text(r.outcome == "win" ? "對手離開了" : "你離開了這場對戰").font(.app(.subheadline)).foregroundStyle(.secondary) }
                        HStack(spacing: 18) {
                            Text("\(s.you.score)").font(.app(size: 40, .bold)).foregroundStyle(Color.themeAccent)
                            Text(":").font(.app(.title2)).foregroundStyle(.tertiary)
                            Text("\(s.opponent?.score ?? 0)").font(.app(size: 40, .bold))
                        }.monospacedDigit()
                        if let o = s.opponent {
                            HStack(spacing: 4) {
                                Text(o.name)
                                if o.pid != nil { LIcon("ellipsis.circle") }
                            }
                            .font(.app(.caption)).foregroundStyle(.secondary)
                            .modifier(PlayerMenu(pid: o.pid, name: o.name, model: model))
                        }
                        Text(ratingLine(s, r)).font(.app(.subheadline, .semibold)).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                if s.rated, let parts = r.breakdown, !parts.isEmpty {
                    Section("這局的積分") {
                        ForEach(parts, id: \.self) { p in
                            LabeledContent(p.label, value: signed(p.value)).monospacedDigit()
                        }
                        LabeledContent { Text(signed(r.delta)).font(.app(.body, .bold)).monospacedDigit() } label: {
                            Text("合計").font(.app(.body, .bold))
                        }
                        TierProgress(rating: s.you.rating, from: r.tierFrom, next: r.tierNext, nextName: r.nextName)
                            .padding(.vertical, 4)
                    }
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
            .fullScreenCover(item: $practice) { StudyFlow(request: $0) }
            .sensoryFeedback(r.outcome == "win" ? .success : .warning, trigger: true)
        }
    }

    private func actions(_ r: BattleState.Outcome) -> some View {
        let missed = r.words.filter { !$0.right }
        return VStack(spacing: 10) {
            if !missed.isEmpty {
                HStack(spacing: 10) {
                    Button("只練答錯的字") {
                        // the words go into 我的單字 so the practice keeps their progress
                        let words = missed.compactMap { w in Dictionary_.lookup(w.term).map { Library.add($0, in: ctx) } }
                        try? ctx.save()
                        saved = true
                        if !words.isEmpty { practice = StudyRequest(title: "答錯的字", words: words) }
                    }
                    .buttonStyle(PillButtonStyle())
                    Button(saved ? "已加入單字" : "加入我的單字") {
                        for w in missed { if let e = Dictionary_.lookup(w.term) { Library.add(e, in: ctx) } }
                        try? ctx.save()
                        saved = true
                    }
                    .buttonStyle(PillButtonStyle()).disabled(saved)
                }
            }
            Button("完成") { model.leave() }
                .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
        }
    }

    private func title(_ r: BattleState.Outcome) -> String {
        r.reason == "abandoned" ? "對戰中斷" : r.outcome == "win" ? "獲勝" : r.outcome == "loss" ? "落敗" : "平手"
    }

    private func ratingLine(_ s: BattleState, _ r: BattleState.Outcome) -> String {
        guard s.rated else { return s.note ?? "這場不計分" }
        return "積分 \(s.you.rating)（\(signed(r.delta))）・\(tierText(s.you.tierName, s.you.tier))"
    }

    private func signed(_ v: Int) -> String { v > 0 ? "+\(v)" : v < 0 ? "−\(-v)" : "0" }
}

// MARK: - Motion

/// Both players slide in from their sides with a VS between them, before the first question.
private struct BattleIntro: View {
    let you: BattleState.Side
    let opponent: BattleState.Side?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            card(you, leading: true).offset(x: shown || reduceMotion ? 0 : -260)
            Text("VS").font(.app(size: 28, .heavy)).foregroundStyle(Color.themeAccent)
                .scaleEffect(shown || reduceMotion ? 1 : 0.2).opacity(shown ? 1 : 0)
            if let opponent { card(opponent, leading: false).offset(x: shown || reduceMotion ? 0 : 260) }
        }
        .padding(.bottom, 24)
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.35)) { shown = true } }
        .sensoryFeedback(.impact(weight: .heavy), trigger: shown)
    }

    private func card(_ p: BattleState.Side, leading: Bool) -> some View {
        VStack(spacing: 6) {
            Circle().fill(leading ? Color.themeAccent : Color.secondary.opacity(0.35)).frame(width: 56, height: 56)
                .overlay { Text(String(p.name.first ?? "?")).font(.app(size: 24, .bold)).foregroundStyle(leading ? Color.onAccent : .primary) }
            Text(p.name).font(.app(.subheadline, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(verbatim: "\(tierText(p.tierName, p.tier))・\(p.rating)").font(.app(.caption)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.cardFill))
    }
}

/// Slides a question's parts up into place one after another when a new question (key) comes in.
private struct StaggerIn: ViewModifier {
    let index: Int
    let key: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 18)
            .onAppear { appear() }
            .onChange(of: key) { shown = false; appear() }
    }

    private func appear() {
        withAnimation(.spring(duration: 0.4).delay(Double(index + 1) * 0.05)) { shown = true }
    }
}

/// Pops its content in with a bounce.
private struct PopIn<C: View>: View {
    let key: Int
    @ViewBuilder let content: C
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : 0.4).opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(duration: 0.45, bounce: 0.5)) { shown = true } }
            .onChange(of: key) { shown = false; withAnimation(.spring(duration: 0.45, bounce: 0.5)) { shown = true } }
    }
}

// MARK: - Tiers, reports and the season board

/// How far the rating is through its tier, and how many points to the next one.
private struct TierProgress: View {
    let rating: Int
    let from: Int?
    let next: Int?
    let nextName: String?

    var body: some View {
        if let from, let next, next > from {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(1, max(0, Double(rating - from) / Double(next - from)))).tint(Color.themeAccent)
                Text("離\(nextName ?? "下一段")還差 \(max(0, next - rating)) 分")
                    .font(.app(.caption)).foregroundStyle(.secondary).monospacedDigit()
            }
        } else if from != nil {
            Text("已經是最高段位").font(.app(.caption)).foregroundStyle(.secondary)
        }
    }
}

/// Long press on a player's name: 檢舉暱稱 (four reasons, then an offer to block too) or 封鎖這位玩家.
private struct PlayerMenu: ViewModifier {
    let pid: String?
    let name: String
    let model: BattleModel
    @State private var reporting = false
    @State private var askBlock = false
    @State private var message: String?

    func body(content: Content) -> some View {
        if let pid, pid != model.me?.pid {
            content
                .contextMenu {
                    Button("檢舉暱稱", pulso: "exclamationmark.bubble") { reporting = true }
                    Button("封鎖這位玩家", pulso: "hand.raised", role: .destructive) { block(pid) }
                }
                .confirmationDialog("檢舉「\(name)」這個暱稱", isPresented: $reporting, titleVisibility: .visible) {
                    ForEach(BattleModel.reportReasons, id: \.0) { r in
                        Button(r.1) {
                            Task {
                                if let e = await model.report(pid, r.0) { message = e } else { askBlock = true }
                            }
                        }
                    }
                }
                .alert("謝謝，我們會處理", isPresented: $askBlock) {
                    Button("一併封鎖", role: .destructive) { block(pid) }
                    Button("不用", role: .cancel) {}
                } message: { Text("要不要一併封鎖這位玩家？") }
                .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                    Button("好", role: .cancel) {}
                }
        } else {
            content
        }
    }

    private func block(_ pid: String) {
        Task { message = await model.block(pid) ?? "已封鎖。之後不會再配到對方，排行榜上也會顯示成匿名玩家。" }
    }
}

/// What battle_board returns: this season live (10 games to be listed) and last season's final board (60 games).
struct BattleBoard: Decodable {
    struct Row: Decodable, Identifiable {
        var rank: Int?
        var name: String?
        var pid: String?
        var rating: Int
        var tierName: String
        var winRate: Double
        var me: Bool?
        var games: Int?
        var id: String { "\(rank ?? -1)-\(pid ?? name ?? "me")" }
    }
    struct Season: Decodable {
        var top: [Row]
        var me: Row?
    }
    var season: String
    var previous: String
    var hasPrevious: Bool
    var minGames: Int
    var liveMinGames: Int
    var current: Season
    var last: Season

    #if DEBUG
    static let demo = BattleBoard(season: "2026 S6", previous: "2026 S5", hasPrevious: true, minGames: 60, liveMinGames: 10,
        current: Season(top: [
            Row(rank: 1, name: "單字狂人", pid: "d1", rating: 1684, tierName: "璀璨卷王", winRate: 0.71),
            Row(rank: 2, name: "柚子", pid: "d2", rating: 1522, tierName: "無雙卷哥", winRate: 0.66),
            Row(rank: 3, name: "匿名玩家", rating: 1407, tierName: "無雙卷哥", winRate: 0.63),
            Row(rank: 4, name: "勇敢的水獺08", pid: "demo-me", rating: 1218, tierName: "至尊星耀", winRate: 0.58, me: true),
        ], me: Row(rank: 4, rating: 1218, tierName: "至尊星耀", winRate: 0.58, games: 12)),
        last: Season(top: [
            Row(rank: 1, name: "單字狂人", pid: "d1", rating: 2214, tierName: "傳奇卷神", winRate: 0.71),
            Row(rank: 2, name: "柚子", pid: "d2", rating: 1987, tierName: "傳奇卷神", winRate: 0.66),
        ], me: nil))
    #endif
}

struct BattleBoardView: View {
    let model: BattleModel
    @State private var board: BattleBoard?
    @State private var failed: String?

    var body: some View {
        List { Group {
            if let b = board {
                Section {
                    rows(b.current, min: b.liveMinGames, empty: "還沒有人打滿 \(b.liveMinGames) 場排名賽")
                } header: { Text("\(b.season) 即時排名") } footer: {
                    Text("本賽季打滿 \(b.liveMinGames) 場排名賽就會上榜，名次隨時更新。勝率含電腦局。長按暱稱可以檢舉或封鎖。")
                }
                Section {
                    if !b.hasPrevious {
                        Text("第一季，還沒有排名").foregroundStyle(.secondary)
                    } else {
                        rows(b.last, min: b.minGames, empty: "上賽季沒有人打滿 \(b.minGames) 場")
                    }
                } header: { Text("\(b.previous) 最終排名") } footer: {
                    Text("上賽季打滿 \(b.minGames) 場排名賽才會列入。")
                }
            } else if let failed {
                Button("讀不到排行，再試一次") { Task { await load() } }
                Text(failed).font(.app(.footnote)).foregroundStyle(.secondary)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
            }
        }.listRowBackground(Color.cardFill) }
        .font(.app(.body))
        .themedBackground()
        .navigationTitle("賽季排行")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { board = try await model.board(); failed = nil } catch { failed = BattleModel.clean(error) }
    }

    @ViewBuilder private func rows(_ s: BattleBoard.Season, min: Int, empty: String) -> some View {
        if s.top.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        }
        ForEach(s.top) { row($0, min: min) }
        if let me = s.me, !s.top.contains(where: { $0.me == true }) { row(me, mine: true, min: min) }
    }

    @ViewBuilder private func row(_ r: BattleBoard.Row, mine: Bool = false, min: Int) -> some View {
        let name = mine ? (model.me?.name ?? "你") : (r.name ?? "匿名玩家")
        HStack(spacing: 12) {
            Text(r.rank.map(String.init) ?? "–").font(.app(.headline)).monospacedDigit()
                .frame(minWidth: 28, alignment: .leading)
                .foregroundStyle(r.rank.map { $0 <= 3 } == true ? Color.themeAccent : .primary)
            Circle().fill(mine || r.me == true ? Color.themeAccent : Color.secondary.opacity(0.3)).frame(width: 34, height: 34)
                .overlay {
                    Text(String(r.pid == nil && !mine && r.me != true ? "?" : name.first.map(String.init) ?? "?"))
                        .font(.app(.subheadline, .bold))
                        .foregroundStyle(mine || r.me == true ? Color.onAccent : .primary)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.app(.subheadline, .semibold)).lineLimit(1)
                Text(mine && r.rank == nil
                     ? "場數不足（\(r.games ?? 0) / \(min) 場）"
                     : "\(r.tierName)・勝率 \(Int((r.winRate * 100).rounded()))%")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: String(r.rating)).font(.app(.headline)).monospacedDigit()
        }
        .modifier(PlayerMenu(pid: mine ? nil : r.pid, name: name, model: model))
    }
}

/// 設定 › 單字對戰: hide from the leaderboard, and the blocked players.
struct BattleSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var hidden = false
    @State private var loaded = false
    @State private var blocked: [Blocked]?
    @State private var error: String?

    struct Blocked: Decodable, Identifiable { var id: Int; var name: String? }
    private struct Me: Decodable { var hidden: Bool? }
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private var levelArg: Any { settings.levelTested ? (Int(settings.level) ?? 3) as Any : NSNull() }

    var body: some View {
        Form { Group {
            Section {
                Toggle("不顯示在排行榜", isOn: $hidden).disabled(!loaded)
            } footer: {
                Text("開啟後，其他人在排行榜上看到的是「匿名玩家」，名次照算。")
            }
            Section {
                if let blocked {
                    if blocked.isEmpty {
                        Text("沒有封鎖任何玩家").foregroundStyle(.secondary)
                    } else {
                        ForEach(blocked) { b in Text(b.name ?? "玩家") }
                            .onDelete { idx in unblock(idx.map { blocked[$0] }) }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } header: { Text("已封鎖的玩家") } footer: {
                Text("封鎖後不會再配到對方，排行榜上對方會顯示成匿名玩家。向左滑可以解除封鎖。最多封鎖 200 人。")
            }
            if let error { Text(error).font(.app(.footnote)).foregroundStyle(.secondary) }
        }.listRowBackground(Color.cardFill) }
        .font(.app(.body))
        .themedBackground()
        .navigationTitle("單字對戰")
        .task { await load() }
        .onChange(of: hidden) { _, v in
            guard loaded else { return }
            Task {
                do { _ = try await Cloud.shared.rpc("battle_set_hidden", ["p_hidden": v], timeout: 10) }
                catch { self.error = BattleModel.clean(error) }
            }
        }
    }

    private func load() async {
        do {
            let me = try Self.decoder.decode(Me.self, from: await Cloud.shared.rpc("battle_me", ["p_level": levelArg], timeout: 10))
            hidden = me.hidden ?? false
            loaded = true
            blocked = try Self.decoder.decode([Blocked].self, from: await Cloud.shared.rpc("battle_blocked", timeout: 10))
            error = nil
        } catch {
            self.error = BattleModel.clean(error)
            if blocked == nil { blocked = [] }
        }
    }

    private func unblock(_ rows: [Blocked]) {
        blocked?.removeAll { r in rows.contains { $0.id == r.id } }
        Task {
            for r in rows { _ = try? await Cloud.shared.rpc("battle_unblock", ["p_id": r.id], timeout: 10) }
        }
    }
}
