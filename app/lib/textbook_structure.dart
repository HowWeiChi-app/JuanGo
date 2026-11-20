// 課文書架的結構：粗體字、單字表頁、課文裡的生字和片語、文法重點的句子、這課的生字。
// 規則照 iOS 版 TextbookStructure.swift 和 Glossary.swift（GlossaryParser），兩邊讀出來的 JSON 一樣。
// Android 沒有裝置端的語言模型，文法句子只用句型比對（checked_by 是 "rule"）。

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'dev_log.dart';
import 'dictionary.dart';
import 'models.dart';
import 'textbook.dart';

final _letter = RegExp(r'\p{L}', unicode: true);
final _han = RegExp(r'\p{Script=Han}', unicode: true);
final _latin = RegExp('[A-Za-z]');

bool _isUpper(String s) => s.isNotEmpty && s[0] != s[0].toLowerCase();

// MARK: 粗體字

/// 照片的灰階版，量筆畫粗細用
class InkMap {
  InkMap(this.w, this.h, this.px);
  final int w, h;
  final Uint8List px;

  factory InkMap.from(img.Image image) {
    final px = Uint8List(image.width * image.height);
    var i = 0;
    for (final p in image) {
      final top = p.maxChannelValue == 0 ? 255 : p.maxChannelValue;
      px[i++] = ((0.299 * p.r + 0.587 * p.g + 0.114 * p.b) * 255 / top).round().clamp(0, 255).toInt();
    }
    return InkMap(image.width, image.height, px);
  }
}

