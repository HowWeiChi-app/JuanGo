import SwiftUI
import Vision
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Page content
// The same JSON on iPhone, Android and in Supabase (see supabase/textbook.sql). A lesson text page:
// {"v":1,"paragraphs":[{"style":"title","sentences":[{"words":[{"t":"modem,","conf":0.42,"bold":true}]}]}],
//  "marks":[{"p":0,"s":1,"g":"not only … but also …","why":"not only … but also"}],"checked":["…"],"checked_by":"ai"}
// A word-list page (單字表) has "kind":"vocab", with "entries":[{"t":"bench","pos":"n.","zh":["長椅"],"kind":"word"}]
// and "grammar":[{"title":"…","note":"…"}]. Keys that are missing mean the plain default. No photos are kept.

nonisolated struct TBWord: Codable, Hashable {
    /// the word as printed, with the punctuation around it ("modem,")
    var t: String
    /// normalised to the photo, top-left origin: x, y, width, height. Only while importing; not saved.
    var box: [Double]?
    /// Vision's confidence for the line the word is on, 0…1
    var conf: Double?
    /// printed in bold (textbooks bold the lesson's new words)
    var bold: Bool?
    var core: String { TBText.core(t) }
    var isBold: Bool { bold == true }
    /// `box` as a rect
    var rect: CGRect? { box.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil } }
}
nonisolated struct TBSentence: Codable, Hashable { var words: [TBWord] }
nonisolated struct TBParagraph: Codable, Hashable {
    var sentences: [TBSentence]
    /// "title" or "subtitle"; nil for body text
    var style: String? = nil
}

/// One row of a 單字表: 生字 (word), 一般生字 (general) or 片語 (phrase).
nonisolated struct TBEntry: Codable, Hashable, Identifiable {
    var t: String
    var pos: String?
    var zh: [String]?
    /// word, general or phrase
    var kind: String
    var id: String { kind + ":" + t }
    var meaning: String { (zh ?? []).prefix(3).joined(separator: "；") }
}

/// A 文法重點 printed on the word-list page.
nonisolated struct TBGrammar: Codable, Hashable, Identifiable {
    var title: String
    var note: String?
    var id: String { title }
}

/// A sentence on a lesson page that uses one of the lesson's grammar points (g is the point's title).
nonisolated struct TBMark: Codable, Hashable, Identifiable {
    var p: Int, s: Int
    var g: String
    /// the words in the sentence that show it
    var why: String?
    var id: String { "\(p)-\(s)-\(g)" }
}

nonisolated struct TBContent: Codable, Hashable {
    var v = 1
    /// "vocab" for a word-list page; nil for lesson text
    var kind: String?
    var paragraphs: [TBParagraph] = []
    var entries: [TBEntry]?
    var grammar: [TBGrammar]?
    var marks: [TBMark]?
    /// the grammar titles the marks were looked for with, and how ("ai" or "rule")
    var checked: [String]?
    var checkedBy: String?

    enum CodingKeys: String, CodingKey {
        case v, kind, paragraphs, entries, grammar, marks, checked
        case checkedBy = "checked_by"
    }

    var isVocab: Bool { kind == "vocab" }
    var isEmpty: Bool {
        paragraphs.allSatisfy { $0.sentences.allSatisfy { $0.words.isEmpty } } && (entries ?? []).isEmpty && (grammar ?? []).isEmpty
    }
    func word(_ at: TBPos) -> TBWord? {
        guard paragraphs.indices.contains(at.p), paragraphs[at.p].sentences.indices.contains(at.s),
              paragraphs[at.p].sentences[at.s].words.indices.contains(at.w) else { return nil }
        return paragraphs[at.p].sentences[at.s].words[at.w]
    }
    /// every word with where it is
    var allWords: [(pos: TBPos, word: TBWord)] {
        var out: [(TBPos, TBWord)] = []
        for (p, para) in paragraphs.enumerated() {
            for (s, sen) in para.sentences.enumerated() {
                for (w, word) in sen.words.enumerated() { out.append((TBPos(p: p, s: s, w: w), word)) }
            }
        }
        return out
    }
    /// what's kept: the boxes are only needed while importing
    var stored: TBContent {
        var c = self
        for p in c.paragraphs.indices {
            for s in c.paragraphs[p].sentences.indices {
                for w in c.paragraphs[p].sentences[s].words.indices { c.paragraphs[p].sentences[s].words[w].box = nil }
            }
        }
        return c
    }
}

/// Where a word is on the page: paragraph › sentence › word.
nonisolated struct TBPos: Hashable { var p: Int, s: Int, w: Int }

/// A suggested or accepted change to one OCR'd word. The page keeps the recognised text as it was;
/// accepted corrections are applied when the page is shown, so "保留原文" can always go back.
nonisolated struct TBCorrection: Codable, Hashable, Identifiable {
    var p: Int, s: Int, w: Int
    var original: String
    var suggestion: String
    /// ai, dictionary or manual
    var source: String
    /// pending, accepted or rejected
    var status: String
    var id: String { "\(p)-\(s)-\(w)" }
    var pos: TBPos { TBPos(p: p, s: s, w: w) }
    var isPending: Bool { status == "pending" }
    var sourceName: String { source == "ai" ? "Apple Intelligence" : source == "cloud_ai" ? "捲字雲端 AI" : source == "manual" ? "手動修改" : "字典比對" }
}

