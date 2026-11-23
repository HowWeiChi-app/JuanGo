import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - File format

/// A JuanGo file: either a full backup (words with progress, lists, review history, settings)
/// or one shared word list (words only, no one's progress). Plain JSON so it survives LINE / AirDrop / 檔案.
struct BackupFile: Codable {
    enum Kind: String, Codable { case backup, list }

    var app = "JuanGo"
    /// 1: every word written out in full. 2: backups leave out what the built-in dictionary already has.
    var format = 1
    var kind: Kind
    var exportedAt = Date()
    var words: [WordRecord]
    var lists: [ListRecord]
    var logs: [LogRecord]? = nil
    var settings: [String: SettingValue]? = nil
    /// words deleted for the free word limit, so a sync doesn't bring them back from the cloud or another device
    var removed: [RemovedRecord]? = nil

    struct WordRecord: Codable {
        var term, ipa, pos: String
        var meanings: [String]
        var definition, example, exampleZh, cefr: String
        // progress (backups only)
        var srsLevel: Int? = nil
        var dueDate: Date? = nil
        var lastReviewed: Date? = nil
        var addedAt: Date? = nil
        var favorite: Bool? = nil
        var inMyWords: Bool? = nil
        var reviewCount: Int? = nil
        var fromExam: Bool? = nil

        private enum CodingKeys: String, CodingKey {
            case term, ipa, pos, meanings, definition, example, exampleZh, cefr
            case srsLevel, dueDate, lastReviewed, addedAt, favorite, inMyWords, reviewCount, fromExam
        }

        /// The built-in entry with exactly this spelling, whose text a backup leaves out.
        private static func dictionary(_ term: String) -> DictEntry? {
            Dictionary_.lookup(term).flatMap { $0.w == term ? $0 : nil }
        }

        /// Backup records (they carry progress) skip what the dictionary already has and the usual values,
        /// which takes most of the size; shared lists keep everything so any version can read them.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            let compact = addedAt != nil
            let d = compact ? Self.dictionary(term) : nil
            try c.encode(term, forKey: .term)
            if d?.ipa != ipa { try c.encode(ipa, forKey: .ipa) }
            if d?.pos != pos { try c.encode(pos, forKey: .pos) }
            if d?.zh != meanings { try c.encode(meanings, forKey: .meanings) }
            if d?.def != definition { try c.encode(definition, forKey: .definition) }
            if d?.ex != example { try c.encode(example, forKey: .example) }
            if d?.exZh != exampleZh { try c.encode(exampleZh, forKey: .exampleZh) }
            if d?.lv != cefr { try c.encode(cefr, forKey: .cefr) }
            try c.encodeIfPresent(srsLevel, forKey: .srsLevel)
            try c.encodeIfPresent(dueDate, forKey: .dueDate)
            try c.encodeIfPresent(lastReviewed, forKey: .lastReviewed)
            try c.encodeIfPresent(addedAt, forKey: .addedAt)
            try c.encodeIfPresent(reviewCount, forKey: .reviewCount)
            if !compact || favorite == true { try c.encodeIfPresent(favorite, forKey: .favorite) }
            if !compact || inMyWords == false { try c.encodeIfPresent(inMyWords, forKey: .inMyWords) }
            if fromExam == true { try c.encode(true, forKey: .fromExam) }
        }
    }
    struct ListRecord: Codable {
        var name: String
        var createdAt: Date? = nil
        var terms: [String]
    }
    struct RemovedRecord: Codable {
        var term: String
        var at: Date
    }
    struct LogRecord: Codable {
        var term: String
        var date: Date
        var result: Int
        var wasNew: Bool
    }
    enum SettingValue: Codable, Equatable {
        case bool(Bool), int(Int), double(Double), string(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int.self) { self = .int(v) }
            else if let v = try? c.decode(Double.self) { self = .double(v) }
            else { self = .string(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            }
        }
        var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
        var int: Int? { if case .int(let v) = self { v } else { nil } }
        var double: Double? { switch self { case .double(let v): v; case .int(let v): Double(v); default: nil } }
        var string: String? { if case .string(let v) = self { v } else { nil } }
    }

    var summary: String {
        var parts = ["\(words.count) 個單字"]
        if !lists.isEmpty { parts.append("\(lists.count) 個清單") }
        if let logs, !logs.isEmpty { parts.append("\(logs.count) 筆複習紀錄") }
        return parts.joined(separator: "、")
    }
    var title: String {
        switch kind {
        case .backup: "JuanGo 備份（\(exportedAt.formatted(date: .abbreviated, time: .shortened))）"
        case .list: "單字清單「\(lists.first?.name ?? "未命名")」"
        }
    }
}