/// 用筆畫粗細找粗體字：每個字的框裡，一列上連續深色像素的平均長度除以框高。
/// 粗體字的筆畫明顯比這頁一般的字粗
class BoldDetector {
  /// 在背景執行緒跑：照片（辨識用的同一張）和每個字的框 → 每個字的筆畫粗細，量不出來是 null
  static List<double?> strokes((List<int>, List<List<double>?>) args) {
    final (bytes, boxes) = args;
    final image = img.decodeImage(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    if (image == null) return [for (final _ in boxes) null];
    final ink = InkMap.from(image);
    return [for (final b in boxes) b == null || b.length != 4 ? null : stroke(ink, ui.Rect.fromLTWH(b[0], b[1], b[2], b[3]))];
  }

  /// strokes 的順序和 lines 裡的字一樣
  static void mark(List<OcrLine> lines, List<double?> strokes) {
    final found = <(TBWord, double)>[];
    var i = 0;
    for (final line in lines) {
      for (final word in line.words) {
        final v = i < strokes.length ? strokes[i] : null;
        i++;
        if (v == null || _letter.allMatches(TBText.core(word.t)).length < 3) continue;
        found.add((word, v));
      }
    }
    if (found.length < 8) return;
    final sorted = found.map((f) => f.$2).toList()..sort();
    final usual = sorted[sorted.length ~/ 2];
    if (usual <= 0) return;
    for (final (word, v) in found) {
      if (v > usual * 1.3) word.bold = true;
    }
  }

  /// 框裡深色像素連續的平均長度 ÷ 框高
  static double? stroke(InkMap ink, ui.Rect r) {
    final x0 = max(0, (r.left * ink.w).toInt()), x1 = min(ink.w - 1, (r.right * ink.w).toInt());
    final y0 = max(0, (r.top * ink.h).toInt()), y1 = min(ink.h - 1, (r.bottom * ink.h).toInt());
    if (x1 - x0 <= 6 || y1 - y0 <= 6) return null;
    var lo = 255, hi = 0;
    for (var y = y0; y <= y1; y += 2) {
      for (var x = x0; x <= x1; x += 2) {
        final v = ink.px[y * ink.w + x];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (hi - lo <= 60) return null;
    final thr = (lo + hi) ~/ 2;
    // 只看中間幾列，上下行的字母才不會算進來
    final iy0 = y0 + (y1 - y0) ~/ 4, iy1 = y1 - (y1 - y0) ~/ 4;
    var dark = 0, runs = 0;
    for (var y = iy0; y <= iy1; y++) {
      var inRun = false;
      for (var x = x0; x <= x1; x++) {
        if (ink.px[y * ink.w + x] < thr) {
          dark += 1;
          if (!inRun) {
            runs += 1;
            inRun = true;
          }
        } else {
          inRun = false;
        }
      }
    }
    if (runs < 3) return null;
    return dark / runs / (y1 - y0);
  }
}

// MARK: 單字表的一列（GlossaryParser）

/// 單字表上的一列，例如 "3. pressure n. 壓力；壓迫"
class GlossaryEntry {
  GlossaryEntry(this.term, this.pos, this.meanings);

  /// 小寫；可能是片語（"give up"）
  final String term;

  /// 和字典一樣的寫法（"v."、"n./v."）；頁面沒寫就是空字串
  final String pos;

  /// 頁面上印的中文意思
  final List<String> meanings;
}

class GlossaryParser {
  /// 課本用的詞性縮寫，對到字典的寫法
  static const posMap = {
    'n': 'n.', 'v': 'v.', 'vt': 'v.', 'vi': 'v.', 'adj': 'adj.', 'a': 'adj.', 'adv': 'adv.', 'ad': 'adv.',
    'prep': 'prep.', 'conj': 'conj.', 'pron': 'pron.', 'aux': 'aux.', 'phr': 'phr.', 'ph': 'phr.',
    'int': 'int.', 'interj': 'int.', 'art': 'art.', 'num': 'num.',
  };

  static final _regex = () {
    const pos = '(?:n|v|vt|vi|adj|adv|a|ad|prep|conj|pron|aux|phr|ph|int|interj|art|num)';
    return RegExp(
      r"(?<term>[A-Za-z][A-Za-z'’\-]*(?:\s[A-Za-z][A-Za-z'’\-]*){0,3})\b"
      r'\s*(?:\[[^\]]{1,40}\]|/[^/]{1,40}/)?' // KK／IPA 音標
      r'\s*(?<pos>(?:\(?'
      '$pos'
      r'\.?\)?\s*(?:[/&,、]\s*)?)*)'
      r'\s*(?<zh>[\p{Script=Han}（(〈][^A-Za-z]*)',
      unicode: true,
    );
  }();

  /// 一列裡的「英文（詞性）中文」；不是中英對照的列回傳 null
  static List<GlossaryEntry>? entries(String raw) {
    // 中文辨識會把括號和字母印成全形（［ ］（adj.））
    final row = halfwidth(raw);
    if (!_han.hasMatch(row) || !RegExp('[A-Za-z]{2}').hasMatch(row)) return null;
    final found = <GlossaryEntry>[];
    for (final m in _regex.allMatches(row)) {
      var term = (m.namedGroup('term') ?? '').trim();
      var posText = m.namedGroup('pos') ?? '';
      // "capable adj 有能力的"：沒加點的縮寫會被算進英文
      final words = term.split(' ').where((s) => s.isNotEmpty).toList();
      if (words.length > 1 && posMap[words.last.toLowerCase()] != null) {
        final last = words.removeLast();
        term = words.join(' ');
        posText = '$last $posText';
      }
      final tags = _unique([
        for (final t in posText.toLowerCase().split(RegExp(r'[^\p{L}]+', unicode: true)))
          if (posMap[t] != null) posMap[t]!,
      ]);
      // 頁面有寫詞性，或英文就是這列的開頭才算（"abandon 放棄" 這種不寫詞性的表）
      final startsRow = !_latin.hasMatch(row.substring(0, m.start));
      if (term.length < 2 || words.length > 4 || (tags.isEmpty && !startsRow)) continue;
      final meanings = meaningList(m.namedGroup('zh') ?? '');
      if (meanings.isEmpty) continue;
      found.add(GlossaryEntry(term.toLowerCase(), tags.join('/'), meanings));
    }
    return found;
  }

  /// 全形轉半形，跟 iOS 的 fullwidthToHalfwidth 一樣（「、」也會變成「､」，tidy 會改回來）
  static String halfwidth(String s) {
    const extra = {0x3000: 0x20, 0x3001: 0xFF64, 0x3002: 0xFF61, 0x300C: 0xFF62, 0x300D: 0xFF63, 0x30FB: 0xFF65,
      0xFFE0: 0xA2, 0xFFE1: 0xA3, 0xFFE2: 0xAC, 0xFFE3: 0xAF, 0xFFE4: 0xA6, 0xFFE5: 0xA5, 0xFFE6: 0x20A9};
    return String.fromCharCodes(s.runes.map((r) => r >= 0xFF01 && r <= 0xFF5E ? r - 0xFEE0 : extra[r] ?? r));
  }

  /// "放棄；拋棄 2." → ["放棄", "拋棄"]；"藝術形式 *5" → ["藝術形式"]
  static List<String> meaningList(String raw) => _unique([
        for (final part in raw.split(RegExp('[；;，,／/：:、]')))
          _trim(tidy(stripMarks(part).replaceAll(RegExp(r'[\s\d.)、､(（]+$'), '')), ' \t。.、'),
      ].where(_han.hasMatch).toList());

  /// 課本用「*5」「★」「※」標等級或重要性，不是意思的一部分。記號後面還有字的話是 OCR 讀進來的圖例
  /// （「種類 ★表示近五年大考出現字彙」），從記號開始全部拿掉；記號已經不見的圖例從「表示」切掉
  static String stripMarks(String s) {
    const marks = '[*＊★☆※]';
    var t = s.replaceFirst(RegExp(r'^\s*' '$marks' r'+\s*\d*\s*'), '');
    final at = t.indexOf(RegExp(marks));
    if (at >= 0) t = t.substring(0, at);
    t = t.replaceAll(RegExp(r'表示.*(大考|出現|字彙|字汇|字货|考試).*$'), '');
    return t.trim();
  }

  /// 把讀頁面時弄壞的意思修好：轉半形變成的「､」、和列尾編號一起被切掉的右括號（「入境檢查(處」）、等級記號
  static String tidy(String m) {
    var t = stripMarks(m).replaceAll('､', '、').replaceAll(RegExp(r'\s{2,}'), ' ');
    final open = '('.allMatches(t).length + '（'.allMatches(t).length;
    final close = ')'.allMatches(t).length + '）'.allMatches(t).length;
    if (open > close) t += ')' * (open - close);
    return t;
  }

  /// OCR 會把字後面的 KK 音標讀成字母（"[ˈækjərəsɪ]" → "takjoresi"）黏在字上：
  /// "accuracy takjoresi"、"combattkam"。留下字典認得的部分
  static String cleanTerm(String term) {
    if (Dict.lookup(term) != null) return term;
    final words = term.split(' ').where((s) => s.isNotEmpty).toList();
    if (words.length > 1) {
      // 片語裡常見、字典不一定單獨收的字
      const glue = {'sth', 'sb', "one's", 'oneself', 'someone', 'something', 'a', 'an', 'the', 'to', 'of',
        'in', 'on', 'at', 'for', 'with', 'up', 'out', 'off', 'down', 'from', 'by', 'into',
        'about', 'over', 'away', 'back', 'be', 'do', 'get', 'make', 'take'};
      while (words.length > 1 && !glue.contains(words.last) && _looksLikePhonetics(words.last) && Dict.lookup(words.last) == null) {
        words.removeLast();
      }
      final kept = words.join(' ');
      return Dict.lookup(kept) != null ? kept : term; // 使用者自己的字就照原樣
    }
    // "combattkam"：認得的字後面接著音標，"[" 被讀成 t（或 "/" 被讀成 l）
    for (var n = term.length - 3; n >= 3; n--) {
      final head = term.substring(0, n), tail = term.substring(n);
      if (tail.length < 4 || !_looksLikePhonetics(tail)) continue;
      final e = Dict.lookup(head);
      if (e != null && e.w.toLowerCase() == head) return head;
    }
    return term;
  }

  /// "[ˈdɛfənɪtlɪ]" 從 OCR 出來是 "tdefonutlil"：括號變成 t／l
  static bool _looksLikePhonetics(String w) =>
      w.length >= 3 && (w.startsWith('t') || w.endsWith('l')) && RegExp(r"^[\p{L}']+$", unicode: true).hasMatch(w);

  static List<String> _unique(List<String> a) {
    final s = <String>{};
    return a.where(s.add).toList();
  }

  static String _trim(String s, String chars) {
    var a = 0, b = s.length;
    while (a < b && chars.contains(s[a])) {
      a++;
    }
    while (b > a && chars.contains(s[b - 1])) {
      b--;
    }
    return s.substring(a, b);
  }
}

// MARK: 單字表頁

/// 讀課本的單字表頁：標題下面的生字、一般生字、片語和文法重點
class VocabPage {
  /// 標題的字 → 種類；照這個順序比對（「一般生字」在「生字」前、"words for recognition" 在 "words" 前）
  static const headings = [
    ('phrase', ['phrase', 'idiom', '片語', '慣用語']),
    ('grammar', ['grammar', 'sentence pattern', 'pattern', 'structure', '句型', '文法', '語法']),
    ('general', ['recognition', 'supplementary', 'additional', 'extra word', '一般', '補充', '延伸', '認識']),
    ('word', ['vocabulary', 'new word', 'production', 'word list', 'key word', '生字', '單字', '字彙', '核心']),
  ];

  static String? heading(String text) {
    final t = GlossaryParser.halfwidth(text).toLowerCase().replaceFirst(RegExp(r'^[\s\d.、:：()\[\]【】•●▪■◆★☆※*-]+'), '').trim();
    if (t.isEmpty || t.length > 40) return null;
    for (final (kind, keys) in headings) {
      if (keys.any(t.contains)) return kind;
    }
    return null;
  }

  static final _pointStart = RegExp(r'^\s*(\d{1,2}\s*[.、)）]|[①②③④⑤⑥⑦⑧⑨⑩]|[•●▪■◆]|(grammar|pattern|point)\s*\d)', caseSensitive: false);

  /// 這頁是單字表就回傳整理好的內容；看起來像課文就回傳 null
  static TBContent? read(List<OcrLine> lines) {
    final rs = rows(lines);
    if (rs.isEmpty) return null;
    final han = rs.where((r) => _han.hasMatch(r.text)).length;
    var section = 'word';
    var sawHeading = false;
    final entries = <TBEntry>[], seen = <String>{};
    final grammar = <TBGrammar>[];
    var bilingual = 0;
    for (final row in rs) {
      // "Vocabulary 生字" 也像一個單字，所以這列列出的全都是標題時才算標題
      final h = heading(row.text);
      if (h != null && (GlossaryParser.entries(row.text) ?? const []).every((e) => heading(e.term) != null)) {
        section = h;
        sawHeading = true;
        continue;
      }
      if (section == 'grammar') {
        final text = GlossaryParser.halfwidth(row.text).trim();
        if (text.length < 2) continue;
        if (grammar.isEmpty || _pointStart.hasMatch(text)) {
          final title = text.replaceFirst(_pointStart, '').trim();
          grammar.add(TBGrammar(title.length > 80 ? title.substring(0, 80) : title));
        } else {
          final g = grammar.last;
          final note = [?g.note, text].join('\n');
          g.note = note.length > 300 ? note.substring(0, 300) : note;
        }
        continue;
      }
      final found = GlossaryParser.entries(row.text);
      if (found == null) continue;
      bilingual += 1;
      for (final e in found) {
        final term = GlossaryParser.cleanTerm(e.term);
        final kind = section == 'word' && term.contains(' ') ? 'phrase' : section;
        if (!seen.add(term)) continue;
        entries.add(TBEntry(term, pos: e.pos.isEmpty ? null : e.pos, zh: e.meanings, kind: kind));
      }
    }
    final list = entries.length >= 3 && entries.length * 2 >= bilingual;
    final sectioned = sawHeading && entries.length + grammar.length >= 2 && han >= rs.length * 0.3;
    if (!list && !sectioned) return null;
    return TBContent([], kind: 'vocab', entries: entries, grammar: grammar.isEmpty ? null : grammar);
  }

  /// 同一列印出來的字由左到右接起來，由上到下；兩欄的頁面一欄一欄讀
  static List<({String text, ui.Rect box})> rows(List<OcrLine> lines) {
    final ls = lines.where((l) => l.words.isNotEmpty).toList();
    final right = ls.where((l) => l.box.left > 0.45).length;
    final spanning = ls.where((l) => l.box.left < 0.4 && l.box.right > 0.6).length;
    final columns = right * 10 >= ls.length * 3 && spanning * 10 <= ls.length
        ? [ls.where((l) => l.box.center.dx < 0.5).toList(), ls.where((l) => l.box.center.dx >= 0.5).toList()]
        : [ls];
    final out = <({String text, ui.Rect box})>[];
    for (final col in columns) {
      final rows = <List<OcrLine>>[];
      for (final line in List.of(col)..sort((a, b) => a.box.center.dy.compareTo(b.box.center.dy))) {
        if (rows.isNotEmpty &&
            (rows.last[0].box.center.dy - line.box.center.dy).abs() < min(rows.last[0].box.height, line.box.height) * 0.5) {
          rows.last.add(line);
        } else {
          rows.add([line]);
        }
      }
      for (final r in rows) {
        final sorted = List.of(r)..sort((a, b) => a.box.left.compareTo(b.box.left));
        final box = sorted.map((l) => l.box).reduce((a, b) => a.expandToInclude(b));
        out.add((text: sorted.map((l) => l.words.map((w) => w.t).join(' ')).join('  '), box: box));
      }
    }
    return out;
  }
}

// MARK: 在課文裡找單字表的字

/// 這課的單字表（單字表頁）和那些字、片語在課文的哪裡
class LessonIndex {
  LessonIndex(List<TBPage> pages) {
    final seenG = <String>{};
    for (final p in pages.where((p) => p.content.isVocab)) {
      for (final e in p.content.entries ?? const <TBEntry>[]) {
        entries.add(e);
        final toks = e.t.toLowerCase().split(' ').where((s) => s.isNotEmpty).toList();
        if (toks.length == 1) {
          _single.putIfAbsent(toks[0], () => e);
        } else if (toks.length > 1) {
          _phrases.add((tokens: toks, kind: e.kind));
        }
      }
      for (final g in p.content.grammar ?? const <TBGrammar>[]) {
        if (seenG.add(g.title)) grammar.add(g);
      }
    }
  }

  final entries = <TBEntry>[];
  final grammar = <TBGrammar>[];
  final _single = <String, TBEntry>{};
  final _phrases = <({List<String> tokens, String kind})>[];

  bool get isEmpty => entries.isEmpty && grammar.isEmpty;

  /// 課文裡的字在單字表的哪一列（"benches" → bench）
  TBEntry? entry(String word) {
    for (final f in forms(word)) {
      final e = _single[f];
      if (e != null) return e;
    }
    return null;
  }

  /// 課文裡的字可能是哪個字的原形（"benches" → bench、"stopped" → stop）
  static List<String> forms(String word) {
    var w = word.toLowerCase();
    for (final s in const ["'s", '’s']) {
      if (w.endsWith(s)) w = w.substring(0, w.length - 2);
    }
    final out = [w];
    void add(String s) {
      if (s.length >= 2 && !out.contains(s)) out.add(s);
    }

    String? doubled(String s) {
      if (s.length < 3) return null;
      final last = s[s.length - 1];
      if (s[s.length - 2] != last || 'aeiou'.contains(last)) return null;
      return s.substring(0, s.length - 1);
    }

    if (w.endsWith('ies')) add('${w.substring(0, w.length - 3)}y');
    if (w.endsWith('es')) add(w.substring(0, w.length - 2));
    if (w.endsWith('s') && !w.endsWith('ss')) add(w.substring(0, w.length - 1));
    if (w.endsWith('ied')) add('${w.substring(0, w.length - 3)}y');
    if (w.endsWith('ed')) {
      final stem = w.substring(0, w.length - 2);
      add(stem);
      add(w.substring(0, w.length - 1));
      final d = doubled(stem);
      if (d != null) add(d);
    }
    if (w.endsWith('ing')) {
      final stem = w.substring(0, w.length - 3);
      add(stem);
      add('${stem}e');
      final d = doubled(stem);
      if (d != null) add(d);
    }
    final e = Dict.lookup(w);
    if (e != null) add(e.w.toLowerCase());
    return out;
  }

  static const _placeholders = {'sb', 'sth', 'sb.', 'sth.', 'someone', 'somebody', 'something', "one's",
    "sb's", 'oneself', 'one', 'a.', 'n.', 'v.', '…', '...', '~'};
  static const _possessives = {'my', 'your', 'his', 'her', 'its', 'our', 'their'};
  static const _be = {'be', 'is', 'am', 'are', 'was', 'were', 'been', 'being', "'s", '’s'};

  static bool _token(String tok, String word) {
    final w = word.toLowerCase();
    if (tok == 'be') return _be.contains(w);
    if (tok == 'oneself') return w.endsWith('self') || w.endsWith('selves');
    return forms(w).contains(tok);
  }

  /// 從 wi 開始對得上這個片語的字的位置；對不上是 null
  static List<int>? _match(List<String> toks, List<String> words, int ti, int wi) {
    if (ti == toks.length) return [];
    if (wi >= words.length) return null;
    final tok = toks[ti];
    if (_placeholders.contains(tok)) {
      if ((tok == "one's" || tok == "sb's") && _possessives.contains(words[wi].toLowerCase())) {
        final rest = _match(toks, words, ti + 1, wi + 1);
        if (rest != null) return rest;
      }
      if (tok == 'oneself' && _token(tok, words[wi])) {
        final rest = _match(toks, words, ti + 1, wi + 1);
        if (rest != null) return [wi, ...rest];
      }
      for (var skip = 1; skip <= 3 && wi + skip <= words.length; skip++) {
        final rest = _match(toks, words, ti + 1, wi + skip);
        if (rest != null) return rest;
      }
      return null;
    }
    if (!_token(tok, words[wi])) return null;
    final rest = _match(toks, words, ti + 1, wi + 1);
    return rest == null ? null : [wi, ...rest];
  }

  /// 這頁每個字：在單字表是哪一種（word、general 或 phrase），以及是不是單字表片語的一部分
  ({Map<TBPos, String> kinds, Set<TBPos> phrase}) marks(TBPage page) {
    final kinds = <TBPos, String>{}, phrase = <TBPos>{};
    if (entries.isEmpty || page.content.isVocab) return (kinds: kinds, phrase: phrase);
    for (final (p, para) in page.content.paragraphs.indexed) {
      for (final (s, sen) in para.sentences.indexed) {
        final words = [for (var w = 0; w < sen.words.length; w++) page.shown((p: p, s: s, w: w))];
        for (final (w, word) in words.indexed) {
          if (word.length < 2) continue;
          final e = entry(word);
          if (e != null) kinds[(p: p, s: s, w: w)] = e.kind;
        }
        for (final ph in _phrases) {
          for (var start = 0; start < words.length; start++) {
            if (!_token(ph.tokens[0], words[start]) && !_placeholders.contains(ph.tokens[0])) continue;
            final hit = _match(ph.tokens, words, 0, start);
            if (hit == null || hit.isEmpty) continue;
            for (final w in hit) {
              phrase.add((p: p, s: s, w: w));
            }
            break;
          }
        }
      }
    }
    return (kinds: kinds, phrase: phrase);
  }

  static String kindName(String kind) => switch (kind) {
        'general' => '一般生字',
        'phrase' => '片語',
        'grammar' => '文法重點',
        _ => '生字',
      };
}

// MARK: 課文裡的文法重點

class GrammarMarker {
  /// 這頁課文用到這課文法重點的句子。iOS 有 Apple Intelligence 時用模型找；Android 用句型比對：
  /// 每個文法重點裡的英文字，依序出現在句子裡
  static ({List<TBMark> marks, String by}) marks(TBPage page, List<TBGrammar> grammar) =>
      (marks: ruleMarks(page, grammar), by: 'rule');

  static List<({int p, int s, String text})> _sentences(TBPage page) => [
        for (final (p, para) in page.content.paragraphs.indexed)
          if (para.style == null)
            for (var s = 0; s < para.sentences.length; s++) (p: p, s: s, text: page.sentence(p, s)),
      ];

  static const _slots = {'s', 'v', 'o', 'n', 'c', 'adj', 'adv', 'ving', 'v-ing', 'ved', 'pp', 'p.p', 'to-v',
    'sb', 'sth', 'n.', 'v.', 'adj.', 'adv.', 'a', 'an'};
  static final _edgePunct = RegExp(r'^\p{P}+|\p{P}+$', unicode: true);

  /// "not only … but also …" → [["not", "only"], ["but", "also"]]；說明式或只有中文的標題回傳空的
  static List<List<String>> fragments(String title) {
    final english = GlossaryParser.halfwidth(title).replaceFirst(RegExp(r'[\p{Script=Han}，。：；（）「」]+.*$', unicode: true), '');
    final parts = english.split(RegExp(r'[…~+/()\[\],=．]')).expand((s) => s.split('...'));
    final frags = [
      for (final part in parts)
        [
          for (final raw in part.toLowerCase().split(' '))
            if (raw.replaceAll(_edgePunct, '') case final w
                when w.isNotEmpty && !_slots.contains(w) && RegExp(r"^[\p{L}']+$", unicode: true).hasMatch(w))
              w,
        ],
    ].where((f) => f.isNotEmpty).toList();
    final words = frags.expand((f) => f).toList();
    // 只有一個字（"that"）到處都對得上；每個字都要是真的字
    if (words.length < 2 || !words.every((w) => Dict.lookup(w) != null)) return [];
    return frags;
  }

  static List<TBMark> ruleMarks(TBPage page, List<TBGrammar> grammar) {
    final out = <TBMark>[];
    for (final g in grammar) {
      final frags = fragments(g.title);
      if (frags.isEmpty) continue;
      for (final s in _sentences(page)) {
        final words = [for (final w in s.text.toLowerCase().split(' ')) if (w.isNotEmpty) TBText.core(w)];
        var at = 0, ok = true;
        for (final f in frags) {
          int? found;
          for (var i = at; i < words.length - f.length + 1; i++) {
            var all = true;
            for (var j = 0; j < f.length; j++) {
              if (!LessonIndex.forms(words[i + j]).contains(f[j])) {
                all = false;
                break;
              }
            }
            if (all) {
              found = i;
              break;
            }
          }
          if (found == null) {
            ok = false;
            break;
          }
          at = found + f.length;
        }
        if (ok) out.add(TBMark(p: s.p, s: s.s, g: g.title, why: frags.map((f) => f.join(' ')).join(' … ')));
      }
    }
    return out;
  }
}

// MARK: 書架這邊

/// 「這課的生字」的一個字：有單字表就是單字表的字（word、general 或 phrase），沒有的話是課文裡的大考或多益字（dict）
class LessonWord {
  LessonWord(this.entry, this.kind, this.meanings);
  final DictEntry entry;
  final String kind;

  /// 單字表上印的意思
  final List<String>? meanings;
  String get id => '$kind:${entry.w}';
}

extension ShelfStructure on Shelf {
  /// 這課的單字表和文法重點，有頁面改過才重算
  LessonIndex index(String lessonId) {
    final ps = pagesIn(lessonId);
    final key = ps.map((p) => '${p.id}${p.updatedAt.microsecondsSinceEpoch}').join();
    final c = indexCache[lessonId];
    if (c != null && c.$1 == key) return c.$2 as LessonIndex;
    final idx = LessonIndex(ps);
    indexCache[lessonId] = (key, idx);
    return idx;
  }

  /// 每頁課文還沒對照過這課文法重點的，找出用到文法的句子
  Future<void> markGrammar(String lessonId) async {
    if (!marking.add(lessonId)) return;
    try {
      final grammar = index(lessonId).grammar;
      final titles = grammar.map((g) => g.title).toList();
      for (final p in pagesIn(lessonId).where((p) => !p.content.isVocab)) {
        // Android 沒有 AI，iPhone 用 AI 找過的（"ai"）或用同一份文法重點找過的就不再找
        if (listEquals(p.content.checked ?? const <String>[], titles)) continue;
        if (titles.isEmpty) {
          setMarks(p.id, [], [], 'rule');
          continue;
        }
        final r = GrammarMarker.marks(p, grammar);
        setMarks(p.id, r.marks, titles, r.by);
        DevLog.add('textbook', 'grammar: ${r.marks.length} sentences on a page (${r.by})');
      }
    } finally {
      marking.remove(lessonId);
    }
  }

  /// 這課的生字：有單字表就用單字表的字；沒有的話，課文裡依出現順序的大考字（第 2 級以上，第 1 級高中生都會）
  /// 和多益字。人名（課文某處句中大寫，例如 "Lily"）不算
  List<LessonWord> lessonWords(String lessonId) {
    final idx = index(lessonId);
    if (idx.entries.isNotEmpty) {
      final seen = <String>{};
      return [
        for (final e in idx.entries)
          if (_listed(e) case final entry when seen.add(entry.w)) LessonWord(entry, e.kind, e.zh),
      ];
    }
    final ps = pagesIn(lessonId).where((p) => !p.content.isVocab).toList();
    final names = <String>{};
    for (final p in ps) {
      for (final (pos, _) in p.content.allWords) {
        if (pos.w == 0) continue;
        final core = p.shown(pos);
        if (_isUpper(core)) names.add(core.toLowerCase());
      }
    }
    final seen = <String>{}, out = <LessonWord>[];
    for (final p in ps) {
      for (final (pos, _) in p.content.allWords) {
        final core = p.shown(pos);
        if (core.length < 2 || names.contains(core.toLowerCase())) continue;
        final e = Dict.lookup(core);
        if (e == null || e.zh.isEmpty) continue;
        if ((int.tryParse(e.lv) ?? 0) < 2 && !e.tags.contains('toeic')) continue;
        if (seen.add(e.w)) out.add(LessonWord(e, 'dict', null));
      }
    }
    return out;
  }

  static DictEntry _listed(TBEntry e) {
    final d = Dict.lookup(e.t);
    return d != null && d.w.toLowerCase() == e.t.toLowerCase() ? d : DictEntry.custom(e.t, e.zh?.firstOrNull ?? '');
  }
}