nonisolated enum TBText {
    /// "“Modem,”" → "Modem"
    static func core(_ t: String) -> String {
        t.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }
    /// The printed word with an accepted correction put in place of its letters ("modem," → "modern,").
    static func apply(_ c: TBCorrection?, to t: String) -> String {
        guard let c, c.status == "accepted", let r = t.range(of: c.original) else { return t }
        return t.replacingCharacters(in: r, with: c.suggestion)
    }
}

// MARK: - Books, lessons, pages

nonisolated struct TBBook: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var subject: String?
    var createdAt = Date.now
    var updatedAt = Date.now
    var deletedAt: Date?
    /// changed here and not yet uploaded
    var dirty = true
}

nonisolated struct TBLesson: Codable, Identifiable, Hashable {
    var id = UUID()
    var bookID: UUID
    var title: String
    var sort: Int
    var lastReadPage = 0
    var updatedAt = Date.now
    var deletedAt: Date?
    var dirty = true
}

nonisolated struct TBPage: Codable, Identifiable, Hashable {
    var id = UUID()
    var lessonID: UUID
    var sort: Int
    /// Storage path of a photo uploaded by an older build; removed from the cloud on the next sync
    var imagePath: String?
    var content: TBContent
    var corrections: [TBCorrection] = []
    var updatedAt = Date.now
    var deletedAt: Date?
    var dirty = true

    func correction(at pos: TBPos) -> TBCorrection? { corrections.first { $0.pos == pos } }
    var pending: [TBCorrection] { corrections.filter(\.isPending) }
    /// the text as it reads now, for listening and translating
    func text(_ pos: TBPos? = nil) -> String {
        content.allWords.map { TBText.apply(correction(at: $0.pos), to: $0.word.t) }.joined(separator: " ")
    }
    func sentence(p: Int, s: Int) -> String {
        guard content.paragraphs.indices.contains(p), content.paragraphs[p].sentences.indices.contains(s) else { return "" }
        return content.paragraphs[p].sentences[s].words.enumerated()
            .map { TBText.apply(correction(at: TBPos(p: p, s: s, w: $0.offset)), to: $0.element.t) }
            .joined(separator: " ")
    }
    /// the word's letters after any accepted correction
    func shown(_ pos: TBPos) -> String {
        guard let w = content.word(pos) else { return "" }
        return TBText.core(TBText.apply(correction(at: pos), to: w.t))
    }
}

// MARK: - The shelf (saved on this device, synced to Supabase when signed in)

@MainActor @Observable
final class Shelf {
    static let shared = Shelf()

    static let freeLessons = 1, freePages = 3, proPages = 1000, warnPages = 900

    private(set) var books: [TBBook] = []
    private(set) var lessons: [TBLesson] = []
    private(set) var pages: [TBPage] = []
    private(set) var syncing = false
    var syncMessage: String?
    /// newest server updated_at already pulled
    private var cursor: String?
    @ObservationIgnored var indexCache: [UUID: (key: String, index: LessonIndex)] = [:]
    @ObservationIgnored var marking = Set<UUID>()

    private struct File: Codable {
        var books: [TBBook]
        var lessons: [TBLesson]
        var pages: [TBPage]
        var cursor: String?
    }

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let f = base.appendingPathComponent("Textbook", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }()
    private var fileURL: URL { folder.appendingPathComponent("shelf.json") }

