import SwiftData
import SwiftUI
import UIKit

/// The app side of the free 1,000-word limit: counting saved words, and the alert when an add is stopped.
extension WordQuota {
    static func counts(_ w: Word) -> Bool {
        counts(cefr: w.cefr, fromExam: w.fromExam, inMyWords: w.inMyWords, favorite: w.favorite, inList: !w.lists.isEmpty)
    }

    static var unlimited: Bool { ProStore.shared.has(.words) }

    static func isOver(_ words: [Word]) -> Bool { !unlimited && words.filter(counts).count > limit }

    /// Words now taking one of the 1,000 places.
    static func used(in ctx: ModelContext) -> Int {
        let lv = examLevels
        let fd = FetchDescriptor<Word>(predicate: #Predicate {
            !$0.fromExam && !lv.contains($0.cefr) && ($0.inMyWords || $0.favorite || !$0.lists.isEmpty)
        })
        if let n = try? ctx.fetchCount(fd) { return n }
        return ((try? ctx.fetch(FetchDescriptor<Word>())) ?? []).filter(counts).count
    }

    static func hasRoom(in ctx: ModelContext) -> Bool { unlimited || used(in: ctx) < limit }

    /// Whether saving this entry (to 我的單字 when `myWords`, and to `list`) would take a new place.
    static func takesPlace(_ e: DictEntry, existing: Word?, myWords: Bool, list: WordList?) -> Bool {
        guard myWords || list != nil else { return false }
        if let existing {
            return !counts(existing) && counts(cefr: existing.cefr, fromExam: existing.fromExam, inMyWords: true,
                                              favorite: false, inList: false)
        }
        return counts(cefr: e.lv, fromExam: false, inMyWords: true, favorite: false, inList: false)
    }

    /// Of these entries, the ones that may still be added, in order.
    static func admitted(_ entries: [DictEntry], myWords: Bool = true, list: WordList? = nil, in ctx: ModelContext) -> [DictEntry] {
        if unlimited { return entries }
        var seen = Set<String>()
        let wanted = entries.map { e in
            let t = e.w.lowercased()
            guard seen.insert(t).inserted else { return false }
            return takesPlace(e, existing: Library.word(t, in: ctx), myWords: myWords, list: list)
        }
        return zip(entries, fit(wanted, used: used(in: ctx), unlimited: false)).filter(\.1).map(\.0)
    }

    /// For a word already in the store being put in 我的單字, 喜歡 or a list: false (and the card shows)
    /// when that would take a place there is no room for.
    static func admit(_ w: Word, in ctx: ModelContext) -> Bool {
        if counts(w) || !counts(cefr: w.cefr, fromExam: w.fromExam, inMyWords: true, favorite: false, inList: false)
            || hasRoom(in: ctx) { return true }
        QuotaGate.shared.stopped()
        return false
    }

    static func usage(in ctx: ModelContext) -> String? { usage(used(in: ctx), unlimited: unlimited) }
}

/// Shows 「免費版最多 1000 個單字…」 when `Library.add` turns a word away.
/// It is presented from UIKit on top of whatever is open, since words are added from sheets as well as tabs.
final class QuotaGate {
    static let shared = QuotaGate()
    /// set while a batch the user already agreed to cut short is being added, so the card doesn't show again
    private var quiet = false
    private weak var shown: UIViewController?

    func stopped() {
        guard !quiet, shown == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let vc = UIHostingController(rootView: QuotaFullCard()
            .environment(AppSettings.shared)
            .tint(AppSettings.shared.theme.accent)
            .fontDesign(AppSettings.shared.fontDesign)
            .font(.app(.body))
            .preferredColorScheme(AppSettings.shared.colorScheme))
        if let sheet = vc.sheetPresentationController {
            sheet.detents = [.custom { _ in 250 }]
            sheet.prefersGrabberVisible = true
        }
        shown = vc
        top.present(vc, animated: true)
    }

    /// Runs `body` without the card (the user was already told only part of it fits).
    func quietly(_ body: () -> Void) {
        quiet = true
        defer { quiet = false }
        body()
    }
}

private struct QuotaFullCard: View {
    @Environment(\.dismiss) private var dismiss
    @State private var paywall = false

