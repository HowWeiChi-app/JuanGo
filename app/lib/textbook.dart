// 課文書架（Pro）：書 › 課 › 頁，存在手機，登入後同步到 Supabase。
// 資料格式跟 iPhone 版（ios/JuanGo/Textbook.swift）和 supabase/textbook.sql 一樣，兩邊可以互相讀。
// 免費版可以建 1 課（最多 3 頁）；伺服器也會擋。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'cloud.dart';
import 'dev_log.dart';
import 'dictionary.dart';
import 'models.dart';
import 'pro.dart';
import 'textbook_structure.dart';

// MARK: 頁面內容
// 課文頁：{"v":1,"paragraphs":[{"style":"title","sentences":[{"words":[{"t":"modem,","conf":0.42,"bold":true}]}]}],
//         "marks":[{"p":0,"s":1,"g":"not only … but also …","why":"not only … but also"}],"checked":["…"],"checked_by":"rule"}
// 單字表頁："kind":"vocab"，"entries":[{"t":"bench","pos":"n.","zh":["長椅"],"kind":"word"}]、"grammar":[{"title":"…","note":"…"}]
// 沒有的欄位就是預設值。不保留原圖。

class TBWord {
  TBWord(this.t, {this.box, this.conf, this.bold});
  factory TBWord.fromJson(Map<String, dynamic> j) => TBWord(
    j['t'] as String? ?? '',
    box: (j['box'] as List?)?.map((e) => (e as num).toDouble()).toList(),
    conf: (j['conf'] as num?)?.toDouble(),
    bold: j['bold'] as bool?,
  );

  /// 印出來的樣子，含標點（"modem,"）
  String t;

  /// 照片上的位置（0~1，左上角為原點）：x, y, 寬, 高。只在辨識時用，不存
  List<double>? box;

  /// 辨識的信心分數 0~1
  double? conf;

  /// 課本印成粗體（課本通常把這課的生字印粗體）
  bool? bold;

  String get core => TBText.core(t);
  bool get isBold => bold == true;

  Map<String, dynamic> toJson() => {
    't': t,
    if (box != null) 'box': box,
    if (conf != null) 'conf': conf,
    if (bold == true) 'bold': true,
  };
}

class TBSentence {
  TBSentence(this.words);
  factory TBSentence.fromJson(Map<String, dynamic> j) => TBSentence([
    for (final w in j['words'] as List? ?? const [])
      TBWord.fromJson(w as Map<String, dynamic>),
  ]);
  final List<TBWord> words;
  Map<String, dynamic> toJson() => {
    'words': [for (final w in words) w.toJson()],
  };
}

class TBParagraph {
  TBParagraph(this.sentences, {this.style});
  factory TBParagraph.fromJson(Map<String, dynamic> j) => TBParagraph([
    for (final s in j['sentences'] as List? ?? const [])
      TBSentence.fromJson(s as Map<String, dynamic>),
  ], style: j['style'] as String?);
  final List<TBSentence> sentences;

  /// title 或 subtitle；內文是 null
  final String? style;
  Map<String, dynamic> toJson() => {
    'sentences': [for (final s in sentences) s.toJson()],
    'style': ?style,
  };
}

/// 單字表的一列：生字（word）、一般生字（general）或片語（phrase）
class TBEntry {
  TBEntry(this.t, {this.pos, this.zh, required this.kind});
  factory TBEntry.fromJson(Map<String, dynamic> j) => TBEntry(
    j['t'] as String? ?? '',
    pos: j['pos'] as String?,
    zh: (j['zh'] as List?)?.cast<String>(),
    kind: j['kind'] as String? ?? 'word',
  );
  final String t;
  final String? pos;
  final List<String>? zh;
  final String kind;
  String get meaning => (zh ?? const []).take(3).join('；');
  Map<String, dynamic> toJson() => {
    't': t,
    'pos': ?pos,
    'zh': ?zh,
    'kind': kind,
  };
}

/// 單字表上的文法重點
class TBGrammar {
  TBGrammar(this.title, {this.note});
  factory TBGrammar.fromJson(Map<String, dynamic> j) =>
      TBGrammar(j['title'] as String? ?? '', note: j['note'] as String?);
  final String title;
  String? note;
  Map<String, dynamic> toJson() => {'title': title, 'note': ?note};
}

/// 課文裡用到這課文法重點的句子（g 是文法重點的標題）
class TBMark {
  TBMark({required this.p, required this.s, required this.g, this.why});
  factory TBMark.fromJson(Map<String, dynamic> j) => TBMark(
    p: j['p'] as int? ?? 0,
    s: j['s'] as int? ?? 0,
    g: j['g'] as String? ?? '',
    why: j['why'] as String?,
  );
  final int p, s;
  final String g;

  /// 句子裡展現這個文法的字
  final String? why;
  Map<String, dynamic> toJson() => {'p': p, 's': s, 'g': g, 'why': ?why};
}

/// 字在頁面的哪裡：段落 › 句子 › 字
typedef TBPos = ({int p, int s, int w});

class TBContent {
  TBContent(
    this.paragraphs, {
    this.kind,
    this.entries,
    this.grammar,
    this.marks,
    this.checked,
    this.checkedBy,
  });
  factory TBContent.fromJson(Map<String, dynamic> j) => TBContent(
    [
      for (final p in j['paragraphs'] as List? ?? const [])
        TBParagraph.fromJson(p as Map<String, dynamic>),
    ],
    kind: j['kind'] as String?,
    entries: (j['entries'] as List?)
        ?.map((e) => TBEntry.fromJson(e as Map<String, dynamic>))
        .toList(),
    grammar: (j['grammar'] as List?)
        ?.map((e) => TBGrammar.fromJson(e as Map<String, dynamic>))
        .toList(),
    marks: (j['marks'] as List?)
        ?.map((e) => TBMark.fromJson(e as Map<String, dynamic>))
        .toList(),
    checked: (j['checked'] as List?)?.cast<String>(),
    checkedBy: j['checked_by'] as String?,
  );
  final List<TBParagraph> paragraphs;

