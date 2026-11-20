import Foundation
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Bold words

/// Finds bold words by stroke thickness: in each word's box, the average run of dark pixels along a row,
/// relative to the box height. Bold type has clearly thicker strokes than the page's usual words.
nonisolated enum BoldDetector {
    static func mark(_ lines: inout [PageReader.Line], ink: InkMap) {
        var strokes: [(l: Int, w: Int, v: Double)] = []
        for (l, line) in lines.enumerated() {
            for (w, word) in line.words.enumerated() {
                guard TBText.core(word.t).filter(\.isLetter).count >= 3, let b = word.box, b.count == 4,
                      let v = stroke(ink, CGRect(x: b[0], y: b[1], width: b[2], height: b[3])) else { continue }
                strokes.append((l, w, v))
            }
        }
        guard strokes.count >= 8 else { return }
        let sorted = strokes.map(\.v).sorted()
        let usual = sorted[sorted.count / 2]
        guard usual > 0 else { return }
        for s in strokes where s.v > usual * 1.3 { lines[s.l].words[s.w].bold = true }
    }

    /// average dark-run length in the word's box ÷ box height
    static func stroke(_ ink: InkMap, _ r: CGRect) -> Double? {
        let x0 = max(0, Int(r.minX * CGFloat(ink.w))), x1 = min(ink.w - 1, Int(r.maxX * CGFloat(ink.w)))
        let y0 = max(0, Int(r.minY * CGFloat(ink.h))), y1 = min(ink.h - 1, Int(r.maxY * CGFloat(ink.h)))
        guard x1 - x0 > 6, y1 - y0 > 6 else { return nil }
        var lo = 255, hi = 0
        for y in stride(from: y0, through: y1, by: 2) {
            for x in stride(from: x0, through: x1, by: 2) { let v = Int(ink.px[y * ink.w + x]); lo = min(lo, v); hi = max(hi, v) }
        }
        guard hi - lo > 60 else { return nil }
        let thr = UInt8((lo + hi) / 2)
        // the middle rows only, so letters of the lines above and below don't count
        let iy0 = y0 + (y1 - y0) / 4, iy1 = y1 - (y1 - y0) / 4
        var dark = 0, runs = 0
        for y in iy0...iy1 {
            var inRun = false
            for x in x0...x1 {
                if ink.px[y * ink.w + x] < thr { dark += 1; if !inRun { runs += 1; inRun = true } } else { inRun = false }
            }
        }
        guard runs >= 3 else { return nil }
        return Double(dark) / Double(runs) / Double(y1 - y0)
    }
}

// MARK: - Where the pictures are

/// A coarse map of the photo's pictures: cells that are colourful, or have a photo's in-between tones (print is
/// paper and ink, with few tones between). Flat pale boxes, shadows and the paper don't count.
nonisolated struct PictureMap {
    let cols: Int, rows: Int
    private let cells: [Bool]
    /// cells under recognised text, left out when judging what surrounds a block
    private var text: [Bool]

    init?(_ cg: CGImage, longSide: Int = 768, cell: Int = 8) {
        let scale = min(1, Double(longSide) / Double(max(cg.width, cg.height)))
        let W = max(cell, Int(Double(cg.width) * scale)), H = max(cell, Int(Double(cg.height) * scale))
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return nil }
        cols = W / cell; rows = H / cell
        var cells = [Bool](repeating: false, count: cols * rows)
        var lum = [Int](repeating: 0, count: cell * cell)
        for cy in 0..<rows {
            for cx in 0..<cols {
                var sat = 0.0, lo = 255, hi = 0, k = 0
                for y in 0..<cell {
                    let row = (cy * cell + y) * W + cx * cell
                    for x in 0..<cell {
                        let i = (row + x) * 4
                        let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
                        let mx = max(r, g, b), mn = min(r, g, b)
                        if mx > 60 { sat += Double(mx - mn) / Double(mx) }
                        let l = (r * 299 + g * 587 + b * 114) / 1000
                        lum[k] = l; k += 1
                        lo = min(lo, l); hi = max(hi, l)
                    }
                }
                var textured = false
                if hi - lo > 60 {
                    let a = lo + (hi - lo) / 4, b = hi - (hi - lo) / 4
                    textured = Double(lum.filter { $0 > a && $0 < b }.count) > Double(lum.count) * 0.45
                }
                cells[cy * cols + cx] = sat / Double(cell * cell) > 0.22 || textured
            }
        }
        self.cells = cells
        text = [Bool](repeating: false, count: cols * rows)
    }

    /// Marks the cells under these boxes (normalised, top-left origin) as text.
    mutating func cover(_ boxes: [CGRect]) {
        for b in boxes {
            let x0 = max(0, Int(b.minX * CGFloat(cols))), x1 = min(cols - 1, Int(b.maxX * CGFloat(cols)))
            let y0 = max(0, Int(b.minY * CGFloat(rows))), y1 = min(rows - 1, Int(b.maxY * CGFloat(rows)))
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 { for x in x0...x1 { text[y * cols + x] = true } }
        }
    }

    /// How much of the ring around `r` (from `inner` to `outer` away, normalised) is picture: overall and on each side
    /// (above, right, below, left). Cells under text don't count; nil where too little is left to judge.
    func around(_ r: CGRect, inner: CGFloat, outer: CGFloat) -> (all: Double?, sides: [Double?]) {
        let i = r.insetBy(dx: -inner, dy: -inner), o = r.insetBy(dx: -outer, dy: -outer)
        let x0 = max(0, Int(o.minX * CGFloat(cols))), x1 = min(cols - 1, Int(o.maxX * CGFloat(cols)))
        let y0 = max(0, Int(o.minY * CGFloat(rows))), y1 = min(rows - 1, Int(o.maxY * CGFloat(rows)))
        guard x0 <= x1, y0 <= y1 else { return (nil, [nil, nil, nil, nil]) }
        var hit = [0, 0, 0, 0], n = [0, 0, 0, 0], allHit = 0, allN = 0
        for cy in y0...y1 {
            for cx in x0...x1 where !text[cy * cols + cx] {
                let c = CGPoint(x: (CGFloat(cx) + 0.5) / CGFloat(cols), y: (CGFloat(cy) + 0.5) / CGFloat(rows))
                guard o.contains(c), !i.contains(c) else { continue }
                let p = cells[cy * cols + cx]
                allN += 1; if p { allHit += 1 }
                for (s, on) in [c.y < i.minY, c.x > i.maxX, c.y > i.maxY, c.x < i.minX].enumerated() where on {
                    n[s] += 1; if p { hit[s] += 1 }
                }
            }
        }
        return (allN >= 6 ? Double(allHit) / Double(allN) : nil, (0..<4).map { n[$0] >= 3 ? Double(hit[$0]) / Double(n[$0]) : nil })
    }
}