    private init() {
        if let d = try? Data(contentsOf: fileURL), let f = try? JSONDecoder().decode(File.self, from: d) {
            books = f.books; lessons = f.lessons; pages = f.pages; cursor = f.cursor
        }
        // pages are kept as text only: photos saved by earlier builds go
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("images"))
    }

    private func save() {
        #if DEBUG
        if ephemeral { return }
        #endif
        let f = File(books: books, lessons: lessons, pages: pages, cursor: cursor)
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: fileURL, options: .atomic) }
    }

    // MARK: reading

    var liveBooks: [TBBook] { books.filter { $0.deletedAt == nil }.sorted { $0.updatedAt > $1.updatedAt } }
    func book(_ id: UUID) -> TBBook? { books.first { $0.id == id } }
    func lesson(_ id: UUID) -> TBLesson? { lessons.first { $0.id == id } }
    func page(_ id: UUID) -> TBPage? { pages.first { $0.id == id } }
    func lessons(in book: UUID) -> [TBLesson] {
        lessons.filter { $0.bookID == book && $0.deletedAt == nil }.sorted { $0.sort < $1.sort }
    }
    func pages(in lesson: UUID) -> [TBPage] {
        pages.filter { $0.lessonID == lesson && $0.deletedAt == nil }.sorted { $0.sort < $1.sort }
    }
    private var liveLessons: [TBLesson] {
        let live = Set(liveBooks.map(\.id))
        return lessons.filter { $0.deletedAt == nil && live.contains($0.bookID) }
    }
    var lessonCount: Int { liveLessons.count }
    var pageCount: Int {
        let live = Set(liveLessons.map(\.id))
        return pages.filter { $0.deletedAt == nil && live.contains($0.lessonID) }.count
    }

    // MARK: limits (the server checks the same in supabase/textbook.sql)

    var isPro: Bool { ProStore.shared.has(.textbook) }
    var canAddBook: Bool { isPro || liveBooks.isEmpty }
    var canAddLesson: Bool { isPro || lessonCount < Self.freeLessons }
    var pagesLeft: Int { max(0, (isPro ? Self.proPages : Self.freePages) - pageCount) }
    var aiFixes: Bool { isPro && OCRFixer.aiAvailable }

    // MARK: changing

    @discardableResult
    func addBook(title: String, subject: String?) -> TBBook {
        let b = TBBook(title: title, subject: subject?.isEmpty == true ? nil : subject)
        books.append(b); save(); pushSoon()
        return b
    }
    func updateBook(_ id: UUID, title: String, subject: String?) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].title = title; books[i].subject = subject?.isEmpty == true ? nil : subject
        books[i].updatedAt = .now; books[i].dirty = true; save(); pushSoon()
    }
    func deleteBook(_ id: UUID) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].deletedAt = .now; books[i].updatedAt = .now; books[i].dirty = true
        for l in lessons(in: id) { deleteLesson(l.id, saving: false) }
        save(); pushSoon()
    }

    @discardableResult
    func addLesson(to book: UUID, title: String) -> TBLesson {
        let sort = (lessons.filter { $0.bookID == book }.map(\.sort).max() ?? -1) + 1
        let l = TBLesson(bookID: book, title: title, sort: sort)
        lessons.append(l)
        if let i = books.firstIndex(where: { $0.id == book }) { books[i].updatedAt = .now }
        save(); pushSoon()
        return l
    }
    func renameLesson(_ id: UUID, title: String) {
        guard let i = lessons.firstIndex(where: { $0.id == id }) else { return }
        lessons[i].title = title; lessons[i].updatedAt = .now; lessons[i].dirty = true; save(); pushSoon()
    }
    func deleteLesson(_ id: UUID, saving: Bool = true) {
        guard let i = lessons.firstIndex(where: { $0.id == id }) else { return }
        lessons[i].deletedAt = .now; lessons[i].updatedAt = .now; lessons[i].dirty = true
        for p in pages(in: id) { deletePage(p.id, saving: false) }
        if saving { save(); pushSoon() }
    }
    func setLastRead(_ id: UUID, page: Int) {
        guard let i = lessons.firstIndex(where: { $0.id == id }), lessons[i].lastReadPage != page else { return }
        lessons[i].lastReadPage = page; lessons[i].updatedAt = .now; lessons[i].dirty = true
        if let b = books.firstIndex(where: { $0.id == lessons[i].bookID }) { books[b].updatedAt = .now }
        save(); pushSoon()
    }

    func addPage(to lesson: UUID, content: TBContent, corrections: [TBCorrection]) {
        let sort = (pages.filter { $0.lessonID == lesson }.map(\.sort).max() ?? -1) + 1
        let p = TBPage(lessonID: lesson, sort: sort, content: content.stored, corrections: corrections)
        pages.append(p)
        if let i = lessons.firstIndex(where: { $0.id == lesson }), let b = books.firstIndex(where: { $0.id == lessons[i].bookID }) {
            books[b].updatedAt = .now
        }
        save(); pushSoon()
    }
    func deletePage(_ id: UUID, saving: Bool = true) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].deletedAt = .now; pages[i].updatedAt = .now; pages[i].dirty = true
        if saving { save(); pushSoon() }
    }
    /// Accept or reject suggestions, or record a manual change ("manual" corrections are accepted right away).
    func setCorrection(page id: UUID, _ c: TBCorrection) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].corrections.removeAll { $0.pos == c.pos }
        // keeping the original after a manual change just means no correction
        if !(c.source == "manual" && c.original == c.suggestion) { pages[i].corrections.append(c) }
        pages[i].updatedAt = .now; pages[i].dirty = true; save(); pushSoon()
    }
    func acceptAll(page id: UUID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        for j in pages[i].corrections.indices where pages[i].corrections[j].isPending { pages[i].corrections[j].status = "accepted" }
        pages[i].updatedAt = .now; pages[i].dirty = true; save(); pushSoon()
    }
    /// grammar marks found for a page
    func setMarks(page id: UUID, _ marks: [TBMark], checked: [String], by: String) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].content.marks = marks.isEmpty ? nil : marks
        pages[i].content.checked = checked
        pages[i].content.checkedBy = by
        pages[i].updatedAt = .now; pages[i].dirty = true; save(); pushSoon()
    }


    // MARK: sync

    private var pushTask: Task<Void, Never>?
    /// a quiet upload a few seconds after a change
    private func pushSoon() {
        #if DEBUG
        if ephemeral { return }
        #endif
        guard Cloud.shared.signedIn else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await sync(quiet: true)
        }
    }

    /// Pulls what changed on other devices, then uploads what changed here.
    func sync(quiet: Bool = false) async {
        #if DEBUG
        if ephemeral { return }
        #endif
        guard Cloud.shared.signedIn, !syncing, let uid = Cloud.shared.session?.userID.lowercased() else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await pull()
            try await push(uid)
            save()
            if !quiet { syncMessage = nil }
        } catch {
            save()
            let text = error.localizedDescription
            DevLog.add("textbook", "sync failed: \(text)")
            if text.contains("textbook_free_limit") {
                syncMessage = "免費版只能同步 1 課（最多 3 頁），升級 Pro 就能同步全部。"
            } else if text.contains("textbook_page_limit") {
                syncMessage = "已經到 1000 頁的上限，刪掉一些頁面才能再上傳。"
            } else if text.contains("Could not find the table") || text.contains("relation") {
                syncMessage = "課文書架的雲端還沒開通，先存在這支手機。"
            } else {
                syncMessage = text
            }
        }
    }

    private func rest(_ table: String, _ query: [URLQueryItem]) -> URL {
        var c = URLComponents(url: CloudConfig.url.appendingPathComponent("rest/v1/" + table), resolvingAgainstBaseURL: false)!
        c.queryItems = query
        return c.url!
    }

    private func pull() async throws {
        var newest = cursor
        func fetch(_ table: String) async throws -> [[String: Any]] {
            var rows: [[String: Any]] = [], offset = 0
            while true {
                var q = [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "updated_at.asc"),
                         URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "offset", value: "\(offset)")]
                if let cursor { q.append(URLQueryItem(name: "updated_at", value: "gte.\(cursor)")) }
                let d = try await Cloud.shared.sendRaw(rest(table, q), method: "GET")
                let page = (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? []
                rows += page
                if page.count < 200 { break }
                offset += page.count
            }
            for r in rows { if let u = r["updated_at"] as? String, u > (newest ?? "") { newest = u } }
            return rows
        }
        for r in try await fetch("books") { merge(book: r) }
        for r in try await fetch("lessons") { merge(lesson: r) }
        for r in try await fetch("pages") { merge(page: r) }
        cursor = newest
    }

    private func merge(book r: [String: Any]) {
        guard let id = (r["id"] as? String).flatMap(UUID.init), let title = r["title"] as? String else { return }
        let b = TBBook(id: id, title: title, subject: r["subject"] as? String,
                       createdAt: TBDate.parse(r["created_at"]) ?? .now, updatedAt: TBDate.parse(r["updated_at"]) ?? .now,
                       deletedAt: TBDate.parse(r["deleted_at"]), dirty: false)
        if let i = books.firstIndex(where: { $0.id == id }) {
            if books[i].dirty { return }
            books[i] = b
        } else { books.append(b) }
    }
    private func merge(lesson r: [String: Any]) {
        guard let id = (r["id"] as? String).flatMap(UUID.init), let book = (r["book_id"] as? String).flatMap(UUID.init),
              let title = r["title"] as? String else { return }
        let l = TBLesson(id: id, bookID: book, title: title, sort: r["sort"] as? Int ?? 0, lastReadPage: r["last_read_page"] as? Int ?? 0,
                         updatedAt: TBDate.parse(r["updated_at"]) ?? .now, deletedAt: TBDate.parse(r["deleted_at"]), dirty: false)
        if let i = lessons.firstIndex(where: { $0.id == id }) {
            if lessons[i].dirty { return }
            lessons[i] = l
        } else { lessons.append(l) }
    }
    private func merge(page r: [String: Any]) {
        guard let id = (r["id"] as? String).flatMap(UUID.init), let lesson = (r["lesson_id"] as? String).flatMap(UUID.init),
              let contentAny = r["content"], let cd = try? JSONSerialization.data(withJSONObject: contentAny),
              let content = try? JSONDecoder().decode(TBContent.self, from: cd) else { return }
        let fixes = (r["corrections"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode([TBCorrection].self, from: $0) } ?? []
        let p = TBPage(id: id, lessonID: lesson, sort: r["sort"] as? Int ?? 0, imagePath: r["image_path"] as? String,
                       content: content, corrections: fixes, updatedAt: TBDate.parse(r["updated_at"]) ?? .now,
                       deletedAt: TBDate.parse(r["deleted_at"]), dirty: false)
        if let i = pages.firstIndex(where: { $0.id == id }) {
            if pages[i].dirty { return }
            pages[i] = p
        } else { pages.append(p) }
    }

    private func push(_ uid: String) async throws {
        let prefer = "resolution=merge-duplicates,return=minimal"
        func upsert(_ table: String, _ rows: [[String: Any]]) async throws {
            guard !rows.isEmpty else { return }
            for chunk in stride(from: 0, to: rows.count, by: 50).map({ Array(rows[$0..<min($0 + 50, rows.count)]) }) {
                let body = try JSONSerialization.data(withJSONObject: chunk)
                _ = try await Cloud.shared.sendRaw(rest(table, [URLQueryItem(name: "on_conflict", value: "id")]), method: "POST",
                                                   body: body, prefer: prefer, timeout: 60)
            }
        }
        let dirtyBooks = books.filter(\.dirty)
        try await upsert("books", dirtyBooks.map { b in
            ["id": b.id.uuidString.lowercased(), "user_id": uid, "title": b.title, "subject": b.subject ?? NSNull(),
             "created_at": TBDate.string(b.createdAt), "deleted_at": b.deletedAt.map(TBDate.string) ?? NSNull()]
        })
        for b in dirtyBooks { if let i = books.firstIndex(where: { $0.id == b.id && $0.updatedAt == b.updatedAt }) { books[i].dirty = false } }

        // a lesson whose book never reached the server can't go up yet
        let dirtyLessons = lessons.filter { l in l.dirty && !(book(l.bookID)?.dirty ?? true) }
        try await upsert("lessons", dirtyLessons.map { l in
            ["id": l.id.uuidString.lowercased(), "book_id": l.bookID.uuidString.lowercased(), "title": l.title, "sort": l.sort,
             "last_read_page": l.lastReadPage, "deleted_at": l.deletedAt.map(TBDate.string) ?? NSNull()]
        })
        for l in dirtyLessons { if let i = lessons.firstIndex(where: { $0.id == l.id && $0.updatedAt == l.updatedAt }) { lessons[i].dirty = false } }

        let dirtyPages = pages.filter { p in p.dirty && !(lesson(p.lessonID)?.dirty ?? true) }
        func row(_ p: TBPage) throws -> [String: Any] {
            let content = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p.content))
            let fixes = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p.corrections))
            return ["id": p.id.uuidString.lowercased(), "lesson_id": p.lessonID.uuidString.lowercased(), "sort": p.sort,
                    "image_path": p.imagePath ?? NSNull(), "content": content, "corrections": fixes,
                    "deleted_at": p.deletedAt.map(TBDate.string) ?? NSNull()]
        }
        try await upsert("pages", dirtyPages.map(row))

        for p in dirtyPages { if let i = pages.firstIndex(where: { $0.id == p.id && $0.updatedAt == p.updatedAt }) { pages[i].dirty = false } }

        // photos uploaded by an older build: delete them from Storage and clear the path
        var cleared: [TBPage] = []
        for p in pages where p.imagePath != nil && !(lesson(p.lessonID)?.dirty ?? true) {
            guard let path = p.imagePath else { continue }
            _ = try? await Cloud.shared.sendRaw(storage(path), method: "DELETE")
            if let i = pages.firstIndex(where: { $0.id == p.id }) { pages[i].imagePath = nil; cleared.append(pages[i]) }
        }
        try await upsert("pages", cleared.map(row))
        if !cleared.isEmpty { DevLog.add("textbook", "removed \(cleared.count) old page photos from the cloud") }
    }

    private func storage(_ path: String) -> URL {
        CloudConfig.url.appendingPathComponent("storage/v1/object/textbook-pages/" + path)
    }

    #if DEBUG
    /// Device testing (JUANGO_TEXTBOOK_DEMO=1): an in-memory shelf with one lesson made from a photo of the app's
    /// own sample text, read by the real OCR → layout → correction steps. Nothing is saved or synced.
    private(set) var ephemeral = false
    func addDemo() async {
        ephemeral = true
        books = []; lessons = []; pages = []
        let b = addBook(title: "示範課本", subject: "英文")
        let l = addLesson(to: b.id, title: "Lesson 1 A Walk in the Park")
        // (size, line); words in *stars* are printed bold
        let text: [(CGFloat, String)] = [
            (60, "*Lesson* *1*"), (46, "*A* *Walk* *in* *the* *Park*"), (38, ""),
            (38, "Every morning, Lily takes a walk in the park"),
            (38, "near her house. She likes to watch the birds and"),
            (38, "listen to the wind in the trees. One day she found"),
            (38, "a srnall dog sitting alone under a *bench*. It looked"),
            (38, "so tired that she shared her bread with it. The dog"),
            (38, "followed her all the way home."), (38, ""),
            (38, "     Lily decided to put up *posters* around the neigh-"),
            (38, "borhood. Two days later, an old man knocked on her"),
            (38, "door. He was not only kind but also very *grateful*,"),
            (38, "because the dog was his only cornpanion."), (38, ""), (38, ""), (38, "12")]
        let list: [(CGFloat, String)] = [
            (44, "Vocabulary 生字"),
            (36, "1. bench n. 長椅"), (36, "2. poster n. 海報"), (36, "3. grateful adj. 感激的"),
            (36, "4. companion n. 同伴；伴侶"), (36, ""),
            (44, "Words for Recognition 一般生字"),
            (36, "5. neighborhood n. 鄰近地區"), (36, "6. hungry adj. 飢餓的"), (36, ""),
            (44, "Phrases 片語"),
            (36, "7. put up 張貼"), (36, "8. all the way 一路上"), (36, ""),
            (44, "Grammar 文法重點"),
            (36, "1. not only … but also … 不但…而且…"),
            (36, "2. so + adj. + that … 如此…以致於…")]
        func page(_ lines: [(CGFloat, String)]) -> UIImage {
            let size = CGSize(width: 1200, height: 1500)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
                var y: CGFloat = 70
                for (pt, line) in lines {
                    let plain = UIFont(name: "Georgia", size: pt) ?? .systemFont(ofSize: pt)
                    let bold = UIFont(name: "Georgia-Bold", size: pt) ?? .boldSystemFont(ofSize: pt)
                    let out = NSMutableAttributedString()
                    for (i, part) in line.components(separatedBy: " ").enumerated() {
                        if i > 0 { out.append(NSAttributedString(string: " ", attributes: [.font: plain])) }
                        let isBold = part.hasPrefix("*") && part.count > 1
                        let t = isBold ? part.replacingOccurrences(of: "*", with: "") : part
                        out.append(NSAttributedString(string: t, attributes: [.font: isBold ? bold : plain, .foregroundColor: UIColor.black]))
                    }
                    let x: CGFloat = line == "12" ? 580 : 70
                    out.draw(at: CGPoint(x: x, y: y))
                    y += pt * 1.63
                }
            }
        }
        _ = await PageImporter.add([page(text), page(list)], to: l.id) { _, _ in }
    }
    #endif
}