  /// 單字表頁是 "vocab"；課文是 null
  final String? kind;
  final List<TBEntry>? entries;
  final List<TBGrammar>? grammar;
  List<TBMark>? marks;

  /// 找文法句子時用的文法重點標題，和用什麼找的（ai 或 rule）
  List<String>? checked;
  String? checkedBy;

  bool get isVocab => kind == 'vocab';
  bool get isEmpty =>
      paragraphs.every((p) => p.sentences.every((s) => s.words.isEmpty)) &&
      (entries ?? const []).isEmpty &&
      (grammar ?? const []).isEmpty;

  /// 位置只在辨識時用，存檔前拿掉
  TBContent dropBoxes() {
    for (final (_, w) in allWords) {
      w.box = null;
    }
    return this;
  }

  TBWord? word(TBPos at) {
    if (at.p >= paragraphs.length) return null;
    final ss = paragraphs[at.p].sentences;
    if (at.s >= ss.length || at.w >= ss[at.s].words.length) return null;
    return ss[at.s].words[at.w];
  }

  Iterable<(TBPos, TBWord)> get allWords sync* {
    for (final (p, para) in paragraphs.indexed) {
      for (final (s, sen) in para.sentences.indexed) {
        for (final (w, word) in sen.words.indexed) {
          yield ((p: p, s: s, w: w), word);
        }
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'v': 1,
    'kind': ?kind,
    'paragraphs': [for (final p in paragraphs) p.toJson()],
    if (entries != null) 'entries': [for (final e in entries!) e.toJson()],
    if (grammar != null) 'grammar': [for (final g in grammar!) g.toJson()],
    if (marks != null) 'marks': [for (final m in marks!) m.toJson()],
    'checked': ?checked,
    'checked_by': ?checkedBy,
  };
}

/// 一個字的修正建議或已接受的修正。頁面本身留著原本辨識的字，接受的修正在顯示時才套上，
/// 所以隨時可以「保留原文」改回來
class TBCorrection {
  TBCorrection({
    required this.p,
    required this.s,
    required this.w,
    required this.original,
    required this.suggestion,
    required this.source,
    required this.status,
  });
  factory TBCorrection.fromJson(Map<String, dynamic> j) => TBCorrection(
    p: j['p'] as int? ?? 0,
    s: j['s'] as int? ?? 0,
    w: j['w'] as int? ?? 0,
    original: j['original'] as String? ?? '',
    suggestion: j['suggestion'] as String? ?? '',
    source: j['source'] as String? ?? 'dictionary',
    status: j['status'] as String? ?? 'pending',
  );
  final int p, s, w;
  final String original, suggestion;

  /// ai、dictionary 或 manual
  final String source;

  /// pending、accepted 或 rejected
  String status;

  TBPos get pos => (p: p, s: s, w: w);
  bool get isPending => status == 'pending';
  String get sourceName => source == 'ai'
      ? 'Apple Intelligence'
      : source == 'manual'
      ? '手動修改'
      : '字典比對';

  Map<String, dynamic> toJson() => {
    'p': p,
    's': s,
    'w': w,
    'original': original,
    'suggestion': suggestion,
    'source': source,
    'status': status,
  };
}

class TBText {
  static final _edges = RegExp(
    r"^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$",
    unicode: true,
  );

  /// "“Modem,”" → "Modem"
  static String core(String t) => t.replaceAll(_edges, '');

  /// 把接受的修正套進印出來的字（"modem," → "modern,"）
  static String apply(TBCorrection? c, String t) =>
      c == null || c.status != 'accepted' || !t.contains(c.original)
      ? t
      : t.replaceFirst(c.original, c.suggestion);
}

// MARK: 書、課、頁

class TBBook {
  TBBook({
    required this.id,
    required this.title,
    this.subject,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.deletedAt,
    this.dirty = true,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();
  factory TBBook.fromJson(Map<String, dynamic> j) => TBBook(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    subject: j['subject'] as String?,
    createdAt: TBDate.parse(j['created_at']),
    updatedAt: TBDate.parse(j['updated_at']),
    deletedAt: TBDate.parse(j['deleted_at']),
    dirty: j['dirty'] as bool? ?? false,
  );
  final String id;
  String title;
  String? subject;
  DateTime createdAt, updatedAt;
  DateTime? deletedAt;

  /// 在這裡改過、還沒上傳
  bool dirty;

  Map<String, dynamic> toRow(String uid) => {
    'id': id,
    'user_id': uid,
    'title': title,
    'subject': subject,
    'created_at': TBDate.string(createdAt),
    'deleted_at': deletedAt == null ? null : TBDate.string(deletedAt!),
  };
  Map<String, dynamic> toJson() => {
    ...toRow(''),
    'updated_at': TBDate.string(updatedAt),
    'dirty': dirty,
  };
}

class TBLesson {
  TBLesson({
    required this.id,
    required this.bookId,
    required this.title,
    required this.sort,
    this.lastReadPage = 0,
    DateTime? updatedAt,
    this.deletedAt,
    this.dirty = true,
  }) : updatedAt = updatedAt ?? DateTime.now();
  factory TBLesson.fromJson(Map<String, dynamic> j) => TBLesson(
    id: j['id'] as String,
    bookId: j['book_id'] as String,
    title: j['title'] as String? ?? '',
    sort: j['sort'] as int? ?? 0,
    lastReadPage: j['last_read_page'] as int? ?? 0,
    updatedAt: TBDate.parse(j['updated_at']),
    deletedAt: TBDate.parse(j['deleted_at']),
    dirty: j['dirty'] as bool? ?? false,
  );
  final String id, bookId;
  String title;
  int sort, lastReadPage;
  DateTime updatedAt;
  DateTime? deletedAt;
  bool dirty;

  Map<String, dynamic> toRow() => {
    'id': id,
    'book_id': bookId,
    'title': title,
    'sort': sort,
    'last_read_page': lastReadPage,
    'deleted_at': deletedAt == null ? null : TBDate.string(deletedAt!),
  };
  Map<String, dynamic> toJson() => {
    ...toRow(),
    'updated_at': TBDate.string(updatedAt),
    'dirty': dirty,
  };
}

class TBPage {
  TBPage({
    required this.id,
    required this.lessonId,
    required this.sort,
    this.imagePath,
    required this.content,
    List<TBCorrection>? corrections,
    DateTime? updatedAt,
    this.deletedAt,
    this.dirty = true,
  }) : corrections = corrections ?? [],
       updatedAt = updatedAt ?? DateTime.now();
  factory TBPage.fromJson(Map<String, dynamic> j) => TBPage(
    id: j['id'] as String,
    lessonId: j['lesson_id'] as String,
    sort: j['sort'] as int? ?? 0,
    imagePath: j['image_path'] as String?,
    content: TBContent.fromJson(
      j['content'] as Map<String, dynamic>? ?? const {},
    ),
    corrections: [
      for (final c in j['corrections'] as List? ?? const [])
        TBCorrection.fromJson(c as Map<String, dynamic>),
    ],
    updatedAt: TBDate.parse(j['updated_at']),
    deletedAt: TBDate.parse(j['deleted_at']),
    dirty: j['dirty'] as bool? ?? false,
  );
  final String id, lessonId;
  int sort;

  /// 舊版上傳過的原圖路徑；下次同步時會從雲端刪掉
  String? imagePath;
  final TBContent content;
  final List<TBCorrection> corrections;
  DateTime updatedAt;
  DateTime? deletedAt;
  bool dirty;

  TBCorrection? correction(TBPos pos) {
    for (final c in corrections) {
      if (c.pos == pos) return c;
    }
    return null;
  }

  List<TBCorrection> get pending =>
      corrections.where((c) => c.isPending).toList();

  /// 套上修正後的字母
  String shown(TBPos pos) {
    final w = content.word(pos);
    return w == null ? '' : TBText.core(TBText.apply(correction(pos), w.t));
  }

  String sentence(int p, int s) => [
    for (final (w, word) in content.paragraphs[p].sentences[s].words.indexed)
      TBText.apply(correction((p: p, s: s, w: w)), word.t),
  ].join(' ');

  Map<String, dynamic> toRow() => {
    'id': id,
    'lesson_id': lessonId,
    'sort': sort,
    'image_path': imagePath,
    'content': content.toJson(),
    'corrections': [for (final c in corrections) c.toJson()],
    'deleted_at': deletedAt == null ? null : TBDate.string(deletedAt!),
  };
  Map<String, dynamic> toJson() => {
    ...toRow(),
    'updated_at': TBDate.string(updatedAt),
    'dirty': dirty,
  };
}

/// Postgres 的時間字串和 DateTime 互轉
class TBDate {
  static DateTime? parse(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;
  static String string(DateTime d) => d.toUtc().toIso8601String();
}

String _uuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

// MARK: 書架

class Shelf extends ChangeNotifier {
  Shelf._();
  static final shared = Shelf._();

  static const freeLessons = 1, freePages = 3, proPages = 1000, warnPages = 900;

  final List<TBBook> books = [];
  final List<TBLesson> lessons = [];
  final List<TBPage> pages = [];
  bool syncing = false;
  String? syncMessage;

  String? _cursor;

  /// 每課的單字表索引（textbook_structure.dart），頁面改了才重算
  final indexCache = <String, (String, Object)>{};
  final marking = <String>{};
  Directory? _dir;
  bool _loaded = false;

  /// 測試用：不寫檔、不同步
  @visibleForTesting
  bool ephemeral = false;

  Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/textbook');
    await d.create(recursive: true);
    // 只存電子版：舊版存的原圖刪掉
    final old = Directory('${d.path}/images');
    if (await old.exists()) await old.delete(recursive: true);
    return _dir = d;
  }

  Future<void> load() async {
    if (_loaded || ephemeral) return;
    _loaded = true;
    try {
      final f = File('${(await _folder()).path}/shelf.json');
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        books.addAll([
          for (final b in j['books'] as List? ?? const [])
            TBBook.fromJson(b as Map<String, dynamic>),
        ]);
        lessons.addAll([
          for (final l in j['lessons'] as List? ?? const [])
            TBLesson.fromJson(l as Map<String, dynamic>),
        ]);
        pages.addAll([
          for (final p in j['pages'] as List? ?? const [])
            TBPage.fromJson(p as Map<String, dynamic>),
        ]);
        _cursor = j['cursor'] as String?;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    if (ephemeral) return;
    final data = jsonEncode({
      'books': [for (final b in books) b.toJson()],
      'lessons': [for (final l in lessons) l.toJson()],
      'pages': [for (final p in pages) p.toJson()],
      'cursor': _cursor,
    });
    final f = File('${(await _folder()).path}/shelf.json');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(f.path);
  }

  // MARK: 讀

  List<TBBook> get liveBooks =>
      books.where((b) => b.deletedAt == null).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  TBBook? book(String id) => books.where((b) => b.id == id).firstOrNull;
  TBLesson? lesson(String id) => lessons.where((l) => l.id == id).firstOrNull;
  TBPage? page(String id) => pages.where((p) => p.id == id).firstOrNull;
  List<TBLesson> lessonsIn(String bookId) =>
      lessons.where((l) => l.bookId == bookId && l.deletedAt == null).toList()
        ..sort((a, b) => a.sort.compareTo(b.sort));
  List<TBPage> pagesIn(String lessonId) =>
      pages.where((p) => p.lessonId == lessonId && p.deletedAt == null).toList()
        ..sort((a, b) => a.sort.compareTo(b.sort));

  List<TBLesson> get _liveLessons {
    final live = liveBooks.map((b) => b.id).toSet();
    return lessons
        .where((l) => l.deletedAt == null && live.contains(l.bookId))
        .toList();
  }

  int get lessonCount => _liveLessons.length;
  int get pageCount {
    final live = _liveLessons.map((l) => l.id).toSet();
    return pages
        .where((p) => p.deletedAt == null && live.contains(p.lessonId))
        .length;
  }

  // MARK: 上限（supabase/textbook.sql 也檢查一樣的事）

  bool get isPro => ProStore.shared.has(ProFeature.textbook);
  bool get canAddBook => isPro || liveBooks.isEmpty;
  bool get canAddLesson => isPro || lessonCount < freeLessons;
  int get pagesLeft => max(0, (isPro ? proPages : freePages) - pageCount);

  // MARK: 改

  TBBook addBook(String title, String? subject) {
    final b = TBBook(
      id: _uuid(),
      title: title,
      subject: subject == null || subject.isEmpty ? null : subject,
    );
    books.add(b);
    _changed();
    return b;
  }

  void updateBook(String id, String title, String? subject) {
    final b = book(id);
    if (b == null) return;
    b
      ..title = title
      ..subject = subject == null || subject.isEmpty ? null : subject;
    _touch(b);
    _changed();
  }

  void deleteBook(String id) {
    final b = book(id);
    if (b == null) return;
    b.deletedAt = DateTime.now();
    _touch(b);
    for (final l in lessonsIn(id)) {
      deleteLesson(l.id, saving: false);
    }
    _changed();
  }

  TBLesson addLesson(String bookId, String title) {
    final sort =
        lessons
            .where((l) => l.bookId == bookId)
            .fold(-1, (m, l) => max(m, l.sort)) +
        1;
    final l = TBLesson(id: _uuid(), bookId: bookId, title: title, sort: sort);
    lessons.add(l);
    book(bookId)?.updatedAt = DateTime.now();
    _changed();
    return l;
  }

  void renameLesson(String id, String title) {
    final l = lesson(id);
    if (l == null) return;
    l.title = title;
    _touch(l);
    _changed();
  }

  void deleteLesson(String id, {bool saving = true}) {
    final l = lesson(id);
    if (l == null) return;
    l.deletedAt = DateTime.now();
    _touch(l);
    for (final p in pagesIn(id)) {
      deletePage(p.id, saving: false);
    }
    if (saving) _changed();
  }

  void setLastRead(String id, int page) {
    final l = lesson(id);
    if (l == null || l.lastReadPage == page) return;
    l.lastReadPage = page;
    _touch(l);
    book(l.bookId)?.updatedAt = DateTime.now();
    _changed();
  }

  Future<void> addPage(
    String lessonId,
    TBContent content,
    List<TBCorrection> corrections,
  ) async {
    final sort =
        pages
            .where((p) => p.lessonId == lessonId)
            .fold(-1, (m, p) => max(m, p.sort)) +
        1;
    final p = TBPage(
      id: _uuid(),
      lessonId: lessonId,
      sort: sort,
      content: content.dropBoxes(),
      corrections: corrections,
    );
    pages.add(p);
    final l = lesson(lessonId);
    if (l != null) book(l.bookId)?.updatedAt = DateTime.now();
    _changed();
  }

  void deletePage(String id, {bool saving = true}) {
    final p = page(id);
    if (p == null) return;
    p.deletedAt = DateTime.now();
    _touch(p);
    if (saving) _changed();
  }

  /// 接受、保留原文，或手動改字（手動改的直接算接受）
  void setCorrection(String pageId, TBCorrection c) {
    final p = page(pageId);
    if (p == null) return;
    p.corrections.removeWhere((x) => x.pos == c.pos);
    if (!(c.source == 'manual' && c.original == c.suggestion))
      p.corrections.add(c);
    _touch(p);
    _changed();
  }

  /// 找到的文法句子
  void setMarks(
    String pageId,
    List<TBMark> marks,
    List<String> checked,
    String by,
  ) {
    final p = page(pageId);
    if (p == null) return;
    p.content
      ..marks = marks.isEmpty ? null : marks
      ..checked = checked
      ..checkedBy = by;
    _touch(p);
    _changed();
  }

  void acceptAll(String pageId) {
    final p = page(pageId);
    if (p == null) return;
    for (final c in p.corrections) {
      if (c.isPending) c.status = 'accepted';
    }
    _touch(p);
    _changed();
  }

  void _touch(Object x) {
    final now = DateTime.now();
    switch (x) {
      case TBBook b:
        b
          ..updatedAt = now
          ..dirty = true;
      case TBLesson l:
        l
          ..updatedAt = now
          ..dirty = true;
      case TBPage p:
        p
          ..updatedAt = now
          ..dirty = true;
    }
  }

  void _changed() {
    unawaited(_save());
    _pushSoon();
  }

  // MARK: 同步

  Timer? _pushTimer;
  void _pushSoon() {
    if (ephemeral || !Cloud.shared.signedIn) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(
      const Duration(seconds: 4),
      () => unawaited(sync(quiet: true)),
    );
  }

  Uri _rest(String table, Map<String, String> q) =>
      Uri.parse('${CloudConfig.url}/rest/v1/$table')
          .replace(queryParameters: q);
  Uri _storage(String path) =>
      Uri.parse('${CloudConfig.url}/storage/v1/object/textbook-pages/$path');

  /// 先拿其他裝置改過的，再上傳這裡改過的
  Future<void> sync({bool quiet = false}) async {
    final uid = Cloud.shared.session?.userId.toLowerCase();
    if (ephemeral || uid == null || syncing) return;
    syncing = true;
    notifyListeners();
    try {
      await _pull();
      await _push(uid);
      if (!quiet) syncMessage = null;
    } on CloudFailure catch (e) {
      final t = e.message;
      DevLog.add('textbook', '同步失敗：$t');
      if (t.contains('textbook_free_limit')) {
        syncMessage = '免費版只能同步 1 課（最多 3 頁），升級 Pro 就能同步全部。';
      } else if (t.contains('textbook_page_limit')) {
        syncMessage = '已經到 1000 頁的上限，刪掉一些頁面才能再上傳。';
      } else if (t.contains('Could not find the table') ||
          t.contains('relation')) {
        syncMessage = '課文書架的雲端還沒開通，先存在這支手機。';
      } else {
        syncMessage = t;
      }
    } finally {
      syncing = false;
      await _save();
    }
  }

  Future<void> _pull() async {
    var newest = _cursor;
    Future<List<Map<String, dynamic>>> fetch(String table) async {
      final rows = <Map<String, dynamic>>[];
      var offset = 0;
      while (true) {
        final q = {
          'select': '*',
          'order': 'updated_at.asc',
          'limit': '200',
          'offset': '$offset',
          'updated_at': ?_gte(_cursor),
        };
        final body = utf8.decode(
          await Cloud.shared.sendBytes(_rest(table, q), 'GET'),
        );
        final page = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
        rows.addAll(page);
        if (page.length < 200) break;
        offset += page.length;
      }
      for (final r in rows) {
        final u = r['updated_at'] as String?;
        if (u != null && (newest == null || u.compareTo(newest!) > 0))
          newest = u;
      }
      return rows;
    }

    for (final r in await fetch('books')) {
      final b = TBBook.fromJson(r);
      final i = books.indexWhere((x) => x.id == b.id);
      if (i < 0) {
        books.add(b);
      } else if (!books[i].dirty) {
        books[i] = b;
      }
    }
    for (final r in await fetch('lessons')) {
      final l = TBLesson.fromJson(r);
      final i = lessons.indexWhere((x) => x.id == l.id);
      if (i < 0) {
        lessons.add(l);
      } else if (!lessons[i].dirty) {
        lessons[i] = l;
      }
    }
    for (final r in await fetch('pages')) {
      final p = TBPage.fromJson(r);
      final i = pages.indexWhere((x) => x.id == p.id);
      if (i < 0) {
        pages.add(p);
      } else if (!pages[i].dirty) {
        pages[i] = p;
      }
    }
    _cursor = newest;
  }

  static String? _gte(String? cursor) => cursor == null ? null : 'gte.$cursor';

  Future<void> _push(String uid) async {
    Future<void> upsert(String table, List<Map<String, dynamic>> rows) async {
      for (var i = 0; i < rows.length; i += 50) {
        final chunk = rows.sublist(i, min(i + 50, rows.length));
        await Cloud.shared.sendBytes(
          _rest(table, {'on_conflict': 'id'}),
          'POST',
          body: utf8.encode(jsonEncode(chunk)),
          prefer: 'resolution=merge-duplicates,return=minimal',
          timeout: const Duration(seconds: 60),
        );
      }
    }

    final dirtyBooks = books.where((b) => b.dirty).toList();
    final stampsB = {for (final b in dirtyBooks) b.id: b.updatedAt};
    await upsert('books', [for (final b in dirtyBooks) b.toRow(uid)]);
    for (final b in dirtyBooks) {
      if (b.updatedAt == stampsB[b.id]) b.dirty = false;
    }

    // 書還沒上去的課先不傳
    final dirtyLessons = lessons
        .where((l) => l.dirty && book(l.bookId)?.dirty == false)
        .toList();
    final stampsL = {for (final l in dirtyLessons) l.id: l.updatedAt};
    await upsert('lessons', [for (final l in dirtyLessons) l.toRow()]);
    for (final l in dirtyLessons) {
      if (l.updatedAt == stampsL[l.id]) l.dirty = false;
    }

    final dirtyPages = pages
        .where((p) => p.dirty && lesson(p.lessonId)?.dirty == false)
        .toList();
    final stampsP = {for (final p in dirtyPages) p.id: p.updatedAt};
    await upsert('pages', [for (final p in dirtyPages) p.toRow()]);

    for (final p in dirtyPages) {
      if (p.updatedAt == stampsP[p.id]) p.dirty = false;
    }

    // 舊版上傳的原圖：從 Storage 刪掉，路徑清掉
    final cleared = <TBPage>[];
    for (final p in pages) {
      if (p.imagePath == null || lesson(p.lessonId)?.dirty != false) continue;
      try {
        await Cloud.shared.sendBytes(_storage(p.imagePath!), 'DELETE');
      } on CloudFailure catch (_) {}
      p.imagePath = null;
      cleared.add(p);
    }
    await upsert('pages', [for (final p in cleared) p.toRow()]);
    if (cleared.isNotEmpty)
      DevLog.add('textbook', '從雲端刪掉 ${cleared.length} 張舊的原圖');
  }
}

// MARK: 整理版面

/// 一行字和它在照片上的位置（0~1，左上角為原點）
class OcrLine {
  OcrLine(this.words, this.box);
  final List<TBWord> words;
  final ui.Rect box;
}

class PageLayout {
  /// "title"、"subtitle" 或 null：比平常的行高很多，或整行粗體、很短、不像一句話結尾
  static String? style(OcrLine l, double lineH) {
    final r = l.box.height / lineH;
    if (r >= 1.45) return 'title';
    if (r >= 1.18) return 'subtitle';
    final letters = l.words
        .where((w) => w.core.contains(RegExp('[A-Za-z]')))
        .toList();
    if (letters.isNotEmpty &&
        letters.length <= 10 &&
        letters.every((w) => w.isBold) &&
        (!endsSentence(l.words.last.t) || letters.length <= 4)) {
      return 'subtitle';
    }
    return null;
  }

  /// 行 → 段落 → 句子：去掉頁碼和頁首頁尾、標題和副標題自成一段、把行尾用連字號斷開的字接回去，
  /// 遇到空隙、縮排或上一行比較短（段落最後一行）就換段
  static TBContent layout(List<OcrLine> raw) {
    final all = raw.where((l) => l.words.isNotEmpty).toList();
    if (all.isEmpty) return TBContent([]);
    double median(Iterable<double> v) {
      final s = v.toList()..sort();
      return s[s.length ~/ 2];
    }

    final lineH = max(median(all.map((l) => l.box.height)), 0.005);
    final lines = all.where((l) => !isFurniture(l, lineH)).toList();
    if (lines.isEmpty) return TBContent([]);
    final bodyLines = lines.where((l) => style(l, lineH) == null).toList();
    final ref = bodyLines.isEmpty ? lines : bodyLines;
    final left = median(ref.map((l) => l.box.left));
    final widths = ref.map((l) => l.box.width).toList()..sort();
    final fullW = widths[widths.length * 3 ~/ 4];

    final paragraphs = <(List<TBWord>, String?)>[];
    var current = <TBWord>[];
    String? currentStyle;
    void close() {
      if (current.isNotEmpty) paragraphs.add((current, currentStyle));
      current = [];
    }

    OcrLine? prev;
    for (final line in lines) {
      final words = List.of(line.words);
      final st = style(line, lineH);
      if (prev != null) {
        final gap = line.box.top - prev.box.bottom;
        final ends = current.isNotEmpty && endsSentence(current.last.t);
        final newColumn = gap < -lineH * 1.5;
        final indented = line.box.left - left > lineH * 1.2;
        final shortLast = prev.box.width < fullW * 0.8;
        if (st != currentStyle || (st != null && gap > lineH * 0.9)) {
          close();
        } else if (st != null) {
          // 標題換到第二行還是同一個標題
        } else if (gap > lineH * 0.9 ||
            newColumn ||
            (ends && (indented || shortLast))) {
          close();
        } else if (current.isNotEmpty &&
            current.last.t.length > 2 &&
            (current.last.t.endsWith('-') || current.last.t.endsWith('‐')) &&
            words.isNotEmpty &&
            words.first.t.isNotEmpty &&
            words.first.t[0] != words.first.t[0].toUpperCase()) {
          // "impor-" + "tant" → "important"
          final last = current.removeLast();
          final first = words.removeAt(0);
          current.add(
            TBWord(
              last.t.substring(0, last.t.length - 1) + first.t,
              box: last.box,
              conf: min(last.conf ?? 1, first.conf ?? 1),
              bold: last.isBold || first.isBold ? true : null,
            ),
          );
        }
      }
      currentStyle = st;
      current.addAll(words);
      prev = line;
    }
    close();
    return TBContent([
      for (final (words, st) in paragraphs)
        TBParagraph(
          st == null ? sentences(words) : [TBSentence(words)],
          style: st,
        ),
    ]);
  }

  static const _abbreviations = {
    'mr.',
    'mrs.',
    'ms.',
    'dr.',
    'st.',
    'e.g.',
    'i.e.',
    'etc.',
    'vs.',
    'no.',
    'p.',
  };
  static final _closing = RegExp(r'''["'”’)\]]+$''');

  static bool endsSentence(String t) {
    final s = t.replaceAll(_closing, '');
    if (s.isEmpty || !'.!?:'.contains(s[s.length - 1])) return false;
    return !_abbreviations.contains(s.toLowerCase());
  }

  static List<TBSentence> sentences(List<TBWord> words) {
    final out = <TBSentence>[];
    var cur = <TBWord>[];
    for (final (i, w) in words.indexed) {
      cur.add(w);
      final next = i + 1 < words.length && words[i + 1].t.isNotEmpty
          ? words[i + 1].t[0]
          : null;
      if (endsSentence(w.t) &&
          !w.t.endsWith(':') &&
          (next == null || next != next.toLowerCase())) {
        out.add(TBSentence(cur));
        cur = [];
      }
    }
    if (cur.isNotEmpty) out.add(TBSentence(cur));
    return out;
  }

  static final _pageNumber = RegExp(
    r'^[\W_]*(p\.|page)?\s*\d{1,4}[\W_]*$',
    caseSensitive: false,
  );

  /// 頁碼（"12"、"- 12 -"、"p. 12"）和最上、最下 5% 裡的短行（頁首頁尾；比內文大的標題不算）
  static bool isFurniture(OcrLine l, double lineH) {
    if (_pageNumber.hasMatch(l.words.map((w) => w.t).join(' '))) return true;
    return (l.box.bottom < 0.05 || l.box.top > 0.95) &&
        l.words.length <= 6 &&
        l.box.height < lineH * 1.15;
  }
}

// MARK: 修正掃錯的字（只修拼字，不改課文的用字和文法）

class OcrFixer {
  /// 可能掃錯的字：字典裡沒有、或信心分數低於 0.5。人名（句中大寫）和全大寫的標題先跳過
  static List<({TBPos pos, String word, bool unknown, double? conf})>
  candidates(TBContent c) {
    final out = <({TBPos pos, String word, bool unknown, double? conf})>[];
    for (final (pos, word) in c.allWords) {
      final core = word.core;
      if (core.length < 2 || !core.contains(RegExp('[A-Za-z]'))) continue;
      final upper = core[0] != core[0].toLowerCase();
      if (upper && pos.w > 0) continue;
      final digits = core.contains(RegExp('[0-9]'));
      if (core == core.toUpperCase() && !digits) continue;
      final unknown = digits || Dict.lookup(core) == null;
      if (unknown || (word.conf ?? 1) < 0.5)
        out.add((pos: pos, word: core, unknown: unknown, conf: word.conf));
    }
    return out.take(40).toList();
  }

  /// Android 沒有裝置端模型可用，只用字典比對
  static List<TBCorrection> suggest(TBContent c) {
    final out = <TBCorrection>[];
    for (final cand in candidates(c).where((x) => x.unknown)) {
      // 辨識很有把握的字（可能是字典沒收的專有名詞），只套常見的辨識錯誤，不做模糊比對
      final s = fix(cand.word, fuzzy: (cand.conf ?? 0) < 0.9);
      if (s == null) continue;
      out.add(
        TBCorrection(
          p: cand.pos.p,
          s: cand.pos.s,
          w: cand.pos.w,
          original: cand.word,
          suggestion: matchCase(s, cand.word),
          source: 'dictionary',
          status: 'pending',
        ),
      );
    }
    return out;
  }

  static String matchCase(String s, String like) =>
      like.isNotEmpty && like[0] != like[0].toLowerCase() && s.isNotEmpty
      ? s[0].toUpperCase() + s.substring(1)
      : s;

  static const _confusions = [
    ('rn', 'm'),
    ('m', 'rn'),
    ('cl', 'd'),
    ('vv', 'w'),
    ('1', 'l'),
    ('1', 'i'),
    ('0', 'o'),
    ('5', 's'),
    ('l', 'i'),
    ('i', 'l'),
    ('li', 'h'),
    ('ii', 'u'),
  ];
  static Map<int, List<DictEntry>>? _byLength;
  static int _rank(DictEntry e) => int.tryParse(e.lv) ?? 7;
  static bool _exact(String w) => Dict.lookup(w)?.w == w;

  static String? fix(String raw, {bool fuzzy = true}) {
    final w = raw.toLowerCase();
    // 1. 常見的辨識錯誤，一次換一處（"srnall" → "small"、"1ike" → "like"）
    for (final (from, to) in _confusions) {
      var at = w.indexOf(from);
      while (at >= 0) {
        final v = w.replaceRange(at, at + from.length, to);
        if (_exact(v)) return v;
        at = w.indexOf(from, at + from.length);
      }
    }
    // 2. 兩個字黏在一起（"inthe" → "in the"）
    if (w.length >= 5 && !w.contains(RegExp('[0-9]'))) {
      for (var i = 2; i <= w.length - 2; i++) {
        final a = w.substring(0, i), b = w.substring(i);
        final ea = Dict.lookup(a), eb = Dict.lookup(b);
        if (ea?.w == a && eb?.w == b && _rank(ea!) <= 3 && _rank(eb!) <= 4)
          return '$a $b';
      }
    }
    if (!fuzzy) return null;
    // 3. 編輯距離 2 以內最接近的常用字，只有一個明顯最好時才建議
    _byLength ??= () {
      final m = <int, List<DictEntry>>{};
      for (final e in Dict.all) {
        if (!e.w.contains(' ') && e.zh.isNotEmpty)
          (m[e.w.length] ??= []).add(e);
      }
      return m;
    }();
    final best = <(DictEntry, int)>[];
    for (var len = max(2, w.length - 2); len <= w.length + 2; len++) {
      for (final e in _byLength![len] ?? const <DictEntry>[]) {
        final d = distance(w, e.w.toLowerCase());
        if (d <= 2) best.add((e, d));
      }
    }
    if (best.isEmpty) return null;
    final minD = best.map((b) => b.$2).reduce(min);
    final top = best.where((b) => b.$2 == minD).toList()
      ..sort((a, b) => _rank(a.$1).compareTo(_rank(b.$1)));
    if (top.length == 1 || _rank(top[0].$1) < _rank(top[1].$1))
      return top[0].$1.w;
    return null;
  }

  /// Damerau–Levenshtein（相鄰兩個字母對調算一次）
  static int distance(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final d = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    for (var i = 0; i <= a.length; i++) {
      d[i][0] = i;
    }
    for (var j = 0; j <= b.length; j++) {
      d[0][j] = j;
    }
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        d[i][j] = min(
          min(d[i - 1][j] + 1, d[i][j - 1] + 1),
          d[i - 1][j - 1] + cost,
        );
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1])
          d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1);
      }
    }
    return d[a.length][b.length];
  }
}

