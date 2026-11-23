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
        alert(fits.wrappedValue.map { "只能加入前 \($0) 個" } ?? "",
                           isPresented: Binding(get: { fits.wrappedValue != nil }, set: { if !$0 { fits.wrappedValue = nil } })
                           ) {
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

// MARK: - Over the limit (e.g. after Pro ends): keep every word, only pause adding

extension Date {
    var monthDay: String { formatted(.dateTime.month(.defaultDigits).day().locale(.zh)) }
}

/// The note at the top of 主頁 and 我的單字 while over the limit. Nothing is ever deleted: the words can still be
/// browsed and reviewed, only adding counted words is paused until back within the limit or on Pro.
struct QuotaBanner: View {
    let words: [Word]
    @State private var details = false

    var body: some View {
        let used = words.filter(WordQuota.counts).count
        if !WordQuota.unlimited, used > WordQuota.limit {
            Button { details = true } label: {
                HStack(alignment: .top, spacing: 12) {
                    LIcon("lock.fill").font(.app(.title3)).foregroundStyle(Color.hsnuMagenta)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("單字超過上限 \(WordQuota.over(used)) 個，暫停新增").font(.app(.subheadline, .bold))
                        Text(WordQuota.overMessage)
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
}

/// Why adding is paused and the two ways out: Pro, or deleting words yourself.
struct QuotaOverView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var paywall = false

    var body: some View {
        let used = WordQuota.used(in: ctx)
        NavigationStack {
            Form { Group {
                Section {
                    Text("免費版的「我的單字」最多 \(WordQuota.limit) 個（大考詞彙和考古題加入的字不算）。你現在有 \(used) 個，超過 \(WordQuota.over(used)) 個。")
                        .font(.app(.subheadline))
                    Text(WordQuota.overMessage).font(.app(.subheadline)).foregroundStyle(.secondary)
                }
                Section {
                    Button { paywall = true } label: { Label("訂閱 Pro，不限個數", systemImage: "crown.fill") }
                } header: { Text("你可以") } footer: {
                    Text("也可以到「字庫 › 我的單字」自己刪掉一些字，刪到 \(WordQuota.limit) 個以內就能再新增。")
                }
            }.listRowBackground(Color.cardFill) }
            .themedBackground()
            .navigationTitle("單字超過上限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $paywall, onDismiss: { if WordQuota.unlimited { dismiss() } }) { ProPaywall() }
        }
    }
}

/// Clears the countdown older versions saved (they deleted words 30 days after going over the limit).
struct QuotaReminders: ViewModifier {
    func body(content: Content) -> some View {
        content.task { UserDefaults.standard.removeObject(forKey: "quota.countdown") }
    }
}