// Decoding lives in an extension so the struct keeps its memberwise initializer.
extension BackupFile.WordRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term = try c.decode(String.self, forKey: .term)
        // format 2 backups leave out text that matches the built-in dictionary
        let d = Self.dictionary(term)
        ipa = try c.decodeIfPresent(String.self, forKey: .ipa) ?? d?.ipa ?? ""
        pos = try c.decodeIfPresent(String.self, forKey: .pos) ?? d?.pos ?? ""
        meanings = try c.decodeIfPresent([String].self, forKey: .meanings) ?? d?.zh ?? []
        definition = try c.decodeIfPresent(String.self, forKey: .definition) ?? d?.def ?? ""
        example = try c.decodeIfPresent(String.self, forKey: .example) ?? d?.ex ?? ""
        exampleZh = try c.decodeIfPresent(String.self, forKey: .exampleZh) ?? d?.exZh ?? ""
        cefr = try c.decodeIfPresent(String.self, forKey: .cefr) ?? d?.lv ?? ""
        srsLevel = try c.decodeIfPresent(Int.self, forKey: .srsLevel)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        lastReviewed = try c.decodeIfPresent(Date.self, forKey: .lastReviewed)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        reviewCount = try c.decodeIfPresent(Int.self, forKey: .reviewCount)
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite)
        inMyWords = try c.decodeIfPresent(Bool.self, forKey: .inMyWords)
        fromExam = try c.decodeIfPresent(Bool.self, forKey: .fromExam)
        if addedAt != nil {   // a backup record: the usual values are left out
            favorite = favorite ?? false
            inMyWords = inMyWords ?? true
        }
    }
}

// MARK: - Export / restore