    var body: some View {
        VStack(spacing: 14) {
            LIcon("tray.full.fill").font(.app(.title)).foregroundStyle(.tint)
            Text("單字已達上限").font(.app(.headline))
            Text(WordQuota.fullMessage).font(.app(.subheadline)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("升級 Pro") { paywall = true }.buttonStyle(PillButtonStyle())
            Button("好") { dismiss() }.font(.app(.subheadline, .semibold))
        }
        .padding(.horizontal, 24).padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .themedBackground()
        .sheet(isPresented: $paywall, onDismiss: { if ProStore.shared.isPro { dismiss() } }) { ProPaywall() }
    }
}

extension View {
    /// Asks 「只能加入前 N 個」 before adding a batch that only partly fits; `fits` is set by the caller.
    func quotaPartial(_ fits: Binding<Int?>, add: @escaping () -> Void) -> some View {
        confirmationDialog(fits.wrappedValue.map { "只能加入前 \($0) 個" } ?? "",
                           isPresented: Binding(get: { fits.wrappedValue != nil }, set: { if !$0 { fits.wrappedValue = nil } }),
                           titleVisibility: .visible) {
            Button("加入 \(fits.wrappedValue ?? 0) 個") { QuotaGate.shared.quietly(add) }
            Button("取消", role: .cancel) {}
        } message: { Text(WordQuota.fullMessage) }
    }
}

extension WordQuota {
    /// Before adding a batch: runs `add` when it all fits, shows the limit card when none does,
    /// otherwise returns how many fit for `quotaPartial`.
    static func batch(_ entries: [DictEntry], list: WordList?, in ctx: ModelContext, add: () -> Void) -> Int? {
        let fits = admitted(entries, list: list, in: ctx).count
        if fits == entries.count { add(); return nil }
        if fits == 0 { QuotaGate.shared.stopped(); return nil }
        return fits
    }
}

/// 「已用 873 / 1000」 under a header, from 900 words on (nothing for Pro).
struct QuotaUsage: View {
    let words: [Word]

    var body: some View {
        let used = words.filter(WordQuota.counts).count
        if let text = WordQuota.usage(used, unlimited: WordQuota.unlimited) {
            Text(text)
                .font(.app(.footnote, .semibold))
                .foregroundStyle(used >= WordQuota.limit ? Color.red : .secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Over the limit: countdown, warnings and deleting the extra words

/// Runs the over-limit countdown on this device: starts and cancels it, pops up the 7-day and 1-day reminders,
/// and on the day it ends deletes the words added first (they go into `Removed` so syncing doesn't bring them back).
@Observable final class QuotaCountdown {
    static let shared = QuotaCountdown()
    private static let key = "quota.countdown"

    private(set) var state: WordQuota.Countdown
    /// days left, while the reminder is up
    var reminder: Int?
    /// how many words were just deleted, while that notice is up
    var deleted: Int?

    private init() {
        state = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(WordQuota.Countdown.self, from: $0) } ?? .init()
    }

    /// Local day number (days since 1970-01-01 on this phone's clock).
    static func day(_ d: Date = .now) -> Int {
        Int(floor((d.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: d))) / 86_400))
    }

    static func date(_ day: Int) -> Date {
        let utc = Date(timeIntervalSince1970: Double(day) * 86_400)
        return utc.addingTimeInterval(-Double(TimeZone.current.secondsFromGMT(for: utc)))
    }

    var deleteDate: Date? { state.deleteOn.map(Self.date) }

    /// On launch, on coming back to the app and whenever the word count changes.
    func refresh(_ ctx: ModelContext, popUps: Bool = false) {
        let today = Self.day()
        let used = WordQuota.used(in: ctx)
        var s = WordQuota.countdown(state, used: used, unlimited: WordQuota.unlimited, today: today)
        if popUps {
            if WordQuota.due(s, today: today) {
                deleted = delete(in: ctx, used: used)
                s = WordQuota.countdown(s, used: WordQuota.used(in: ctx), unlimited: WordQuota.unlimited, today: today)
            } else if let left = WordQuota.reminder(s, today: today) {
                reminder = left
                if left == 1 { s.shown1 = true; s.shown7 = true } else { s.shown7 = true }
            }
        }
        if s != state {
            state = s
            UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: Self.key)
        }
    }