// MARK: 照片變成一頁

class PageImporter {
  /// ML Kit 文字辨識（在手機上），轉成跟 iPhone 一樣的行。中文辨識器也認得英文，用來讀單字表
  static Future<List<OcrLine>> recognize(
    String path,
    double width,
    double height, {
    bool chinese = false,
  }) async {
    final recognizer = TextRecognizer(
      script: chinese
          ? TextRecognitionScript.chinese
          : TextRecognitionScript.latin,
    );
    try {
      final r = await recognizer.processImage(InputImage.fromFilePath(path));
      double r4(double v) => (v * 10000).roundToDouble() / 10000;
      final lines = <OcrLine>[];
      for (final block in r.blocks) {
        for (final line in block.lines) {
          final words = [
            for (final e in line.elements)
              TBWord(
                e.text,
                box: [
                  r4(e.boundingBox.left / width),
                  r4(e.boundingBox.top / height),
                  r4(e.boundingBox.width / width),
                  r4(e.boundingBox.height / height),
                ],
                conf: e.confidence == null
                    ? line.confidence
                    : (e.confidence! * 100).roundToDouble() / 100,
              ),
          ];
          final b = line.boundingBox;
          lines.add(
            OcrLine(
              words,
              ui.Rect.fromLTWH(
                b.left / width,
                b.top / height,
                b.width / width,
                b.height / height,
              ),
            ),
          );
        }
      }
      return lines;
    } finally {
      await recognizer.close();
    }
  }