@MainActor
enum Backup {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Everything on this device.
    static func full(_ ctx: ModelContext) -> BackupFile {
        let words = (try? ctx.fetch(FetchDescriptor<Word>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
        let lists = (try? ctx.fetch(FetchDescriptor<WordList>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let logs = (try? ctx.fetch(FetchDescriptor<ReviewLog>(sortBy: [SortDescriptor(\.date)]))) ?? []
        return BackupFile(format: 2, kind: .backup,
                          words: words.map { record($0, progress: true) },
                          lists: lists.map { .init(name: $0.name, createdAt: $0.createdAt, terms: $0.words.map(\.term)) },
                          logs: logs.map { .init(term: $0.term, date: $0.date, result: $0.result, wasNew: $0.wasNew) },
                          settings: AppSettings.shared.backupValues,
                          removed: Removed.all.isEmpty ? nil : Removed.all.map { .init(term: $0.key, at: $0.value) }
                            .sorted { $0.at < $1.at })
    }

    /// One list to give to someone else: the words and their meanings, without progress.
    static func list(name: String, words: [Word]) -> BackupFile {
        BackupFile(kind: .list, words: words.map { record($0, progress: false) },
                   lists: [.init(name: name, terms: words.map(\.term))])
    }

    private static func record(_ w: Word, progress: Bool) -> BackupFile.WordRecord {
        var r = BackupFile.WordRecord(term: w.term, ipa: w.ipa, pos: w.pos, meanings: w.meanings, definition: w.definition,
                                      example: w.example, exampleZh: w.exampleZh, cefr: w.cefr)
        if progress {
            r.srsLevel = w.srsLevel; r.dueDate = w.dueDate; r.lastReviewed = w.lastReviewed; r.addedAt = w.addedAt
            r.favorite = w.favorite; r.inMyWords = w.inMyWords; r.reviewCount = w.reviewCount
            if w.fromExam { r.fromExam = true }
        }
        return r
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Writes the file to a temporary folder (for the share sheet) and returns its URL.
    static func write(_ f: BackupFile) throws -> URL {
        let day = f.exportedAt.formatted(.iso8601.year().month().day())
        let base: String
        switch f.kind {
        case .backup: base = "JuanGo 備份 \(day)"
        case .list: base = "\(f.lists.first?.name ?? "清單") - JuanGo 清單"
        }
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe + ".json")
        try encoder.encode(f).write(to: url, options: .atomic)
        return url
    }

    static func read(_ url: URL) throws -> BackupFile {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let f = try? d.decode(BackupFile.self, from: data), f.app == "JuanGo" else {
            throw Failure(message: "這不是 JuanGo 的備份或清單檔")
        }
        guard f.format <= 2 else { throw Failure(message: "這個檔案來自較新版的 JuanGo，請先更新 App") }
        return f
    }

    /// Merges a file into this device; nothing already here is deleted.
    /// Words already saved keep whichever progress was reviewed more recently.
    @discardableResult
    /// `only`: the terms of a shared list that fit under the free word limit (nil: all of them).
    static func restore(_ f: BackupFile, into ctx: ModelContext, settings: Bool = true, only: Set<String>? = nil) -> String {
        var existing: [String: Word] = [:]
        for w in (try? ctx.fetch(FetchDescriptor<Word>())) ?? [] { existing[w.term] = w }
        var added = 0, updated = 0

        // words another device deleted for the word limit: delete them here too, and don't take them back
        var gone: [String: Date] = [:]
        if f.kind == .backup {
            Removed.merge(f.removed ?? [])
            gone = Removed.all
            for (t, at) in gone { if let w = existing[t], w.addedAt <= at { ctx.delete(w); existing[t] = nil } }
        }

        for r in f.words where !r.term.isEmpty && only?.contains(r.term) != false {
            if let at = gone[r.term], existing[r.term] == nil, (r.addedAt ?? .distantPast) <= at { continue }
            let w: Word
            if let e = existing[r.term] {
                w = e
                if e.meanings.isEmpty { e.meanings = r.meanings }
                if e.pos.isEmpty { e.pos = r.pos }
                if e.definition.isEmpty { e.definition = r.definition }
                if e.example.isEmpty { e.example = r.example; e.exampleZh = r.exampleZh }
                if e.ipa.isEmpty { e.ipa = r.ipa }
                if f.kind == .backup, (r.lastReviewed ?? .distantPast) > (e.lastReviewed ?? .distantPast) {
                    applyProgress(r, to: e); updated += 1
                }
                if r.favorite == true { e.favorite = true }
                if f.kind == .backup, r.fromExam == true { e.fromExam = true }
                if r.inMyWords == true || f.kind == .list { e.inMyWords = true }
            } else {
                w = Word(entry: DictEntry(w: r.term, ipa: r.ipa, pos: r.pos, zh: r.meanings, def: r.definition,
                                          ex: r.example, exZh: r.exampleZh, lv: r.cefr))
                if f.kind == .backup {
                    applyProgress(r, to: w)
                    if let d = r.addedAt { w.addedAt = d }
                    w.favorite = r.favorite ?? false
                    w.inMyWords = r.inMyWords ?? true
                    w.fromExam = r.fromExam ?? false
                }
                ctx.insert(w)
                existing[r.term] = w
                added += 1
            }
        }

        var lists: [String: WordList] = [:]
        for l in (try? ctx.fetch(FetchDescriptor<WordList>())) ?? [] { lists[l.name] = l }
        for r in f.lists {
            if WordList.builtInNames.contains(r.name) {   // the built-in list, not a folder with the same name
                for t in r.terms { if let w = existing[t] { if r.name == "喜歡" { w.favorite = true } else { w.inMyWords = true } } }
                continue
            }
            let l: WordList
            if let e = lists[r.name] { l = e } else {
                l = WordList(name: r.name)
                if let d = r.createdAt { l.createdAt = d }
                ctx.insert(l); lists[r.name] = l
            }
            for t in r.terms where only?.contains(t) != false {
                guard let w = existing[t], !w.lists.contains(where: { $0.persistentModelID == l.persistentModelID }) else { continue }
                w.lists.append(l)
            }
        }

        var logCount = 0
        if let logs = f.logs, !logs.isEmpty {
            let key = { (t: String, d: Date) in "\(t)|\(Int(d.timeIntervalSince1970))" }
            var have = Set(((try? ctx.fetch(FetchDescriptor<ReviewLog>())) ?? []).map { key($0.term, $0.date) })
            for r in logs where !have.contains(key(r.term, r.date)) {
                let log = ReviewLog(term: r.term, result: r.result, wasNew: r.wasNew)
                log.date = r.date
                ctx.insert(log); have.insert(key(r.term, r.date)); logCount += 1
            }
        }

        if f.kind == .backup, settings, let s = f.settings { AppSettings.shared.apply(backup: s) }
        try? ctx.save()

        var parts = ["新增 \(added) 個單字"]
        if updated > 0 { parts.append("更新 \(updated) 個字的進度") }
        if logCount > 0 { parts.append("還原 \(logCount) 筆複習紀錄") }
        if f.kind == .list, let name = f.lists.first?.name { parts.append("加入清單「\(name)」") }
        return parts.joined(separator: "，")
    }

    private static func applyProgress(_ r: BackupFile.WordRecord, to w: Word) {
        if let v = r.srsLevel { w.srsLevel = v }
        w.dueDate = r.dueDate
        w.lastReviewed = r.lastReviewed
        if let v = r.reviewCount { w.reviewCount = v }
    }
}

// MARK: - Settings in backups

extension AppSettings {
    var backupValues: [String: BackupFile.SettingValue] {
        ["level": .string(level), "dailyGoal": .int(dailyGoal), "reminderOn": .bool(reminderOn),
         "reminderMinutes": .int(reminderMinutes), "appearance": .int(appearance), "fontStyle": .int(fontStyle),
         "themeID": .string(themeID), "muted": .bool(muted), "showTranslation": .bool(showTranslation),
         "haptics": .bool(haptics), "speechRate": .double(speechRate), "listShowMeaning": .bool(listShowMeaning),
         "detailAutoSpeak": .bool(detailAutoSpeak), "exploreShowIPA": .bool(exploreShowIPA),
         "aiTranslate": .bool(aiTranslate), "apiBaseURL": .string(apiBaseURL), "apiModel": .string(apiModel),
         "examOn": .bool(examOn), "examName": .string(examName), "examDate": .double(examDate.timeIntervalSince1970),
         "examTop": .int(examTop), "levelTested": .bool(levelTested), "language": .string(language),
         "exploreTipsDone": .bool(exploreTipsDone), "studyRulesSeen": .bool(studyRulesSeen),
         "practiceLimit": .int(UserDefaults.standard.object(forKey: "practiceLimit") as? Int ?? 20)]
    }

    func apply(backup s: [String: BackupFile.SettingValue]) {
        if let v = s["level"]?.string { level = v }
        if let v = s["dailyGoal"]?.int { dailyGoal = v }
        if let v = s["examOn"]?.bool { examOn = v }
        if let v = s["examName"]?.string { examName = v }
        if let v = s["examDate"]?.double, v > 0 { examDate = Date(timeIntervalSince1970: v) }
        if let v = s["examTop"]?.int { examTop = v }
        if let v = s["reminderMinutes"]?.int { reminderMinutes = v }
        if let v = s["reminderOn"]?.bool { reminderOn = v }
        if let v = s["appearance"]?.int { appearance = v }
        if let v = s["fontStyle"]?.int { fontStyle = v }
        if let v = s["themeID"]?.string { themeID = v }
        if let v = s["muted"]?.bool { muted = v }
        if let v = s["showTranslation"]?.bool { showTranslation = v }
        if let v = s["haptics"]?.bool { haptics = v }
        if let v = s["speechRate"]?.double { speechRate = v }
        if let v = s["listShowMeaning"]?.bool { listShowMeaning = v }
        if let v = s["detailAutoSpeak"]?.bool { detailAutoSpeak = v }
        if let v = s["exploreShowIPA"]?.bool { exploreShowIPA = v }
        if let v = s["aiTranslate"]?.bool { aiTranslate = v }
        if let v = s["apiBaseURL"]?.string { apiBaseURL = v }
        if let v = s["apiModel"]?.string { apiModel = v }
        // a test done on any phone counts; a backup from before the test never undoes it here
        if s["levelTested"]?.bool == true { levelTested = true }
        if let v = s["language"]?.string { language = v }
        if s["exploreTipsDone"]?.bool == true { exploreTipsDone = true }
        if s["studyRulesSeen"]?.bool == true { studyRulesSeen = true }
        if let v = s["practiceLimit"]?.int { UserDefaults.standard.set(v, forKey: "practiceLimit") }
    }

    /// After signing out: every setting the account carries goes back to a new install's (onboarding stays done).
    func resetAccount() {
        // the same values as the defaults registered in AppSettings.init
        language = "zh-Hant"; level = "3"; levelTested = false; levelRetest = false
        dailyGoal = 10; reminderOn = false; reminderMinutes = 20 * 60
        appearance = 0; fontStyle = 0; themeID = "phoenix"; muted = false
        showTranslation = true; haptics = true; speechRate = 0.45
        exploreTipsDone = false; studyRulesSeen = false; listShowMeaning = true
        detailAutoSpeak = false; exploreShowIPA = true; aiTranslate = true
        apiBaseURL = "https://apihub.agnes-ai.com/v1"; apiModel = "agnes-3.0-flash"
        examOn = false; examName = "學測"; examDate = ExamPlan.defaultDate(); examTop = 6
        UserDefaults.standard.removeObject(forKey: "practiceLimit")
    }
}

/// Words deleted for the free word limit and when, kept on this device and carried in backups (`removed`).
enum Removed {
    private static let key = "quota.removed"

    static var all: [String: Date] {
        ((UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func add(_ terms: [String], at: Date = .now) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        for t in terms { d[t] = at.timeIntervalSince1970 }
        UserDefaults.standard.set(d, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    static func merge(_ records: [BackupFile.RemovedRecord]) {
        guard !records.isEmpty else { return }
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        for r in records { d[r.term] = max(d[r.term] ?? 0, r.at.timeIntervalSince1970) }
        UserDefaults.standard.set(d, forKey: key)
    }
}

// MARK: - UI helpers

/// Shows the system share sheet (AirDrop, LINE, 儲存到「檔案」…) for a file, on top of whatever is on screen —
/// presenting it from UIKit avoids clashing with SwiftUI sheets, file importers and dialogs on the same view.
@MainActor
func presentShareSheet(_ url: URL) {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
          var top = scene.keyWindow?.rootViewController else { return }
    while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
    let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    vc.popoverPresentationController?.sourceView = top.view
    vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
    top.present(vc, animated: true)
}

extension View {
    /// Asks before merging a picked JuanGo file into this device, then reports what happened.
    func backupImport(_ file: Binding<BackupFile?>, ctx: ModelContext, done: @escaping (String) -> Void) -> some View {
        modifier(BackupImportConfirm(file: file, ctx: ctx, done: done))
    }
}

private struct BackupImportConfirm: ViewModifier {
    @Binding var file: BackupFile?
    let ctx: ModelContext
    let done: (String) -> Void

    /// For a shared list that doesn't all fit under the free word limit, the terms that do; nil when it all fits.
    private func fitting(_ f: BackupFile) -> Set<String>? {
        guard f.kind == .list else { return nil }
        let entries = f.words.map { DictEntry(w: $0.term, ipa: "", pos: "", zh: [], def: "", ex: "", exZh: "", lv: $0.cefr) }
        let ok = WordQuota.admitted(entries, in: ctx)
        return ok.count < entries.count ? Set(ok.map(\.w)) : nil
    }

    func body(content: Content) -> some View {
        content.alert(file?.title ?? "", isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } }),
                                   presenting: file) { f in
            let fits = fitting(f)
            Button(f.kind == .backup ? "合併還原" : fits.map { "加入前 \($0.count) 個" } ?? "加入清單") {
                if let fits, fits.isEmpty { QuotaGate.shared.stopped() } else { done(Backup.restore(f, into: ctx, only: fits)) }
                file = nil
            }
            Button("取消", role: .cancel) { file = nil }
        } message: { f in
            if f.kind == .backup {
                Text("\(f.summary)。會和這台裝置上的資料合併，不會刪除任何東西；同一個字保留最近複習過的進度。設定也會換成備份裡的。")
            } else if let fits = fitting(f) {
                Text("\(f.summary)。只能加入前 \(fits.count) 個，\(WordQuota.fullMessage)。")
            } else {
                Text("\(f.summary)。會加進「我的單字」和同名清單，你自己的進度不受影響。")
            }
        }
    }
}

#if DEBUG
extension Backup {
    /// `SIMCTL_CHILD_JUANGO_BACKUP_SELFTEST=1`: round-trips a backup and a shared list through files,
    /// using in-memory stores only (the app's own data is not touched), prints the result and exits.
    static func selfTest() {
        func store() -> ModelContext {
            let c = try! ModelContainer(for: Word.self, WordList.self, ReviewLog.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            return ModelContext(c)
        }
        let a = store()
        let entries = Array(Dictionary_.all.prefix(5))
        for e in entries { Library.add(e, in: a) }
        let words = try! a.fetch(FetchDescriptor<Word>(sortBy: [SortDescriptor(\.term)]))
        words[0].srsLevel = 3; words[0].reviewCount = 7; words[0].lastReviewed = .now; words[0].favorite = true
        let l = WordList(name: "測試/清單"); a.insert(l); words[1].lists.append(l); words[2].lists.append(l)
        a.insert(ReviewLog(term: words[0].term, result: 2, wasNew: true))
        try! a.save()

        let url = try! write(full(a))
        let f = try! read(url)
        let b = store()
        let r1 = restore(f, into: b)
        let r2 = restore(f, into: b)   // second time: nothing new
        let bw = try! b.fetch(FetchDescriptor<Word>(sortBy: [SortDescriptor(\.term)]))
        let bl = try! b.fetch(FetchDescriptor<WordList>())
        let logs = try! b.fetchCount(FetchDescriptor<ReviewLog>())
        let w0 = bw.first { $0.term == words[0].term }!
        print("SELFTEST file:", url.lastPathComponent)
        print("SELFTEST restore1:", r1, "| restore2:", r2)
        print("SELFTEST words", bw.count, "lists", bl.map { "\($0.name)=\($0.words.count)" }, "logs", logs,
              "w0 level", w0.srsLevel, "reviews", w0.reviewCount, "fav", w0.favorite)

        let lu = try! write(list(name: l.name, words: l.words))
        let lf = try! read(lu)
        let c = store()
        print("SELFTEST list file:", lu.lastPathComponent, "|", restore(lf, into: c),
              "| progress kept out:", (try! c.fetch(FetchDescriptor<Word>())).allSatisfy { $0.srsLevel == 0 })
        exit(0)
    }
}
#endif