    /// The counted words added first, as many as are over the limit.
    func doomed(in ctx: ModelContext) -> [Word] {
        let used = WordQuota.used(in: ctx)
        guard !WordQuota.unlimited, used > WordQuota.limit else { return [] }
        let words = (try? ctx.fetch(FetchDescriptor<Word>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
        return Array(words.filter(WordQuota.counts).prefix(WordQuota.over(used)))
    }

    /// Deletes the extra words with their progress; lists stay, even when empty. Returns how many went.
    private func delete(in ctx: ModelContext, used: Int) -> Int {
        guard !WordQuota.unlimited else { return 0 }   // checked again right before deleting
        let gone = doomed(in: ctx)
        guard !gone.isEmpty else { return 0 }
        Removed.add(gone.map(\.term))
        for w in gone { ctx.delete(w) }
        try? ctx.save()
        return gone.count
    }

    /// 「只匯出要被刪的字」: a CSV of the words that will be deleted.
    func csv(in ctx: ModelContext) -> URL? {
        func cell(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var lines = ["word,meaning,part_of_speech,added_at,level"]
        for w in doomed(in: ctx) {
            lines.append([w.term, w.meaningLine, w.pos, f.string(from: w.addedAt), String(w.srsLevel)].map(cell).joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("捲字_將被刪除的單字.csv")
        // with a byte order mark so Excel reads the Chinese correctly
        guard (try? ("\u{FEFF}" + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }
}

extension Date {
    var monthDay: String { formatted(.dateTime.month(.defaultDigits).day().locale(.zh)) }
}

/// The warning at the top of 主頁 and 我的單字 while over the limit; it can't be closed.
struct QuotaBanner: View {
    let words: [Word]
    @Environment(\.modelContext) private var ctx
    @State private var details = false
    private var countdown: QuotaCountdown { .shared }

    var body: some View {
        let used = words.filter(WordQuota.counts).count
        Group {
            if !WordQuota.unlimited, used > WordQuota.limit, let date = countdown.deleteDate {
                Button { details = true } label: {
                    HStack(alignment: .top, spacing: 12) {
                        LIcon("exclamationmark.triangle.fill").font(.app(.title3)).foregroundStyle(Color.hsnuMagenta)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("單字超過上限 \(WordQuota.over(used)) 個").font(.app(.subheadline, .bold))
                            Text("\(date.monthDay)會刪除最早加入的 \(WordQuota.over(used)) 個字，訂閱 Pro 或自己刪到 1000 個以下就不會刪。")
                                .font(.app(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        LIcon("chevron.right").font(.app(.footnote, .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.hsnuMagentaFill))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $details) { QuotaOverView() }
            }
        }
        .onAppear { countdown.refresh(ctx) }
    }
}

/// What will be deleted and the three ways out: Pro, deleting words yourself, exporting first.
struct QuotaOverView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var paywall = false
    @State private var showAll = false
    private var countdown: QuotaCountdown { .shared }

    var body: some View {
        let doomed = countdown.doomed(in: ctx)
        let used = WordQuota.used(in: ctx)
        NavigationStack {
            Form { Group {
                Section {
                    Text("免費版的「我的單字」最多 \(WordQuota.limit) 個（大考詞彙和考古題加入的字不算）。你現在有 \(used) 個，超過 \(doomed.count) 個。")
                        .font(.app(.subheadline))
                    if let date = countdown.deleteDate {
                        Text("如果 \(date.monthDay) 前沒有處理，會刪掉最早加入的 \(doomed.count) 個字和它們的複習紀錄。自訂清單會留著，只是少了這些字。")
                            .font(.app(.subheadline)).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button { paywall = true } label: { Label("訂閱 Pro，字全部保留", systemImage: "crown.fill") }
                    Button { if let url = countdown.csv(in: ctx) { presentShareSheet(url) } } label: {
                        Label("匯出要被刪的字（CSV）", systemImage: "square.and.arrow.up")
                    }
                } header: { Text("你可以") } footer: {
                    Text("也可以到「字庫 › 我的單字」自己刪掉一些字，刪到 \(WordQuota.limit) 個以下就取消。完整備份在「設定 › 備份」。")
                }
                Section("會被刪的字（最早加入的在前）") {
                    ForEach(showAll ? doomed : Array(doomed.prefix(20))) { w in
                        HStack {
                            Text(w.term).font(.app(.headline))
                            Text(w.primaryMeaning).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(w.addedAt.monthDay).font(.app(.caption)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    if doomed.count > 20, !showAll {
                        Button("看完整清單（\(doomed.count) 個）") { showAll = true }
                    }
                }
            }.listRowBackground(Color.cardFill) }
            .themedBackground()
            .navigationTitle("單字超過上限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $paywall, onDismiss: { countdown.refresh(ctx); if WordQuota.unlimited { dismiss() } }) { ProPaywall() }
        }
    }
}

/// The 7-day and 1-day reminders and the notice after deleting, shown from the root.
struct QuotaReminders: ViewModifier {
    @Environment(\.modelContext) private var ctx
    @Environment(\.scenePhase) private var phase
    @State private var countdown = QuotaCountdown.shared
    @State private var details = false

    func body(content: Content) -> some View {
        content
            .task { countdown.refresh(ctx, popUps: true) }
            .onChange(of: phase) { _, p in if p == .active { countdown.refresh(ctx, popUps: true) } }
            .alert(countdown.reminder == 1 ? "明天會刪除超過上限的單字" : "還剩 \(countdown.reminder ?? 7) 天會刪除超過上限的單字",
                   isPresented: Binding(get: { countdown.reminder != nil }, set: { if !$0 { countdown.reminder = nil } })) {
                Button("查看") { details = true }
                Button("稍後", role: .cancel) {}
            } message: {
                Text("\(countdown.deleteDate?.monthDay ?? "")會刪除最早加入的 \(WordQuota.over(WordQuota.used(in: ctx))) 個字。訂閱 Pro、自己刪到 \(WordQuota.limit) 個以下，或先匯出要被刪的字。")
            }
            .alert("已刪除 \(countdown.deleted ?? 0) 個單字",
                   isPresented: Binding(get: { (countdown.deleted ?? 0) > 0 }, set: { if !$0 { countdown.deleted = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text("依照免費版 \(WordQuota.limit) 字上限，刪除了最早加入的字和它們的複習紀錄。之後想再練可以重新加入（有 Pro 就沒有上限）。")
            }
            .sheet(isPresented: $details) { QuotaOverView() }
    }
}