// MARK: - What isn't lesson text

/// Clears what a photo of a textbook page shows besides its text, before the lines are laid out:
/// - lines cut off at the photo's edge (the next page showing)
/// - text printed on a picture (labels on a map, speech bubbles, a quote on a photo)
/// - captions: smaller type next to a picture
/// - side notes: a column of smaller type beside the text ("Language Highlight", "Note the Details"), and the
///   textbook's own boxes ("Word Bank", "Scan and Watch")
/// - line numbers in the margin, footnote numbers and asterisks on words, bullets and symbols (®, ™, ▶, •)
/// - Chinese read by the English recogniser as junk letters
nonisolated enum PageCleaner {
    enum Mode {
        /// lesson text: everything above
        case lesson
        /// a word list or the word scanner: only cut-off lines and text on pictures, the rest is the list's own layout
        case list
    }

    /// Lines worth reading, each with its block. Lesson text comes back in reading order (block by block, pieces of one
    /// printed line joined), with Chinese and the marks around the words taken out; `chinese` is the same page read
    /// with the Chinese recogniser, to find where the Chinese is.
    static func clean(_ raw: [PageReader.Line], picture: PictureMap?, mode: Mode, chinese: [PageReader.Line] = []) -> [PageReader.Line] {
        var lines = raw.filter { !$0.words.isEmpty }
        if mode == .lesson { lines = dropChinese(lines, chinese) }
        guard !lines.isEmpty else { return [] }
        let r = regions(lines, picture: picture, mode: mode)
        var kept: [PageReader.Line] = []
        for (i, line) in lines.enumerated() where r.keep[i] {
            var l = line
            l.block = r.block[i]
            kept.append(l)
        }
        guard mode == .lesson, !kept.isEmpty else { return kept }
        let lineH = median(kept.map(\.box.height))
        kept = joinDropCaps(kept, lineH: lineH).compactMap { tidy($0, lineH: lineH) }
        return order(kept)
    }

    static func median(_ a: [CGFloat]) -> CGFloat {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[s.count / 2]
    }

    // MARK: blocks

    /// cut off by the edge of the photo
    static func cutOff(_ r: CGRect) -> Bool { r.minX < 0.006 || r.maxX > 0.994 || r.minY < 0.004 || r.maxY > 0.996 }

    /// Two lines of one block: about the same size, and pieces of one printed line or one under the other.
    static func together(_ a: CGRect, _ b: CGRect) -> Bool {
        let h = min(a.height, b.height)
        guard h > 0, max(a.height, b.height) / h < 1.35 else { return false }
        let vGap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
        let hGap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        if vGap < -h * 0.5 { return hGap < h * 0.8 }
        return vGap < h * 1.3 && -hGap > min(a.width, b.width) * 0.3
    }

    /// the boxes printed by the textbook around its text (first words of the block, lowercased)
    static let boxLabels = ["word bank", "language highlight", "note the details", "scan and watch", "scan to watch", "scan to listen"]

    /// Which lines to keep, and the block of each line.
    static func regions(_ lines: [PageReader.Line], picture: PictureMap?, mode: Mode) -> (keep: [Bool], block: [Int]) {
        let boxes = lines.map(\.box)
        let n = boxes.count
        var keep = boxes.map { !cutOff($0) }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for a in 0..<n where keep[a] {
            for b in (a + 1)..<max(a + 1, n) where keep[b] && together(boxes[a], boxes[b]) { parent[find(a)] = find(b) }
        }
        let block = (0..<n).map(find)
        let groups = Dictionary(grouping: (0..<n).filter { keep[$0] }, by: { block[$0] })
        // the page's text: the block with the most lines
        guard let body = groups.values.max(by: { $0.count == $1.count ? $0[0] > $1[0] : $0.count < $1.count }) else { return (keep, block) }
        func frame(_ g: [Int]) -> CGRect { g.dropFirst().reduce(boxes[g[0]]) { $0.union(boxes[$1]) } }
        let bodyH = median(body.map { boxes[$0].height })
        let bodyX = frame(body)
        var pic = picture
        pic?.cover(boxes)
        for g in groups.values {
            let h = median(g.map { boxes[$0].height })
            let f = frame(g)
            var drop = false
            if let pic {
                // on a picture: mostly picture all around, or on three sides
                let a = pic.around(f, inner: h * 0.6, outer: h * 2.5)
                if (a.all ?? 0) >= 0.5 || a.sides.filter({ ($0 ?? 0) >= 0.35 }).count >= 3 { drop = true }
                // a caption: a few lines of smaller type right by a picture
                if !drop, mode == .lesson, h < bodyH * 0.85, g.count <= 6 {
                    let c = pic.around(f, inner: h * 0.6, outer: h * 4)
                    if (c.all ?? 0) >= 0.25 || c.sides.contains(where: { ($0 ?? 0) >= 0.6 }) { drop = true }
                }
            }
            if !drop, mode == .lesson, g != body {
                // a side note: smaller type in a column of its own
                let overlap = min(f.maxX, bodyX.maxX) - max(f.minX, bodyX.minX)
                if h < bodyH * 0.88 && overlap < f.width * 0.3 { drop = true }
                let first = g.min { boxes[$0].minY < boxes[$1].minY }.map { lines[$0].words.map(\.t).joined(separator: " ").lowercased() } ?? ""
                if boxLabels.contains(where: { first.hasPrefix($0) }) { drop = true }
            }
            if drop { for i in g { keep[i] = false } }
        }
        return (keep, block)
    }

    /// Blocks top to bottom (side by side: left first), lines top to bottom in each, and pieces of one printed
    /// line joined into one line.
    static func order(_ lines: [PageReader.Line]) -> [PageReader.Line] {
        var frames: [Int: CGRect] = [:]
        for l in lines { frames[l.block] = frames[l.block]?.union(l.box) ?? l.box }
        let blocks = frames.keys.sorted { a, b in
            let x = frames[a]!, y = frames[b]!
            if min(x.maxY, y.maxY) - max(x.minY, y.minY) > min(x.height, y.height) * 0.5, x.minX != y.minX { return x.minX < y.minX }
            return x.minY != y.minY ? x.minY < y.minY : a < b
        }
        var out: [PageReader.Line] = []
        for b in blocks {
            let ls = lines.filter { $0.block == b }.sorted { $0.box.minY != $1.box.minY ? $0.box.minY < $1.box.minY : $0.box.minX < $1.box.minX }
            var rows: [[PageReader.Line]] = []
            for l in ls {
                if let i = rows.indices.last, let r = rows[i].first,
                   abs(r.box.midY - l.box.midY) < min(r.box.height, l.box.height) * 0.5 { rows[i].append(l) } else { rows.append([l]) }
            }
            for r in rows {
                let pieces = r.sorted { $0.box.minX < $1.box.minX }
                var line = pieces[0]
                for p in pieces.dropFirst() { line.words += p.words; line.box = line.box.union(p.box) }
                out.append(line)
            }
        }
        return out
    }

    // MARK: words

    /// English words read off Chinese text: where the Chinese recogniser found Chinese characters.
    static func dropChinese(_ lines: [PageReader.Line], _ chinese: [PageReader.Line]) -> [PageReader.Line] {
        let han = chinese.flatMap(\.words).filter { $0.t.range(of: #"\p{Han}"#, options: .regularExpression) != nil }.compactMap(\.rect)
        guard !han.isEmpty else { return lines }
        return lines.compactMap { line in
            var l = line
            l.words = line.words.filter { w in
                guard let r = w.rect else { return true }
                let c = CGPoint(x: r.midX, y: r.midY)
                return !han.contains { $0.contains(c) }
            }
            return l.words.isEmpty ? nil : l
        }
    }

    /// A drop cap (a big first letter beside the first lines) put back on its word: "H" + "ave you…" → "Have you…".
    static func joinDropCaps(_ lines: [PageReader.Line], lineH: CGFloat) -> [PageReader.Line] {
        var out = lines
        var used = Set<Int>()
        for (i, cap) in lines.enumerated() {
            guard cap.words.count == 1, cap.words[0].t.count == 1, let c = cap.words[0].t.first, c.isUppercase,
                  cap.box.height >= lineH * 1.8 else { continue }
            let beside = lines.indices.filter { j in
                j != i && !used.contains(j) && lines[j].box.height < cap.box.height * 0.7
                    && lines[j].box.minX > cap.box.maxX - lineH && lines[j].box.minX < cap.box.maxX + lineH * 2.5
                    && lines[j].box.midY > cap.box.minY && lines[j].box.midY < cap.box.maxY
            }
            guard let j = beside.min(by: { lines[$0].box.minY < lines[$1].box.minY }) else { continue }
            out[j].words = joined(cap.words[0], out[j].words)
            used.insert(i)
        }
        // the drop cap read as part of its line: "H ave you…"
        for i in out.indices where !used.contains(i) && out[i].words.count >= 2 {
            let w = out[i].words[0]
            guard w.t.count == 1, let c = w.t.first, c.isUppercase, c != "A", c != "I" else { continue }
            out[i].words = joined(w, Array(out[i].words.dropFirst()))
        }
        return out.indices.filter { !used.contains($0) }.map { out[$0] }
    }

    /// The letter joined to the first word when that makes it a word ("A" + "lthough"), else kept as a word of its own ("A" "long").
    private static func joined(_ cap: TBWord, _ words: [TBWord]) -> [TBWord] {
        guard var first = words.first, let f = first.t.first, f.isLowercase else { return [cap] + words }
        let alone = Dictionary_.lookup(first.core).map { $0.w.lowercased() == first.core.lowercased() } ?? false
        if (cap.t == "A" || cap.t == "I") && alone { return [cap] + words }
        first.t = cap.t + first.t
        return [first] + words.dropFirst()
    }

    /// symbols printed around the text, never part of a word
    static let markers = CharacterSet(charactersIn: "*＊†‡§¶®©™•●○◦◆◇■□▪▫★☆▲△▼▽▶▷►◀◁※#|¦⁰¹²³⁴⁵⁶⁷⁸⁹")

    /// "accompany²," → "accompany,", "deceased*" → "deceased", "accompany2" (a footnote number read as a digit) → "accompany"
    static func strip(_ t: String) -> String {
        var s = ""
        s.unicodeScalars.append(contentsOf: t.unicodeScalars.filter { !markers.contains($0) })
        return s.replacingOccurrences(of: #"^([("“‘']*[A-Za-z][A-Za-z'’-]*[a-z])\d{1,2}([.,;:!?)\]"”’']*)$"#, with: "$1$2",
                                      options: .regularExpression)
    }

    private static func isNumber(_ t: String) -> Bool { t.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil }

    /// The line without line numbers in the margin ("5  on end, …") and the marks on its words; nil if nothing is left.
    static func tidy(_ line: PageReader.Line, lineH: CGFloat) -> PageReader.Line? {
        var words = line.words
        func gap(_ a: TBWord, _ b: TBWord) -> CGFloat? {
            guard let x = a.rect, let y = b.rect else { return nil }
            return y.minX - x.maxX
        }
        if words.count >= 2, isNumber(words[0].t), let g = gap(words[0], words[1]), g > lineH * 0.8 { words.removeFirst() }
        if words.count >= 2, isNumber(words[words.count - 1].t), let g = gap(words[words.count - 2], words[words.count - 1]), g > lineH * 0.8 {
            words.removeLast()
        }
        var out: [TBWord] = []
        for var w in words {
            let printed = w.t
            w.t = strip(printed)
            if w.t.isEmpty { continue }
            if w.t != printed, w.core.isEmpty {
                // punctuation left after its marker went ("afterlife" "*." ) goes back on the word before
                if var last = out.popLast() { last.t += w.t; out.append(last) }
                continue
            }
            out.append(w)
        }
        guard !out.isEmpty else { return nil }
        var l = line
        l.words = out
        return l
    }
}

// MARK: - Word-list pages (單字表)

/// Reads a page of the textbook's word list: 生字, 一般生字, 片語 and 文法重點 under their headings.
nonisolated enum VocabPage {
    struct Row { var text: String; var box: CGRect }

    /// heading words → section; checked in this order ("一般生字" before "生字", "words for recognition" before "words")
    static let headings: [(kind: String, keys: [String])] = [
        ("phrase", ["phrase", "idiom", "片語", "慣用語"]),
        ("grammar", ["grammar", "sentence pattern", "pattern", "structure", "句型", "文法", "語法"]),
        ("general", ["recognition", "supplementary", "additional", "extra word", "一般", "補充", "延伸", "認識"]),
        ("word", ["vocabulary", "new word", "production", "word list", "key word", "生字", "單字", "字彙", "核心"]),
    ]

    static func heading(_ text: String) -> String? {
        let t = GlossaryParser.halfwidth(text).lowercased()
            .replacingOccurrences(of: #"^[\s\d.、:：()\[\]【】•●▪■◆★☆※*-]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 40 else { return nil }
        return headings.first { h in h.keys.contains { t.contains($0) } }?.kind
    }

    private static let pointStart = #"^\s*(\d{1,2}\s*[.、)）]|[①②③④⑤⑥⑦⑧⑨⑩]|[•●▪■◆]|(grammar|pattern|point)\s*\d)"#

    /// The page as a word list, or nil when it reads like lesson text.
    static func read(_ lines: [PageReader.Line]) -> TBContent? {
        let rows = rows(lines)
        guard !rows.isEmpty else { return nil }
        let han = rows.filter { $0.text.range(of: #"\p{Han}"#, options: .regularExpression) != nil }.count
        var section = "word"
        var sawHeading = false
        var entries: [TBEntry] = [], seen = Set<String>()
        var grammar: [TBGrammar] = []
        var bilingual = 0
        for row in rows {
            // "Vocabulary 生字" reads like an entry too, so a row counts as a heading when all it lists are headings
            if let h = heading(row.text), (GlossaryParser.entries(inRow: row.text) ?? []).allSatisfy({ heading($0.term) != nil }) {
                section = h; sawHeading = true; continue
            }
            if section == "grammar" {
                let text = GlossaryParser.halfwidth(row.text).trimmingCharacters(in: .whitespaces)
                guard text.count >= 2 else { continue }
                if grammar.isEmpty || text.range(of: pointStart, options: [.regularExpression, .caseInsensitive]) != nil {
                    let title = text.replacingOccurrences(of: pointStart, with: "", options: [.regularExpression, .caseInsensitive])
                        .trimmingCharacters(in: .whitespaces)
                    grammar.append(TBGrammar(title: String(title.prefix(80)), note: nil))
                } else {
                    let i = grammar.count - 1
                    let note = [grammar[i].note, text].compactMap { $0 }.joined(separator: "\n")
                    grammar[i].note = String(note.prefix(300))
                }
                continue
            }
            guard let found = GlossaryParser.entries(inRow: row.text) else { continue }
            bilingual += 1
            for e in found {
                let term = GlossaryParser.cleanTerm(e.term)
                let kind = section == "word" && term.contains(" ") ? "phrase" : section
                guard seen.insert(term).inserted else { continue }
                entries.append(TBEntry(t: term, pos: e.pos.isEmpty ? nil : e.pos, zh: e.meanings, kind: kind))
            }
        }
        let list = entries.count >= 3 && entries.count * 2 >= bilingual
        let sectioned = sawHeading && entries.count + grammar.count >= 2 && Double(han) >= Double(rows.count) * 0.3
        guard list || sectioned else { return nil }
        return TBContent(kind: "vocab", paragraphs: [], entries: entries, grammar: grammar.isEmpty ? nil : grammar)
    }

    /// Lines on the same printed row joined left to right, top to bottom; a two-column page is read
    /// column by column.
    static func rows(_ lines: [PageReader.Line]) -> [Row] {
        let ls = lines.filter { !$0.words.isEmpty }
        let right = ls.filter { $0.box.minX > 0.45 }.count
        let spanning = ls.filter { $0.box.minX < 0.4 && $0.box.maxX > 0.6 }.count
        let columns: [[PageReader.Line]] = right * 10 >= ls.count * 3 && spanning * 10 <= ls.count
            ? [ls.filter { $0.box.midX < 0.5 }, ls.filter { $0.box.midX >= 0.5 }] : [ls]
        var out: [Row] = []
        for col in columns {
            var rows: [[PageReader.Line]] = []
            for line in col.sorted(by: { $0.box.midY < $1.box.midY }) {
                if let i = rows.indices.last, abs(rows[i][0].box.midY - line.box.midY) < min(rows[i][0].box.height, line.box.height) * 0.5 {
                    rows[i].append(line)
                } else {
                    rows.append([line])
                }
            }
            for r in rows {
                let sorted = r.sorted { $0.box.minX < $1.box.minX }
                let box = sorted.map(\.box).reduce(sorted[0].box) { $0.union($1) }
                out.append(Row(text: sorted.map { $0.words.map(\.t).joined(separator: " ") }.joined(separator: "  "), box: box))
            }
        }
        return out
    }
}

// MARK: - Matching the word list in the lesson text

/// The lesson's word list (from its 單字表 pages) and where those words and phrases are in its text.
nonisolated struct LessonIndex {
    private(set) var entries: [TBEntry] = []
    private(set) var grammar: [TBGrammar] = []
    private var single: [String: TBEntry] = [:]
    private var phrases: [(tokens: [String], kind: String)] = []

    init(pages: [TBPage]) {
        var seenG = Set<String>()
        for p in pages where p.content.isVocab {
            for e in p.content.entries ?? [] {
                entries.append(e)
                let toks = e.t.lowercased().split(separator: " ").map(String.init)
                if toks.count == 1 { if single[toks[0]] == nil { single[toks[0]] = e } }
                else { phrases.append((toks, e.kind)) }
            }
            for g in p.content.grammar ?? [] where seenG.insert(g.title).inserted { grammar.append(g) }
        }
    }

    var isEmpty: Bool { entries.isEmpty && grammar.isEmpty }

    /// the word list's row for a word in the text ("benches" → bench)
    func entry(for word: String) -> TBEntry? { Self.forms(word).lazy.compactMap { single[$0] }.first }

    /// Spellings a word in running text may be the dictionary form of ("benches" → bench, "stopped" → stop).
    static func forms(_ word: String) -> [String] {
        var w = word.lowercased()
        for s in ["'s", "’s"] where w.hasSuffix(s) { w = String(w.dropLast(2)) }
        var out = [w]
        func add(_ s: String) { if s.count >= 2 && !out.contains(s) { out.append(s) } }
        func doubled(_ s: String) -> String? {
            guard s.count >= 3, let last = s.last, s.dropLast().last == last, !"aeiou".contains(last) else { return nil }
            return String(s.dropLast())
        }
        if w.hasSuffix("ies") { add(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("es") { add(String(w.dropLast(2))) }
        if w.hasSuffix("s") && !w.hasSuffix("ss") { add(String(w.dropLast())) }
        if w.hasSuffix("ied") { add(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("ed") {
            let stem = String(w.dropLast(2))
            add(stem); add(String(w.dropLast())); if let d = doubled(stem) { add(d) }
        }
        if w.hasSuffix("ing") {
            let stem = String(w.dropLast(3))
            add(stem); add(stem + "e"); if let d = doubled(stem) { add(d) }
        }
        if let e = Dictionary_.lookup(w) { add(e.w.lowercased()) }
        return out
    }

    private static let placeholders: Set<String> = ["sb", "sth", "sb.", "sth.", "someone", "somebody", "something", "one's",
                                                     "sb's", "oneself", "one", "a.", "n.", "v.", "…", "...", "~"]
    private static let possessives: Set<String> = ["my", "your", "his", "her", "its", "our", "their"]
    private static let be: Set<String> = ["be", "is", "am", "are", "was", "were", "been", "being", "'s", "’s"]

    private static func token(_ tok: String, matches word: String) -> Bool {
        let w = word.lowercased()
        if tok == "be" { return be.contains(w) }
        if tok == "oneself" { return w.hasSuffix("self") || w.hasSuffix("selves") }
        return forms(w).contains(tok)
    }

    /// Word positions matched by the phrase starting at `start`, or nil.
    private static func match(_ toks: [String], _ words: [String], _ ti: Int, _ wi: Int) -> [Int]? {
        if ti == toks.count { return [] }
        guard wi < words.count else { return nil }
        let tok = toks[ti]
        if placeholders.contains(tok) {
            if tok == "one's" || tok == "sb's", possessives.contains(words[wi].lowercased()) {
                if let rest = match(toks, words, ti + 1, wi + 1) { return rest }
            }
            if tok == "oneself", token(tok, matches: words[wi]) {
                if let rest = match(toks, words, ti + 1, wi + 1) { return [wi] + rest }
            }
            for skip in 1...3 where wi + skip <= words.count {
                if let rest = match(toks, words, ti + 1, wi + skip) { return rest }
            }
            return nil
        }
        guard token(tok, matches: words[wi]) else { return nil }
        return match(toks, words, ti + 1, wi + 1).map { [wi] + $0 }
    }

    /// For each word on the page: its kind in the word list (word, general or phrase) and whether it's part of
    /// a listed phrase.
    func marks(_ page: TBPage) -> (kinds: [TBPos: String], phrase: Set<TBPos>) {
        var kinds: [TBPos: String] = [:], phrase = Set<TBPos>()
        guard !entries.isEmpty, !page.content.isVocab else { return (kinds, phrase) }
        for (p, para) in page.content.paragraphs.enumerated() {
            for (s, sen) in para.sentences.enumerated() {
                let words = sen.words.indices.map { page.shown(TBPos(p: p, s: s, w: $0)) }
                for (w, word) in words.enumerated() where word.count >= 2 {
                    if let e = entry(for: word) { kinds[TBPos(p: p, s: s, w: w)] = e.kind }
                }
                for ph in phrases {
                    for start in words.indices where Self.token(ph.tokens[0], matches: words[start]) || Self.placeholders.contains(ph.tokens[0]) {
                        guard let hit = Self.match(ph.tokens, words, 0, start), !hit.isEmpty else { continue }
                        for w in hit { phrase.insert(TBPos(p: p, s: s, w: w)) }
                        break
                    }
                }
            }
        }
        return (kinds, phrase)
    }

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "general": "一般生字"
        case "phrase": "片語"
        case "grammar": "文法重點"
        default: "生字"
        }
    }
}

// MARK: - Grammar points in the lesson text

#if canImport(FoundationModels)
@Generable
struct GrammarHit {
    @Guide(description: "The sentence number")
    var sentence: Int
    @Guide(description: "The grammar point number it uses")
    var point: Int
    @Guide(description: "The exact words in the sentence that show the grammar point")
    var quote: String
}

@Generable
struct GrammarHits {
    @Guide(description: "Only the sentences that clearly use one of the grammar points")
    var hits: [GrammarHit]
}
#endif

enum GrammarMarker {
    /// Sentences on a lesson page that use the lesson's grammar points: Apple Intelligence when `ai`,
    /// otherwise (or if it fails) the English words of each point's pattern found in order.
    static func marks(_ page: TBPage, _ grammar: [TBGrammar], ai: Bool) async -> (marks: [TBMark], by: String) {
        if ai, let m = await aiMarks(page, grammar) { return (m, "ai") }
        return (ruleMarks(page, grammar), "rule")
    }

    private static func sentences(_ page: TBPage) -> [(p: Int, s: Int, text: String)] {
        var out: [(Int, Int, String)] = []
        for (p, para) in page.content.paragraphs.enumerated() where para.style == nil {
            for s in para.sentences.indices { out.append((p, s, page.sentence(p: p, s: s))) }
        }
        return out
    }

    // MARK: rule

    private static let slots: Set<String> = ["s", "v", "o", "n", "c", "adj", "adv", "ving", "v-ing", "ved", "pp", "p.p", "to-v",
                                             "sb", "sth", "n.", "v.", "adj.", "adv.", "a", "an"]

    /// "not only … but also …" → [["not", "only"], ["but", "also"]]; descriptive or Chinese-only titles give none.
    static func fragments(_ title: String) -> [[String]] {
        let english = GlossaryParser.halfwidth(title).replacingOccurrences(of: #"[\p{Han}，。：；（）「」]+.*$"#, with: "",
                                                                             options: .regularExpression)
        let parts = english.components(separatedBy: CharacterSet(charactersIn: "…~+/()[],=").union(.init(charactersIn: "．")))
            .flatMap { $0.components(separatedBy: "...") }
        let frags = parts.map { part in
            part.lowercased().split(separator: " ").map { String($0).trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty && !slots.contains($0) && $0.allSatisfy { $0.isLetter || $0 == "'" } }
        }.filter { !$0.isEmpty }
        let words = frags.flatMap { $0 }
        // a lone word ("that") would match everywhere; every word should be a real one
        guard words.count >= 2, words.allSatisfy({ Dictionary_.lookup($0) != nil }) else { return [] }
        return frags
    }

    static func ruleMarks(_ page: TBPage, _ grammar: [TBGrammar]) -> [TBMark] {
        var out: [TBMark] = []
        for g in grammar {
            let frags = fragments(g.title)
            guard !frags.isEmpty else { continue }
            for s in sentences(page) {
                let words = s.text.lowercased().split(separator: " ").map { TBText.core(String($0)) }
                var at = 0, ok = true
                for f in frags {
                    guard let i = (at..<max(at, words.count - f.count + 1)).first(where: { i in
                        f.indices.allSatisfy { LessonIndex.forms(words[i + $0]).contains(f[$0]) }
                    }) else { ok = false; break }
                    at = i + f.count
                }
                if ok { out.append(TBMark(p: s.p, s: s.s, g: g.title, why: frags.map { $0.joined(separator: " ") }.joined(separator: " … "))) }
            }
        }
        return out
    }

    // MARK: Apple Intelligence

    private static func aiMarks(_ page: TBPage, _ grammar: [TBGrammar]) async -> [TBMark]? {
        #if canImport(FoundationModels)
        guard OCRFixer.aiAvailable else { return nil }
        let all = sentences(page)
        guard !all.isEmpty else { return [] }
        let points = grammar.enumerated().map { i, g in
            "\(i + 1). \(g.title)" + (g.note.map { "（\($0.replacingOccurrences(of: "\n", with: " ").prefix(120))）" } ?? "")
        }.joined(separator: "\n")
        var out: [TBMark] = []
        for start in stride(from: 0, to: all.count, by: 25) {
            let chunk = Array(all[start..<min(start + 25, all.count)])
            let session = LanguageModelSession(instructions: """
                你是高中英文老師。下面是這課的文法重點和課文句子。找出明確用到某個文法重點的句子，\
                quote 要逐字抄句子裡展現這個文法的字。沒有用到就不要列，不確定就不要列。
                """)
            let list = chunk.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
            guard let r = try? await session.respond(to: "文法重點：\n\(points)\n\n句子：\n\(list)", generating: GrammarHits.self).content
            else { return out.isEmpty ? nil : out }
            for h in r.hits {
                guard chunk.indices.contains(h.sentence - 1), grammar.indices.contains(h.point - 1) else { continue }
                let s = chunk[h.sentence - 1]
                let quote = h.quote.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                // the quote has to really be in the sentence, or the model made it up
                guard quote.count >= 2, s.text.range(of: quote, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
                let g = grammar[h.point - 1].title
                guard !out.contains(where: { $0.p == s.p && $0.s == s.s && $0.g == g }) else { continue }
                out.append(TBMark(p: s.p, s: s.s, g: g, why: quote))
            }
        }
        return out
        #else
        return nil
        #endif
    }
}

// MARK: - The shelf's side of it

/// One word for 這課的生字: from the lesson's word list (kind word, general or phrase) or, without one,
/// a 大考 or 多益 word found in the text (kind dict).
struct LessonWord: Identifiable, Hashable {
    let entry: DictEntry
    let kind: String
    /// the meanings printed in the word list
    let meanings: [String]?
    var id: String { kind + ":" + entry.w }
}

extension Shelf {
    /// The lesson's word list and grammar points, rebuilt only when one of its pages changed.
    func index(_ lesson: UUID) -> LessonIndex {
        let ps = pages(in: lesson)
        let key = ps.map { "\($0.id)\($0.updatedAt.timeIntervalSince1970)" }.joined()
        if let c = indexCache[lesson], c.key == key { return c.index }
        let idx = LessonIndex(pages: ps)
        indexCache[lesson] = (key, idx)
        return idx
    }

    /// Looks for the lesson's grammar points in each text page that hasn't been checked against them yet
    /// (or was only checked by the rule and Apple Intelligence can now do better).
    func markGrammar(_ lesson: UUID) async {
        guard !marking.contains(lesson) else { return }
        marking.insert(lesson)
        defer { marking.remove(lesson) }
        let grammar = index(lesson).grammar
        let titles = grammar.map(\.title)
        let ai = aiFixes
        for p in pages(in: lesson) where !p.content.isVocab {
            if p.content.checked ?? [] == titles && (p.content.checkedBy == "ai" || !ai) { continue }
            if titles.isEmpty { setMarks(page: p.id, [], checked: [], by: "rule"); continue }
            let r = await GrammarMarker.marks(p, grammar, ai: ai)
            setMarks(page: p.id, r.marks, checked: titles, by: r.by)
            DevLog.add("textbook", "grammar: \(r.marks.count) sentences on a page (\(r.by))")
        }
    }

    /// 這課的生字: the word list's words when the lesson has one, otherwise 大考 (level 2 and up: level 1 is known
    /// by everyone in 高中) and 多益 words in the text in the order they first appear. Names (capitalised in
    /// mid-sentence somewhere in the lesson, like "Lily") are left out.
    func lessonWords(_ lesson: UUID) -> [LessonWord] {
        let idx = index(lesson)
        if !idx.entries.isEmpty {
            var seen = Set<String>()
            return idx.entries.compactMap { e in
                let entry = Dictionary_.lookup(e.t).flatMap { $0.w.lowercased() == e.t.lowercased() ? $0 : nil }
                    ?? DictEntry.custom(e.t, meaning: e.zh?.first ?? "")
                guard seen.insert(entry.w).inserted else { return nil }
                return LessonWord(entry: entry, kind: e.kind, meanings: e.zh)
            }
        }
        let ps = pages(in: lesson).filter { !$0.content.isVocab }
        var names = Set<String>()
        for p in ps {
            for (pos, _) in p.content.allWords where pos.w > 0 {
                let core = p.shown(pos)
                if core.first?.isUppercase == true { names.insert(core.lowercased()) }
            }
        }
        var seen = Set<String>(), out: [LessonWord] = []
        for p in ps {
            for (pos, _) in p.content.allWords {
                let core = p.shown(pos)
                guard core.count >= 2, !names.contains(core.lowercased()), let e = Dictionary_.lookup(core), !e.zh.isEmpty,
                      (Int(e.lv) ?? 0) >= 2 || e.tags?.contains("toeic") == true, seen.insert(e.w).inserted else { continue }
                out.append(LessonWord(entry: e, kind: "dict", meanings: nil))
            }
        }
        return out
    }
}