/// Postgres timestamps ("2026-11-21T10:00:00.123456+00:00") to and from Date.
nonisolated enum TBDate {
    static func parse(_ any: Any?) -> Date? {
        guard var s = any as? String else { return nil }
        // ISO8601DateFormatter takes at most 3 decimals
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = s[s.index(after: dot)..<end]
            s.replaceSubrange(dot..<end, with: "." + frac.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

// MARK: - Reading a photo into paragraphs

nonisolated enum PageReader {
    struct Line {
        var words: [TBWord]
        /// normalised, top-left origin
        var box: CGRect
        /// lines of one block (a paragraph's lines, of one size) share a number; a new block starts a new paragraph
        var block = 0
    }

    /// A word-list page (read with Chinese too, for the meanings) or lesson text (read as English, with
    /// titles and bold words). What isn't the page's text is cleared first (see PageCleaner), then laid out.
    static func read(_ cg: CGImage) async -> TBContent {
        let picture = PictureMap(cg)
        let chinese = await recognize(cg, languages: ["zh-Hant", "en-US"])
        if let vocab = VocabPage.read(PageCleaner.clean(chinese, picture: picture, mode: .list)) { return vocab }
        var lines = PageCleaner.clean(await recognize(cg, languages: ["en-US"]), picture: picture, mode: .lesson, chinese: chinese)
        if let ink = InkMap(cg) { BoldDetector.mark(&lines, ink: ink) }
        return layout(lines)
    }

    /// Vision lines with a box and confidence for each word (the same recogniser settings as the word scanner).
    static func recognize(_ cg: CGImage, languages: [String]) async -> [Line] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = TextRecognition.request(languages: languages)
                try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])
                var out: [Line] = []
                func r4(_ v: CGFloat) -> Double { (Double(v) * 10000).rounded() / 10000 }
                for obs in req.results ?? [] {
                    guard let cand = obs.topCandidates(1).first else { continue }
                    let s = cand.string
                    let conf = (Double(cand.confidence) * 100).rounded() / 100
                    var words: [TBWord] = []
                    for m in s.matches(of: /\S+/) {
                        let b = (try? cand.boundingBox(for: m.range))?.boundingBox
                        let box = b.map { [r4($0.minX), r4(1 - $0.maxY), r4($0.width), r4($0.height)] }
                        words.append(TBWord(t: String(s[m.range]), box: box, conf: conf))
                    }
                    let b = obs.boundingBox
                    out.append(Line(words: words, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)))
                }
                cont.resume(returning: out)
            }
        }
    }

    /// "title", "subtitle" or nil: a line clearly taller than the page's usual line, or a short line all in bold
    /// that doesn't end like a sentence.
    static func style(_ l: Line, lineH: CGFloat) -> String? {
        let r = l.box.height / lineH
        if r >= 1.45 { return "title" }
        if r >= 1.18 { return "subtitle" }
        let letters = l.words.filter { $0.core.contains(where: \.isLetter) }
        if letters.count >= 1, letters.count <= 10, letters.allSatisfy(\.isBold), !endsSentence(l.words.last?.t ?? "") || letters.count <= 4 {
            return "subtitle"
        }
        return nil
    }

    /// Lines → paragraphs → sentences: drops page numbers and running headers/footers, keeps titles and
    /// subtitles as their own paragraphs, joins words broken with a hyphen at the end of a line, and starts a
    /// new paragraph at a new block, a gap, an indent or a short last line.
    static func layout(_ raw: [Line]) -> TBContent {
        let all = raw.filter { !$0.words.isEmpty }
        guard !all.isEmpty else { return TBContent() }
        func median(_ a: [CGFloat]) -> CGFloat { let s = a.sorted(); return s[s.count / 2] }
        let lineH = max(median(all.map(\.box.height)), 0.005)
        let lines = all.filter { !isFurniture($0, lineH: lineH) }
        guard !lines.isEmpty else { return TBContent() }
        let body = lines.filter { style($0, lineH: lineH) == nil }
        let left = median((body.isEmpty ? lines : body).map(\.box.minX))
        let widths = (body.isEmpty ? lines : body).map(\.box.width).sorted()
        let fullW = widths[widths.count * 3 / 4]

        var paragraphs: [(words: [TBWord], style: String?)] = []
        var current: [TBWord] = []
        var currentStyle: String?
        var prev: Line?
        func close() { if !current.isEmpty { paragraphs.append((current, currentStyle)) }; current = [] }
        for line in lines {
            var words = line.words
            let st = style(line, lineH: lineH)
            if let p = prev {
                let gap = line.box.minY - p.box.maxY
                let endsSentence = endsSentence(current.last?.t ?? "")
                let newColumn = gap < -lineH * 1.5
                let indented = line.box.minX - left > lineH * 1.2
                let shortLast = p.box.width < fullW * 0.8
                if st != currentStyle || line.block != p.block || (st != nil && gap > lineH * 0.9) {
                    close()
                } else if st != nil {
                    // a title that wraps onto a second line stays one title
                } else if gap > lineH * 0.9 || newColumn || (endsSentence && (indented || shortLast)) {
                    close()
                } else if let last = current.last, last.t.count > 2, last.t.hasSuffix("-") || last.t.hasSuffix("‐"),
                          let first = words.first, first.t.first?.isLowercase == true {
                    // "impor-" + "tant" → "important"
                    var merged = current.removeLast()
                    merged.t = String(merged.t.dropLast()) + first.t
                    merged.conf = min(merged.conf ?? 1, first.conf ?? 1)
                    if first.isBold { merged.bold = true }
                    current.append(merged)
                    words.removeFirst()
                }
            }
            currentStyle = st
            current += words
            prev = line
        }
        close()
        return TBContent(paragraphs: paragraphs.map {
            TBParagraph(sentences: $0.style == nil ? sentences($0.words) : [TBSentence(words: $0.words)], style: $0.style)
        })
    }

    private static let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "st.", "e.g.", "i.e.", "etc.", "vs.", "no.", "p."]

    static func endsSentence(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        guard let c = s.last, ".!?:".contains(c) else { return false }
        return !abbreviations.contains(s.lowercased())
    }

    static func sentences(_ words: [TBWord]) -> [TBSentence] {
        var out: [TBSentence] = [], cur: [TBWord] = []
        for (i, w) in words.enumerated() {
            cur.append(w)
            let next = i + 1 < words.count ? words[i + 1].t.first : nil
            if endsSentence(w.t) && !w.t.hasSuffix(":") && (next == nil || next?.isLowercase == false) {
                out.append(TBSentence(words: cur)); cur = []
            }
        }
        if !cur.isEmpty { out.append(TBSentence(words: cur)) }
        return out
    }

    /// page numbers ("12", "- 12 -", "p. 12") and short lines in the top or bottom 5% (running headers)
    static func isFurniture(_ l: Line, lineH: CGFloat) -> Bool {
        let text = l.words.map(\.t).joined(separator: " ")
        if text.range(of: #"^[\W_]*(p\.|page)?\s*\d{1,4}[\W_]*$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return (l.box.maxY < 0.05 || l.box.minY > 0.95) && l.words.count <= 6 && l.box.height < lineH * 1.15
    }
}

