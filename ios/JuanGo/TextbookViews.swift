import SwiftUI
import SwiftData
import PhotosUI
import VisionKit
import PDFKit
import UniformTypeIdentifiers
import Translation

// MARK: - Shelf

/// 課文書架: scanned textbooks, read like e-books. Pro; a free account can try 1 lesson of up to 3 pages.
struct BookshelfView: View {
    @State private var openLesson: UUID?
    @State private var newBook = false
    @State private var paywall = false
    private var shelf: Shelf { .shared }
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let m = shelf.syncMessage {
                    Label { Text(m) } icon: { LIcon("exclamationmark.icloud") }
                        .font(.app(.footnote)).foregroundStyle(.secondary)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.cardFill))
                }
                if shelf.liveBooks.isEmpty {
                    EmptyState("書架還是空的", icon: "books.vertical",
                               message: "拍下課本、講義或補充閱讀，整理成可以點字查詢的電子書。")
                    Button { add() } label: { Text("新增第一本書") }
                        .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(shelf.liveBooks) { b in
                            NavigationLink { BookView(bookID: b.id) } label: { BookCover(book: b) }.buttonStyle(.plain)
                        }
                    }
                }
                footer
            }
            .padding(20)
        }
        .themedBackground()
        .navigationTitle("課文書架")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { add() } label: { LIcon("plus") }.accessibilityLabel("新增書")
            }
            if Cloud.shared.signedIn {
                ToolbarItem(placement: .secondaryAction) {
                    Button("立即同步", pulso: "arrow.triangle.2.circlepath") { Task { await shelf.sync() } }
                }
            }
        }
        .sheet(isPresented: $newBook) { BookEditor(bookID: nil) }
        .sheet(isPresented: $paywall) { ProPaywall() }
        .task { await shelf.sync(quiet: true) }
        .refreshable { await shelf.sync() }
        .navigationDestination(item: $openLesson) { LessonReader(lessonID: $0) }
        #if DEBUG
        .task {   // JUANGO_TEXTBOOK=lesson opens the first lesson
            guard ProcessInfo.processInfo.environment["JUANGO_TEXTBOOK"] == "lesson" else { return }
            try? await Task.sleep(for: .seconds(1))
            if let b = shelf.liveBooks.first, let l = shelf.lessons(in: b.id).first { openLesson = l.id }
        }
        #endif
    }

    private func add() { if shelf.canAddBook { newBook = true } else { paywall = true } }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !shelf.isPro {
                Text("免費版可以試用 1 課（最多 3 頁），閱讀和點字查詢都能用；AI 修正和更多課要升級 Pro。")
            } else if shelf.pageCount >= Shelf.warnPages {
                Text("已用 \(shelf.pageCount) / \(Shelf.proPages) 頁，快到上限了。可以刪掉讀完的舊課。")
                    .foregroundStyle(Color.againInk)
            } else if shelf.pageCount > 0 {
                Text("已用 \(shelf.pageCount) / \(Shelf.proPages) 頁")
            }
            if !OCRFixer.aiAvailable {
                Text("開啟 Apple Intelligence 後修正會更準，現在用字典比對找出掃錯的字。")
            }
            Text("照片只用來辨識，存下來的是整理好的電子版，不保留原圖。")
            Text(Cloud.shared.signedIn ? "電子版會同步到你的其他裝置。" : "登入後就能在其他裝置閱讀。")
            Text("課文有著作權，書架只給自己看，不能分享或匯出。")
        }
        .font(.app(.footnote)).foregroundStyle(.secondary)
    }
}

private struct BookCover: View {
    let book: TBBook
    private var shelf: Shelf { .shared }