  /// 單字表頁，或課文頁（標題、粗體字都標好）
  static Future<TBContent> read(
    String path,
    List<int> bytes,
    double w,
    double h,
  ) async {
    try {
      final vocab = VocabPage.read(await recognize(path, w, h, chinese: true));
      if (vocab != null) return vocab;
    } catch (e) {
      DevLog.add('textbook', '中文辨識失敗：$e');
    }
    final lines = await recognize(path, w, h);
    final boxes = [
      for (final l in lines)
        for (final word in l.words) word.box,
    ];
    final strokes = await compute(BoldDetector.strokes, (bytes, boxes));
    BoldDetector.mark(lines, strokes);
    return PageLayout.layout(lines);
  }

  /// 一張張辨識、整理、加進這課；到頁數上限就停。回傳加了幾頁。照片只用來辨識，不存
  static Future<int> add(
    List<String> paths,
    String lessonId,
    void Function(int done, int total) progress,
  ) async {
    final shelf = Shelf.shared;
    var added = 0;
    for (final (i, path) in paths.indexed) {
      if (shelf.pagesLeft <= 0) break;
      progress(i + 1, paths.length);
      final photo = await _upright(path);
      if (photo == null) continue;
      try {
        final content = await read(
          photo.path,
          photo.bytes,
          photo.width,
          photo.height,
        );
        final fixes = content.isVocab
            ? <TBCorrection>[]
            : OcrFixer.suggest(content);
        await shelf.addPage(lessonId, content, fixes);
        if (content.isVocab) {
          DevLog.add(
            'textbook',
            '辨識單字表：${content.entries?.length ?? 0} 個字、${content.grammar?.length ?? 0} 個文法重點',
          );
        } else {
          final bold = content.allWords.where((x) => x.$2.isBold).length;
          final titles = content.paragraphs
              .where((x) => x.style != null)
              .length;
          DevLog.add(
            'textbook',
            '辨識一頁：${content.allWords.length} 個字、${content.paragraphs.length} 段（$titles 個標題）、$bold 個粗體、${fixes.length} 個修正建議',
          );
        }
        added++;
      } catch (e) {
        DevLog.add('textbook', '辨識失敗：$e');
      } finally {
        // 轉正用的暫存照片用完就刪
        unawaited(File(photo.path).delete().then((_) {}, onError: (_) {}));
      }
    }
    if (added > 0) await shelf.markGrammar(lessonId);
    return added;
  }