// MARK: - Fixing OCR mistakes (only spelling slips, never the text's own wording)

#if canImport(FoundationModels)
@Generable
struct OCRFix {
    @Guide(description: "The word exactly as it was given")
    var original: String
    @Guide(description: "The correct spelling if the word is clearly an OCR misreading; otherwise the original unchanged")
    var suggestion: String
    @Guide(description: "How sure you are that it is a misreading, 0 to 1")
    var confidence: Double
}

@Generable
struct OCRFixList {
    @Guide(description: "One entry per numbered word, in the same order")
    var fixes: [OCRFix]
}
#endif

enum OCRFixer {
    struct Candidate {
        let pos: TBPos
        let word: String
        let sentence: String
        /// unknown to every dictionary (not just a low-confidence read)
        let unknown: Bool
    }

    static var aiAvailable: Bool {
        #if canImport(FoundationModels)
        SystemLanguageModel.default.availability == .available
        #else
        false
        #endif
    }

    /// Suggestions for a newly read page: Apple Intelligence when allowed and available, the dictionary otherwise.
    static func suggest(_ c: TBContent, ai: Bool) async -> [TBCorrection] {
        let cands = candidates(c)
        guard !cands.isEmpty else { return [] }
        if ai, aiAvailable, let fixes = await aiFixes(cands) { return fixes }
        return dictionarySuggestions(c, cands)
    }