    var body: some View {
        let lessons = shelf.lessons(in: book.id)
        let last = lessons.max { $0.updatedAt < $1.updatedAt }
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.themeAccent.opacity(0.18))
                Text(book.title).font(.app(.title3, .bold)).foregroundStyle(Color.themeAccent)
                    .multilineTextAlignment(.center).padding(12)
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            Text(book.title).font(.app(.headline)).lineLimit(1)
            Text([book.subject, "\(lessons.count) 課"].compactMap { $0 }.joined(separator: "・"))
                .font(.app(.caption)).foregroundStyle(.secondary)
            if let last {
                Text("讀到 \(last.title) 第 \(last.lastReadPage + 1) 頁").font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// New book, or the title and subject of one.
private struct BookEditor: View {
    let bookID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var subject = ""
    private var shelf: Shelf { .shared }

    var body: some View {
        NavigationStack {
            Form { Group {
                Section {
                    TextField("書名，例如「龍騰 B3」", text: $title)
                    TextField("科目（可以不填）", text: $subject)
                } footer: {
                    Text("建好以後在書裡新增一課，再拍照或匯入課文。")
                }
            }.listRowBackground(Color.cardFill) }
            .font(.app(.body))
            .themedBackground()
            .navigationTitle(bookID == nil ? "新增書" : "編輯書")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        let t = title.trimmingCharacters(in: .whitespaces), s = subject.trimmingCharacters(in: .whitespaces)
                        if let bookID { shelf.updateBook(bookID, title: t, subject: s) } else { shelf.addBook(title: t, subject: s) }
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty).bold()
                }
            }
            .onAppear {
                if let bookID, let b = shelf.book(bookID) { title = b.title; subject = b.subject ?? "" }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Book (its lessons)

struct BookView: View {
    let bookID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var naming: UUID?? = nil      // .some(nil) = new lesson, .some(id) = rename
    @State private var name = ""
    @State private var open: UUID?
    @State private var paywall = false
    @State private var editing = false
    @State private var confirmDelete = false
    private var shelf: Shelf { .shared }

    var body: some View {
        let lessons = shelf.lessons(in: bookID)
        List {
            Group {
                Section {
                    ForEach(lessons) { l in
                        NavigationLink { LessonReader(lessonID: l.id) } label: { row(l) }
                            .swipeActions { Button("刪除", pulso: "trash", role: .destructive) { shelf.deleteLesson(l.id) } }
                            .contextMenu {
                                Button("重新命名", pulso: "pencil") { name = l.title; naming = .some(l.id) }
                                Button("刪除", pulso: "trash", role: .destructive) { shelf.deleteLesson(l.id) }
                            }
                    }
                    Button { newLesson(count: lessons.count) } label: {
                        Label { Text("新增一課") } icon: { LIcon(shelf.canAddLesson ? "plus" : "lock.fill") }
                    }
                } footer: {
                    if !shelf.isPro { Text("免費版可以建 1 課（最多 3 頁）。") }
                }
            }
            .listRowBackground(Color.cardFill)
        }
        .themedBackground()
        .navigationTitle(shelf.book(bookID)?.title ?? "")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) { Button("編輯書名", pulso: "pencil") { editing = true } }
            ToolbarItem(placement: .secondaryAction) {
                Button("刪除這本書", pulso: "trash", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationDestination(item: $open) { LessonReader(lessonID: $0) }
        .sheet(isPresented: $editing) { BookEditor(bookID: bookID) }
        .sheet(isPresented: $paywall) { ProPaywall() }
        .alert(naming == .some(nil) ? "新增一課" : "重新命名", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("例如 Lesson 3", text: $name)
            Button("取消", role: .cancel) {}
            Button(naming == .some(nil) ? "新增" : "儲存") {
                let t = name.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, let target = naming else { return }
                if let id = target { shelf.renameLesson(id, title: t) } else { open = shelf.addLesson(to: bookID, title: t).id }
            }
        } message: { Text("標題之後也可以改。") }
        .alert("刪除「\(shelf.book(bookID)?.title ?? "")」？", isPresented: $confirmDelete) {
            Button("刪除這本書和所有課", role: .destructive) { shelf.deleteBook(bookID); dismiss() }
            Button("取消", role: .cancel) {}
        } message: { Text("所有裝置上的這本書都會刪掉，無法復原。") }
    }

    private func row(_ l: TBLesson) -> some View {
        let n = shelf.pages(in: l.id).count
        return VStack(alignment: .leading, spacing: 3) {
            Text(l.title).font(.app(.headline))
            Text(n == 0 ? "還沒有頁面" : "\(n) 頁・讀到第 \(min(l.lastReadPage, n - 1) + 1) 頁")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    private func newLesson(count: Int) {
        guard shelf.canAddLesson else { paywall = true; return }
        name = "第 \(count + 1) 課"
        naming = .some(nil)
    }
}

// MARK: - Reading a lesson

struct LessonReader: View {
    let lessonID: UUID
    @Environment(\.dismiss) private var dismiss
    @AppStorage("textbook.scale") private var scale = 1.15
    @AppStorage("textbook.levels") private var levels = false
    @State private var index = 0
    @State private var progress: (Int, Int)?
    @State private var paywall = false
    @State private var camera = false
    @State private var photos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var files = false
    @State private var renaming = false
    @State private var name = ""
    @State private var notice: String?
    private var shelf: Shelf { .shared }

    var body: some View {
        let pages = shelf.pages(in: lessonID)
        Group {
            if pages.isEmpty {
                VStack(spacing: 14) {
                    EmptyState("這課還沒有頁面", icon: "doc.viewfinder",
                               message: "課文和單字表都拍進來。一次可以拍好幾頁，App 會自動裁切、拉正，整理成電子版。")
                    addButtons
                }
                .padding(24)
            } else {
                TabView(selection: $index) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                        PageView(pageID: p.id, lessonID: lessonID, scale: scale, levels: levels).tag(i)
                    }
                    LessonWordsView(lessonID: lessonID).tag(pages.count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .safeAreaInset(edge: .bottom) { bottomBar(pages) }
            }
        }
        .themedBackground()
        .navigationTitle(shelf.lesson(lessonID)?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { menu(pages) } }
        .overlay {
            if let progress {
                ProgressView("正在整理第 \(progress.0) / \(progress.1) 頁…")
                    .font(.app(.body)).padding(24).background(.regularMaterial, in: .rect(cornerRadius: Radius.lg))
            }
        }
        .onAppear { if let l = shelf.lesson(lessonID) { index = min(l.lastReadPage, max(0, pages.count - 1)) } }
        .task { await shelf.markGrammar(lessonID) }
        .onChange(of: index) { _, i in if i < pages.count { shelf.setLastRead(lessonID, page: i) } }
        .fullScreenCover(isPresented: $camera) {
            DocumentCamera { add($0) }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $photos, selection: $photoItems, maxSelectionCount: 20, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var images: [UIImage] = []
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { images.append(img) }
                }
                photoItems = []
                add(images)
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var images: [UIImage] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if url.pathExtension.lowercased() == "pdf" { images += PDFPages.images(url) }
                else if let img = UIImage(contentsOfFile: url.path) { images.append(img) }
            }
            add(images)
        }
        .sheet(isPresented: $paywall) { ProPaywall() }
        .alert("重新命名", isPresented: $renaming) {
            TextField("課名", text: $name)
            Button("取消", role: .cancel) {}
            Button("儲存") { let t = name.trimmingCharacters(in: .whitespaces); if !t.isEmpty { shelf.renameLesson(lessonID, title: t) } }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) {}
        }
        #if DEBUG
        .task {   // JUANGO_TEXTBOOK_VIEW=words | list (the word-list page)
            switch ProcessInfo.processInfo.environment["JUANGO_TEXTBOOK_VIEW"] {
            case "words": index = pages.count
            case "list": index = pages.firstIndex { $0.content.isVocab } ?? 0
            default: break
            }
        }
        #endif
    }

    private var addButtons: some View {
        VStack(spacing: 10) {
            Button { start { camera = true } } label: { Label("拍照", pulso: "camera.viewfinder") }
                .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
            Button { start { photos = true } } label: { Label("從相簿選照片", pulso: "photo.stack") }
                .buttonStyle(PillButtonStyle())
            Button { start { files = true } } label: { Label("匯入 PDF 或圖片檔", pulso: "doc") }
                .buttonStyle(PillButtonStyle())
        }
    }

    private func menu(_ pages: [TBPage]) -> some View {
        Menu {
            Section("字級") {
                Button("放大字", pulso: "textformat.size.larger") { scale = min(2, scale + 0.1) }
                Button("縮小字", pulso: "textformat.size.smaller") { scale = max(0.8, scale - 0.1) }
            }
            Toggle("顯示大考等級顏色", isOn: $levels)
            Section("新增頁面") {
                Button("拍照", pulso: "camera.viewfinder") { start { camera = true } }
                Button("從相簿選照片", pulso: "photo.stack") { start { photos = true } }
                Button("匯入 PDF 或圖片檔", pulso: "doc") { start { files = true } }
            }
            Button("重新命名這課", pulso: "pencil") { name = shelf.lesson(lessonID)?.title ?? ""; renaming = true }
            if index < pages.count {
                Button("刪除這一頁", pulso: "trash", role: .destructive) {
                    shelf.deletePage(pages[index].id)
                    index = max(0, index - 1)
                }
            }
        } label: { LIcon("ellipsis.circle") }
        .accessibilityLabel("更多")
    }

    @ViewBuilder private func bottomBar(_ pages: [TBPage]) -> some View {
        HStack {
            Text(index < pages.count ? "第 \(index + 1) / \(pages.count) 頁\(pages[index].content.isVocab ? "・單字表" : "")" : "這課的生字")
                .font(.app(.footnote, .semibold)).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if index < pages.count, case let n = pages[index].pending.count, n > 0 {
                Button("全部接受 \(n) 個修正") { shelf.acceptAll(page: pages[index].id) }
                    .font(.app(.footnote, .semibold))
                    .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    /// Opens an import only when there's room for another page.
    private func start(_ open: () -> Void) {
        if shelf.pagesLeft > 0 { open() } else { paywall = true }
    }

    private func add(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(350))   // let the camera or picker finish closing
            let before = shelf.pages(in: lessonID).count
            let added = await PageImporter.add(images, to: lessonID) { progress = ($0, $1) }
            progress = nil
            if added > 0 { index = before }
            if added < images.count {
                if shelf.isPro { notice = "已經到 \(Shelf.proPages) 頁的上限，只加入了 \(added) 頁。" }
                else { paywall = true }
            }
        }
    }
}

// MARK: - One page

private struct WordTap: Identifiable {
    let page: UUID
    let pos: TBPos
    var id: String { "\(page)-\(pos.p)-\(pos.s)-\(pos.w)" }
}

/// Colours for the word list's kinds and the grammar marks, the same in the text, the legend and the list.
enum TBStyle {
    static func color(_ kind: String) -> Color {
        switch kind {
        case "general": Color.hsnuSky
        case "phrase": Color.hsnuMagenta
        case "grammar": Color.knowInk
        default: Color.themeAccent
        }
    }
    static let grammarFill = Color.knowInk.opacity(0.13)
}

private struct PageView: View {
    let pageID: UUID
    let lessonID: UUID
    let scale: Double
    let levels: Bool
    @Query(filter: #Predicate<Word> { $0.inMyWords }) private var mine: [Word]
    @State private var tap: WordTap?
    @State private var lookup: LookupTerm?
    @State private var translating = false
    @State private var translateText = ""
    private var shelf: Shelf { .shared }

    var body: some View {
        if let page = shelf.page(pageID) {
            let saved = Set(mine.map(\.term))
            ScrollView {
                Group {
                    if page.content.isVocab {
                        VocabPageView(page: page, fontSize: fontSize, saved: saved) { lookup = LookupTerm(term: $0) }
                    } else {
                        textPage(page, saved: saved)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(item: $tap) { t in TBWordSheet(pageID: t.page, lessonID: lessonID, pos: t.pos) }
            .sheet(item: $lookup) { WordConfirmSheet(term: $0.term) }
            #if DEBUG
            .task {   // JUANGO_TEXTBOOK_VIEW=fix opens the first suggestion
                guard ProcessInfo.processInfo.environment["JUANGO_TEXTBOOK_VIEW"] == "fix", let c = page.pending.first else { return }
                try? await Task.sleep(for: .seconds(1))
                tap = WordTap(page: page.id, pos: c.pos)
            }
            #endif
            .translationPresentation(isPresented: $translating, text: translateText)
        }
    }

    private var fontSize: CGFloat { UIFont.preferredFont(forTextStyle: .body).pointSize * scale }

    @ViewBuilder private func textPage(_ page: TBPage, saved: Set<String>) -> some View {
        let index = shelf.index(lessonID)
        let found = index.marks(page)
        let marks = page.content.marks ?? []
        let grammarSentences = Set(marks.map { "\($0.p)-\($0.s)" })
        VStack(alignment: .leading, spacing: 18) {
            if page.content.isEmpty {
                Text("這頁沒有辨識到英文。可以刪掉這頁再拍一次。").font(.app(.body)).foregroundStyle(.secondary)
            }
            legend(kinds: Set(found.kinds.values), phrase: !found.phrase.isEmpty, grammar: !marks.isEmpty)
            ForEach(page.content.paragraphs.indices, id: \.self) { p in
                paragraph(page, p, saved: saved, found: found, grammar: grammarSentences)
            }
            if !marks.isEmpty { grammarList(page, marks, index) }
        }
    }

    /// what the colours mean, for the ones on this page
    @ViewBuilder private func legend(kinds: Set<String>, phrase: Bool, grammar: Bool) -> some View {
        let items: [(String, String)] = ["word", "general"].filter(kinds.contains).map { ($0, LessonIndex.kindName($0)) }
            + (phrase ? [("phrase", "片語")] : []) + (grammar ? [("grammar", "文法重點")] : [])
        if !items.isEmpty {
            HStack(spacing: 12) {
                ForEach(items, id: \.0) { kind, name in
                    HStack(spacing: 5) {
                        switch kind {
                        case "phrase": Rectangle().fill(TBStyle.color(kind)).frame(width: 14, height: 2)
                        case "grammar": RoundedRectangle(cornerRadius: 3).fill(TBStyle.grammarFill).frame(width: 14, height: 12)
                        default: Circle().fill(TBStyle.color(kind)).frame(width: 8, height: 8)
                        }
                        Text(name)
                    }
                }
            }
            .font(.app(.caption)).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func paragraph(_ page: TBPage, _ p: Int, saved: Set<String>,
                           found: (kinds: [TBPos: String], phrase: Set<TBPos>), grammar: Set<String>) -> some View {
        let para = page.content.paragraphs[p]
        let size = para.style == "title" ? fontSize * 1.55 : para.style == "subtitle" ? fontSize * 1.25 : fontSize
        let weight: Font.Weight? = para.style == "title" ? .bold : para.style == "subtitle" ? .semibold : nil
        return Text(attributed(page, p, saved: saved, found: found, grammar: grammar, size: size))
            .font(.app(size: size, weight))
            .lineSpacing(size * (para.style == nil ? 0.35 : 0.15))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, para.style == "subtitle" && p > 0 ? 6 : 0)
            .accessibilityAddTraits(para.style != nil ? .isHeader : [])
            .environment(\.openURL, OpenURLAction { url in
                let parts = url.pathComponents.compactMap { Int($0) }
                if parts.count == 3 { tap = WordTap(page: page.id, pos: TBPos(p: parts[0], s: parts[1], w: parts[2])) }
                return .handled
            })
            .contextMenu {
                ForEach(para.sentences.indices, id: \.self) { s in
                    let text = page.sentence(p: p, s: s)
                    Button("聽：\(text.prefix(28))\(text.count > 28 ? "…" : "")", pulso: "speaker.wave.2") { Speech.say(text) }
                }
                Button("翻譯這段", pulso: "translate") {
                    translateText = para.sentences.indices.map { page.sentence(p: p, s: $0) }.joined(separator: " ")
                    translating = true
                }
            }
    }

    private func attributed(_ page: TBPage, _ p: Int, saved: Set<String>,
                            found: (kinds: [TBPos: String], phrase: Set<TBPos>), grammar: Set<String>, size: CGFloat) -> AttributedString {
        var out = AttributedString()
        let isBody = page.content.paragraphs[p].style == nil
        for (s, sen) in page.content.paragraphs[p].sentences.enumerated() {
            let marked = grammar.contains("\(p)-\(s)")
            for (w, word) in sen.words.enumerated() {
                if s > 0 || w > 0 {
                    var space = AttributedString(" ")
                    if marked && w > 0 { space.backgroundColor = TBStyle.grammarFill }
                    out += space
                }
                let pos = TBPos(p: p, s: s, w: w)
                let fix = page.correction(at: pos)
                var run = AttributedString(TBText.apply(fix, to: word.t))
                if marked { run.backgroundColor = TBStyle.grammarFill }
                if word.isBold && isBody { run.font = .app(size: size, .bold) }
                let core = page.shown(pos)
                guard core.contains(where: \.isLetter) else { out += run; continue }
                run.link = URL(string: "juango-tb://w/\(p)/\(s)/\(w)")
                let entry = Dictionary_.lookup(core)
                let term = entry?.w ?? core.lowercased()
                if let kind = found.kinds[pos] {
                    run.foregroundColor = TBStyle.color(kind)
                    if kind == "word" && isBody { run.font = .app(size: size, .bold) }
                } else {
                    run.foregroundColor = levels ? Self.levelColor(entry?.lv) : Color.primary
                }
                if saved.contains(term) { run.backgroundColor = Color.themeAccent.opacity(0.16) }
                if fix?.isPending == true {
                    run.underlineStyle = Text.LineStyle(pattern: .dash, color: .orange)
                } else if found.phrase.contains(pos) {
                    run.underlineStyle = Text.LineStyle(pattern: .solid, color: TBStyle.color("phrase"))
                }
                out += run
            }
        }
        return out
    }

    /// 這頁的文法重點: each marked sentence with the point it uses
    private func grammarList(_ page: TBPage, _ marks: [TBMark], _ index: LessonIndex) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("這頁的文法重點").font(.app(.headline)).padding(.top, 8)
            ForEach(marks) { m in
                VStack(alignment: .leading, spacing: 5) {
                    Text(m.g).font(.app(.subheadline, .semibold)).foregroundStyle(TBStyle.color("grammar"))
                    Text(page.sentence(p: m.p, s: m.s)).font(.app(.subheadline))
                    if let why = m.why, !why.isEmpty {
                        Text("用到：\(why)").font(.app(.caption)).foregroundStyle(.secondary)
                    }
                    if let note = index.grammar.first(where: { $0.title == m.g })?.note {
                        Text(note).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(TBStyle.grammarFill))
                .accessibilityElement(children: .combine)
            }
            Text(page.content.checkedBy == "ai" ? "由 Apple Intelligence 對照這課單字表的文法重點找出。" : "依這課單字表文法重點的句型找出。")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    static func levelColor(_ lv: String?) -> Color {
        switch Int(lv ?? "") {
        case 1, 2: Color.knowInk
        case 3, 4: Color.hsnuSky
        case 5, 6: Color.hsnuMagenta
        default: Color.primary
        }
    }
}

/// A 單字表 page as a tidy list: 生字, 一般生字, 片語, then 文法重點.
private struct VocabPageView: View {
    let page: TBPage
    let fontSize: CGFloat
    let saved: Set<String>
    var onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("單字表").font(.app(size: fontSize * 1.55, .bold))
            ForEach(["word", "general", "phrase"], id: \.self) { kind in
                let list = (page.content.entries ?? []).filter { $0.kind == kind }
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(LessonIndex.kindName(kind)).font(.app(.title3, .bold)).foregroundStyle(TBStyle.color(kind))
                            .padding(.bottom, 6).accessibilityAddTraits(.isHeader)
                        ForEach(list) { e in
                            Button { onTap(e.t) } label: { row(e, kind) }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
            if let grammar = page.content.grammar, !grammar.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("文法重點").font(.app(.title3, .bold)).foregroundStyle(TBStyle.color("grammar")).accessibilityAddTraits(.isHeader)
                    ForEach(Array(grammar.enumerated()), id: \.offset) { i, g in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(i + 1). \(g.title)").font(.app(size: fontSize, .semibold))
                            if let note = g.note { Text(note).font(.app(.subheadline)).foregroundStyle(.secondary) }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(TBStyle.grammarFill))
                    }
                    Text("課文裡用到這些文法的句子會標出來。").font(.app(.caption)).foregroundStyle(.secondary)
                }
            }
            if (page.content.entries ?? []).isEmpty && (page.content.grammar ?? []).isEmpty {
                Text("這頁沒有辨識到單字。").font(.app(.body)).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ e: TBEntry, _ kind: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(e.t).font(.app(size: fontSize, .semibold)).foregroundStyle(.primary)
            if let pos = e.pos { Text(pos).font(.app(.subheadline)).italic().foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Text(e.meaning).font(.app(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            if saved.contains(Dictionary_.lookup(e.t)?.w ?? e.t) {
                LIcon("checkmark.circle.fill").font(.app(.subheadline)).foregroundStyle(Color.knowInk).accessibilityLabel("已在我的單字")
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Tapped word

/// The small card for a tapped word: meaning, IPA, level, listen, add to 我的單字, and any suggested fix.
private struct TBWordSheet: View {
    let pageID: UUID
    let lessonID: UUID
    let pos: TBPos
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var saved: Word?
    @State private var editing = false
    @State private var editText = ""
    @State private var lookup: LookupTerm?
    private var shelf: Shelf { .shared }

    var body: some View {
        let page = shelf.page(pageID)
        let shown = page?.shown(pos) ?? ""
        let entry = Dictionary_.lookup(shown)
        let fix = page?.correction(at: pos)
        let listed = shelf.index(lessonID).entry(for: shown)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry?.w ?? shown).font(.app(size: 34, .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                    SpeakButton(text: entry?.w ?? shown)
                    Spacer()
                    Button { dismiss() } label: { GlassCircleIcon(systemName: "xmark") }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                }
                HStack(spacing: 8) {
                    if let ipa = entry?.ipa, !ipa.isEmpty { Text("/\(ipa)/").foregroundStyle(.secondary) }
                    if let listed { Chip(text: "這課的\(LessonIndex.kindName(listed.kind))") }
                    if let lv = entry?.lv, Int(lv) != nil { Chip(text: "大考 \(lv) 級") }
                    else if entry?.tags?.contains("toeic") == true { Chip(text: "多益") }
                }
                .font(.app(.subheadline))
                if let listed, !listed.meaning.isEmpty {
                    Text([listed.pos, listed.meaning].compactMap { $0 }.joined(separator: " "))
                        .font(.app(.title3, .semibold)).foregroundStyle(.secondary)
                    Text("課本單字表的意思").font(.app(.caption)).foregroundStyle(.secondary)
                } else if let entry, !entry.zh.isEmpty {
                    Text([entry.pos, entry.zh.prefix(3).joined(separator: "；")].filter { !$0.isEmpty }.joined(separator: " "))
                        .font(.app(.title3, .semibold)).foregroundStyle(.secondary)
                } else {
                    Text("字典裡沒有這個字，加入時會幫你翻譯。").font(.app(.subheadline)).foregroundStyle(.secondary)
                }
                if let fix, fix.isPending { suggestion(fix) }
                else if let fix, fix.status == "accepted" {
                    Text("原本辨識成「\(fix.original)」，已改成「\(fix.suggestion)」（\(fix.sourceName)）")
                        .font(.app(.footnote)).foregroundStyle(.secondary)
                }
                if let saved, saved.inMyWords {
                    Label("已在我的單字", pulso: "checkmark.circle.fill").font(.app(.subheadline, .semibold)).foregroundStyle(Color.knowInk)
                } else {
                    Button { add(entry, shown, listed) } label: { Text("加入我的單字") }
                        .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent, glass: true))
                }
                Button { editText = shown; editing = true } label: { Label("修改辨識結果", pulso: "square.and.pencil") }
                    .buttonStyle(PillButtonStyle(foreground: .secondary))
            }
            .padding(22)
        }
        .font(.app(.body))
        .presentationDetents([.medium, .large])
        .presentationBackground(.regularMaterial)
        .task { saved = Library.word(entry?.w ?? shown, in: ctx) }
        .sheet(item: $lookup) { WordConfirmSheet(term: $0.term) { w in saved = w } }
        .alert("修改辨識結果", isPresented: $editing) {
            TextField("正確的字", text: $editText).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("取消", role: .cancel) {}
            Button("儲存") { manual(page) }
        } message: { Text("只改這一個字，課文的其他地方不會動。") }
    }

    private func suggestion(_ fix: TBCorrection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("原本：\(fix.original) → 建議：\(fix.suggestion)").font(.app(.headline))
            Text("由\(fix.sourceName)找出，可能是掃錯的字").font(.app(.caption)).foregroundStyle(.secondary)
            if let page = shelf.page(pageID) {
                Text(page.sentence(p: pos.p, s: pos.s)).font(.app(.subheadline)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { decide(fix, "accepted") } label: { Text("接受") }
                    .buttonStyle(PillButtonStyle(fill: .themeAccent, foreground: .onAccent))
                Button { decide(fix, "rejected") } label: { Text("保留原文") }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    private func decide(_ fix: TBCorrection, _ status: String) {
        var f = fix; f.status = status
        shelf.setCorrection(page: pageID, f)
    }

    private func manual(_ page: TBPage?) {
        let t = editText.trimmingCharacters(in: .whitespaces)
        guard let page, let word = page.content.word(pos), !t.isEmpty else { return }
        shelf.setCorrection(page: pageID, TBCorrection(p: pos.p, s: pos.s, w: pos.w, original: word.core, suggestion: t,
                                                       source: "manual", status: "accepted"))
        saved = Library.word(Dictionary_.lookup(t)?.w ?? t, in: ctx)
    }

    /// with the word list's meanings when the textbook lists the word
    private func add(_ entry: DictEntry?, _ shown: String, _ listed: TBEntry?) {
        let meanings = listed?.zh.flatMap { $0.isEmpty ? nil : $0 }
        if let entry, !entry.zh.isEmpty { saved = Library.add(entry, meanings: meanings, in: ctx) ?? saved }
        else if let listed, let meanings { saved = Library.add(.custom(listed.t, meaning: meanings[0]), meanings: meanings, in: ctx) ?? saved }
        else { lookup = LookupTerm(term: shown.lowercased()) }
    }
}

// MARK: - 這課的生字

private struct LessonWordsView: View {
    let lessonID: UUID
    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Word> { $0.inMyWords }) private var mine: [Word]
    @State private var lookup: LookupTerm?
    @State private var partial: Int?
    @State private var practice: StudyRequest?
    @State private var startAfterAdd = false
    private var shelf: Shelf { .shared }

    var body: some View {
        let saved = Set(mine.map(\.term))
        let all = shelf.lessonWords(lessonID)
        let fresh = all.filter { !saved.contains($0.entry.w) }
        let fromList = all.contains { $0.kind != "dict" }
        List {
            Group {
                if fresh.isEmpty {
                    Section {
                        Text(all.isEmpty ? "這課還沒有大考或多益單字。拍下課本的單字表，就會用課本列的生字。"
                             : "這課的生字都在「我的單字」裡了。")
                            .font(.app(.subheadline)).foregroundStyle(.secondary)
                    } header: { Text("這課的生字").font(.app(.headline)) }
                }
                ForEach(["word", "general", "phrase", "dict"], id: \.self) { kind in
                    let list = fresh.filter { $0.kind == kind }
                    if !list.isEmpty {
                        Section {
                            ForEach(list) { w in
                                Button { lookup = LookupTerm(term: w.entry.w) } label: { row(w) }
                            }
                        } header: {
                            Text(kind == "dict" ? "這課的生字" : LessonIndex.kindName(kind)).font(.app(.headline))
                        } footer: {
                            if kind == "dict" { Text("這課出現、還不在「我的單字」裡的大考字和多益字。") }
                        }
                    }
                }
                if !fresh.isEmpty {
                    Section {
                        Button("全部加入（\(fresh.count) 個）", pulso: "plus.circle") { addAll(fresh, thenStudy: false) }
                        Button("加入並開始練習", pulso: "play.circle") { addAll(fresh, thenStudy: true) }
                    } footer: {
                        if fromList { Text("用課本單字表上的意思加入。") }
                    }
                }
            }
            .listRowBackground(Color.cardFill)
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $lookup) { WordConfirmSheet(term: $0.term) }
        .quotaPartial($partial) { add(fresh, thenStudy: startAfterAdd) }
        .fullScreenCover(item: $practice) { StudyFlow(request: $0) }
    }

    private func row(_ w: LessonWord) -> some View {
        HStack {
            Text(w.entry.w).font(.app(.headline)).foregroundStyle(.primary)
            Text(w.meanings?.first ?? w.entry.zh.first ?? "").font(.app(.subheadline)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if Int(w.entry.lv) != nil { Text("\(w.entry.lv) 級").font(.app(.caption)).foregroundStyle(.secondary) }
            else if w.entry.tags?.contains("toeic") == true { Text("多益").font(.app(.caption)).foregroundStyle(.secondary) }
        }
    }

    private func addAll(_ words: [LessonWord], thenStudy: Bool) {
        startAfterAdd = thenStudy
        partial = WordQuota.batch(words.map(\.entry), list: nil, in: ctx) { add(words, thenStudy: thenStudy) }
    }

    private func add(_ words: [LessonWord], thenStudy: Bool) {
        let added = words.compactMap { Library.add($0.entry, meanings: $0.meanings, in: ctx) }
        if thenStudy, !added.isEmpty { practice = StudyRequest(title: shelf.lesson(lessonID)?.title ?? "這課的生字", words: added) }
    }
}

// MARK: - Importing

/// VisionKit's document camera: finds the page edges, straightens them and takes several pages in a row.
struct DocumentCamera: View {
    var onPages: ([UIImage]) -> Void
    var body: some View {
        if VNDocumentCameraViewController.isSupported { Scanner(onPages: onPages) } else { CameraPicker { onPages([$0]) } }
    }

    private struct Scanner: UIViewControllerRepresentable {
        var onPages: ([UIImage]) -> Void
        @Environment(\.dismiss) private var dismiss

        func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
            let vc = VNDocumentCameraViewController()
            vc.delegate = context.coordinator
            return vc
        }
        func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}
        func makeCoordinator() -> Coordinator { Coordinator(self) }

        final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
            let parent: Scanner
            init(_ p: Scanner) { parent = p }
            func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
                parent.onPages((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
                parent.dismiss()
            }
            func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }
            func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.dismiss() }
        }
    }
}

enum PDFPages {
    /// each page drawn about 2000 px on the long side (up to 30 pages)
    static func images(_ url: URL) -> [UIImage] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<min(doc.pageCount, 30)).compactMap { doc.page(at: $0) }.map { page in
            let r = page.bounds(for: .mediaBox)
            let k = 2000 / max(r.width, r.height, 1)
            return page.thumbnail(of: CGSize(width: r.width * k, height: r.height * k), for: .mediaBox)
        }
    }
}