  /// 照 EXIF 轉正、長邊縮到 2400 px 以內，存成暫存的 JPEG。辨識和量粗體用同一張，字的框才對得上
  static Future<({String path, List<int> bytes, double width, double height})?>
  _upright(String path) async {
    try {
      final r = await compute(_normalize, await File(path).readAsBytes());
      if (r == null) {
        DevLog.add('textbook', '照片讀不出來：$path');
        return null;
      }
      final f = File(
        '${(await getTemporaryDirectory()).path}/textbook_${_uuid()}.jpg',
      );
      await f.writeAsBytes(r.$1, flush: true);
      return (
        path: f.path,
        bytes: r.$1,
        width: r.$2.toDouble(),
        height: r.$3.toDouble(),
      );
    } catch (e) {
      DevLog.add('textbook', '照片讀不出來：$e');
      return null;
    }
  }

  static (Uint8List, int, int)? _normalize(Uint8List bytes) {
    var im = img.decodeImage(bytes);
    if (im == null) return null;
    im = img.bakeOrientation(im);
    if (max(im.width, im.height) > 2400) {
      im = im.width >= im.height
          ? img.copyResize(
              im,
              width: 2400,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              im,
              height: 2400,
              interpolation: img.Interpolation.average,
            );
    }
    return (img.encodeJpg(im, quality: 88), im.width, im.height);
  }
}