    /// Words worth checking: not in words.json nor the system's English dictionary, or read with low
    /// confidence. Names (a capital in mid-sentence) and all-caps headings are left alone.
    static func candidates(_ c: TBContent) -> [Candidate] {
        var out: [Candidate] = []
        for (p, para) in c.paragraphs.enumerated() {
            for (s, sen) in para.sentences.enumerated() {
                let sentence = sen.words.map(\.t).joined(separator: " ")
                for (w, word) in sen.words.enumerated() {
                    let core = word.core
                    guard core.count >= 2, core.contains(where: \.isLetter) else { continue }
                    if core.first?.isUppercase == true && w > 0 { continue }
                    if core.count > 1 && core == core.uppercased() && !core.contains(where: \.isNumber) { continue }
                    let mixedDigits = core.contains(where: \.isNumber)
                    let unknown = mixedDigits || !isKnown(core)
                    if unknown || (word.conf ?? 1) < 0.5 {
                        out.append(Candidate(pos: TBPos(p: p, s: s, w: w), word: core, sentence: sentence, unknown: unknown))
                    }
                }
            }
        }
        return Array(out.prefix(40))
    }

    static func isKnown(_ w: String) -> Bool { Dictionary_.lookup(w) != nil || spelledRight(w) }

    private static let checker = UITextChecker()
    static func spelledRight(_ w: String) -> Bool {
        guard !w.contains(where: \.isNumber) else { return false }
        let r = checker.rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: w.utf16.count),
                                              startingAt: 0, wrap: false, language: "en_US")
        return r.location == NSNotFound
    }

    /// A suggestion is kept only when it's a real word within 2 edits of what was read.
    static func acceptable(_ original: String, _ suggestion: String) -> Bool {
        let s = suggestion.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.lowercased() != original.lowercased(), distance(original.lowercased(), s.lowercased()) <= 2 else { return false }
        return s.split(separator: " ").allSatisfy { isKnown(String($0)) }
    }

    /// keeps the capital of the word as printed
    static func matchCase(_ s: String, like original: String) -> String {
        guard original.first?.isUppercase == true, let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    private static func aiFixes(_ cands: [Candidate]) async -> [TBCorrection]? {
        #if canImport(FoundationModels)
        var out: [TBCorrection] = []
        for chunk in stride(from: 0, to: cands.count, by: 20).map({ Array(cands[$0..<min($0 + 20, cands.count)]) }) {
            let session = LanguageModelSession(instructions: """
                這是 OCR 辨識的英文課文。只在字明顯是辨識錯誤時，給出正確拼法；不確定就原樣回傳。不要改文法或用字。
                Typical OCR slips: "rn" read as "m" or the other way round, l / 1 / I mixed up, 0 for o, a missing letter, \
                two words stuck together. Never rewrite the sentence, never change a correct word into a better word.
                """)
            let list = chunk.enumerated().map { "\($0.offset + 1). word: \($0.element.word) | sentence: \($0.element.sentence)" }
            guard let r = try? await session.respond(to: "Check these words:\n" + list.joined(separator: "\n"),
                                                     generating: OCRFixList.self).content else { return out.isEmpty ? nil : out }
            for (i, f) in r.fixes.enumerated() {
                // match by position first, by the word itself if the model skipped one
                let c = i < chunk.count && chunk[i].word == f.original ? chunk[i] : chunk.first { $0.word == f.original }
                guard let c, f.confidence >= 0.5, acceptable(c.word, f.suggestion), !out.contains(where: { $0.pos == c.pos }) else { continue }
                out.append(TBCorrection(p: c.pos.p, s: c.pos.s, w: c.pos.w, original: c.word,
                                        suggestion: matchCase(f.suggestion.trimmingCharacters(in: .whitespaces), like: c.word),
                                        source: "ai", status: "pending"))
            }
        }
        return out
        #else
        return nil
        #endif
    }

    /// Without Apple Intelligence: the closest common word in the dictionary, for words no dictionary knows.
    static func dictionarySuggestions(_ c: TBContent, _ given: [Candidate]? = nil) -> [TBCorrection] {
        (given ?? candidates(c)).filter(\.unknown).compactMap { cand in
            guard let s = dictionaryFix(cand.word) else { return nil }
            return TBCorrection(p: cand.pos.p, s: cand.pos.s, w: cand.pos.w, original: cand.word,
                                suggestion: matchCase(s, like: cand.word), source: "dictionary", status: "pending")
        }
    }

    private static let confusions: [(String, String)] = [("rn", "m"), ("m", "rn"), ("cl", "d"), ("vv", "w"), ("1", "l"), ("1", "i"),
                                                          ("0", "o"), ("5", "s"), ("l", "i"), ("i", "l"), ("I", "l"), ("li", "h"), ("ii", "u")]
    /// single words from words.json, by length, for the edit-distance search
    private static let byLength: [Int: [DictEntry]] = Dictionary(grouping: Dictionary_.all.filter { !$0.w.contains(" ") && !$0.zh.isEmpty },
                                                                 by: { $0.w.count })
    private static func rank(_ e: DictEntry) -> Int { Int(e.lv) ?? 7 }

    static func dictionaryFix(_ raw: String) -> String? {
        let w = raw.lowercased()
        // 1. the usual OCR confusions, one at a time ("srnall" → "small", "1ike" → "like")
        for (from, to) in confusions {
            var search = w.startIndex
            while search < w.endIndex, let r = w.range(of: from.lowercased(), range: search..<w.endIndex) {
                let v = w.replacingCharacters(in: r, with: to)
                if Dictionary_.lookup(v)?.w == v || spelledRight(v) { return v }
                search = r.upperBound
            }
        }
        // 2. two words stuck together ("inthe" → "in the")
        if w.count >= 5, !w.contains(where: \.isNumber) {
            for i in 2...(w.count - 2) {
                let a = String(w.prefix(i)), b = String(w.dropFirst(i))
                if let ea = Dictionary_.lookup(a), ea.w == a, let eb = Dictionary_.lookup(b), eb.w == b, rank(ea) <= 3, rank(eb) <= 4 {
                    return a + " " + b
                }
            }
        }
        // 3. the nearest common word, only when one stands out
        var best: [(DictEntry, Int)] = []
        for len in max(2, w.count - 2)...(w.count + 2) {
            for e in byLength[len] ?? [] {
                let d = distance(w, e.w.lowercased())
                if d <= 2 { best.append((e, d)) }
            }
        }
        guard let minD = best.map(\.1).min() else { return nil }
        let top = best.filter { $0.1 == minD }.sorted { rank($0.0) < rank($1.0) }
        if top.count == 1 || rank(top[0].0) < rank(top[1].0) { return top[0].0.w }
        return nil
    }

    /// Damerau–Levenshtein (adjacent swaps count as one edit).
    nonisolated static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 0...x.count { d[i][0] = i }
        for j in 0...y.count { d[0][j] = j }
        for i in 1...x.count {
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[x.count][y.count]
    }
}

// MARK: - Turning photos into pages

enum PageImporter {
    /// Reads each photo and adds it to the lesson. Stops at the page limit; returns how many were added.
    @MainActor
    static func add(_ images: [UIImage], to lesson: UUID, progress: (Int, Int) -> Void) async -> Int {
        let shelf = Shelf.shared
        var added = 0
        for (i, img) in images.enumerated() {
            guard shelf.pagesLeft > 0 else { break }
            progress(i + 1, images.count)
            let up = PhotoScanner.upright(img)
            guard let cg = up.cgImage else { continue }
            let content = await PageReader.read(cg)
            let fixes = content.isVocab ? [] : await OCRFixer.suggest(content, ai: shelf.aiFixes)
            shelf.addPage(to: lesson, content: content, corrections: fixes)
            if content.isVocab {
                DevLog.add("textbook", "word list read: \(content.entries?.count ?? 0) entries, \(content.grammar?.count ?? 0) grammar points")
            } else {
                let bold = content.allWords.filter(\.word.isBold).count
                let titles = content.paragraphs.filter { $0.style != nil }.count
                DevLog.add("textbook", "page read: \(content.allWords.count) words, \(content.paragraphs.count) paragraphs (\(titles) titles), \(bold) bold, \(fixes.count) suggestions (\(shelf.aiFixes ? "AI" : "dictionary"))")
            }
            added += 1
        }
        if added > 0 { await shelf.markGrammar(lesson) }
        return added
    }
}
