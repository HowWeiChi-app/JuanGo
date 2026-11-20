// 使用者的資料：單字、清單、學習紀錄。整份存成 App 資料夾裡的一個 JSON 檔。
// 備份檔的格式和 iOS 版相同，兩邊可以互相匯入。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'dictionary.dart';
import 'models.dart';
import 'settings.dart';
import 'word_quota.dart';

class AppStore extends ChangeNotifier {
  AppStore._();
  static AppStore shared = AppStore._();

  /// 測試用：換一份乾淨的資料，不碰檔案
  @visibleForTesting
  static void resetForTest() => shared = AppStore._();

  final _byTerm = <String, Word>{};
  final lists = <WordList>[];

  /// 依時間由舊到新
  final logs = <ReviewLog>[];

  /// 因為免費版上限被刪掉的字和刪除時間；放進備份，同步時才不會從雲端或別台裝置再帶回來
  final removed = <String, DateTime>{};

  /// 超過上限的倒數
  var countdown = Countdown();

  File? _file;
  Timer? _timer;
  Stats? _stats;
  int _nextListId = 1;

  Iterable<Word> get words => _byTerm.values;
  List<Word> get wordList => _byTerm.values.toList(growable: false);
  Word? word(String term) => _byTerm[term.toLowerCase()];
  Stats get stats => _stats ??= Stats(logs, wordList);
  Iterable<Word> get studyable => words.where((w) => w.studyable);
  List<Word> wordsIn(WordList l) => words.where((w) => w.lists.contains(l.id)).toList();

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    final file = _file = File('${dir.path}/library.json');
    if (!file.existsSync()) return;
    try {
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final m in (j['words'] as List? ?? const [])) {
        final w = Word.fromJson(m as Map<String, dynamic>);
        _byTerm[w.term] = w;
      }
      for (final m in (j['lists'] as List? ?? const [])) {
        lists.add(WordList.fromJson(m as Map<String, dynamic>));
      }
      for (final m in (j['logs'] as List? ?? const [])) {
        logs.add(ReviewLog.fromJson(m as Map<String, dynamic>));
      }
      logs.sort((a, b) => a.date.compareTo(b.date));
      _readRemoved(j['removed']);
      if (j['countdown'] is Map) countdown = Countdown.fromJson((j['countdown'] as Map).cast<String, dynamic>());
      _nextListId = lists.fold(0, (n, l) => l.id > n ? l.id : n) + 1;
    } catch (e) {
      // 檔案壞掉時留一份副本，不直接蓋掉使用者的資料
      debugPrint('library.json 讀取失敗：$e');
      await file.copy('${file.path}.broken');
    }
  }

  /// 資料改變：畫面立刻更新，存檔等 0.4 秒合併（連續答題不用每次都寫檔）
  void save() {
    _stats = null;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), flush);
  }

  /// App 進背景時也會呼叫。先寫暫存檔再改名，寫到一半被關掉也不會壞
  Future<void> flush() async {
    _timer?.cancel();
    final file = _file;
    if (file == null) return;
    final data = jsonEncode({
      'words': words.map((w) => w.toJson()).toList(),
      'lists': lists.map((l) => l.toJson()).toList(),
      'logs': logs.map((l) => l.toJson()).toList(),
      'removed': _removedJson(),
      'countdown': countdown.toJson(),
    });
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(file.path);
  }

  /// 存一個字。被免費版 1000 字上限擋下時回傳 null（並跳出提示）；fromExam 的字不算，一律存
  Word? add(DictEntry e, {List<String>? meanings, WordList? list, bool myWords = true, bool fromExam = false}) {
    var w = word(e.w);
    if (!fromExam && WordQuota.takesPlace(e, w, myWords: myWords, toList: list != null) && !WordQuota.hasRoom) {
      WordQuota.stopped();
      return null;
    }
    if (w != null) {
      if (meanings != null && meanings.isNotEmpty) w.meanings = List.of(meanings);
      if (myWords) w.inMyWords = true;
    } else {
      w = Word.fromEntry(e, meanings: meanings)
        ..inMyWords = myWords
        ..fromExam = fromExam;
      _byTerm[w.term.toLowerCase()] = w;
    }
    if (list != null) w.lists.add(list.id);
    save();
    return w;
  }

  void remove(Word w) {
    _byTerm.remove(w.term.toLowerCase());
    save();
  }

  void removeAll(Iterable<Word> ws) {
    for (final w in ws.toList()) {
      _byTerm.remove(w.term.toLowerCase());
    }
    save();
  }

  /// 從「我的單字」拿掉；還在清單或喜歡裡的字要留著
  void removeFromMyWords(Word w) {
    if (w.lists.isEmpty && !w.favorite) {
      remove(w);
    } else {
      w.inMyWords = false;
      save();
    }
  }

  void toggleFavorite(Word w) {
    w.favorite = !w.favorite;
    save();
  }

  bool isNewListName(String name) {
    final n = name.trim();
    return n.isNotEmpty && !WordList.builtInNames.contains(n) && lists.every((l) => l.name != n);
  }

  WordList createList(String name, {DateTime? createdAt}) {
    final l = WordList(id: _nextListId++, name: name.trim(), createdAt: createdAt);
    lists.add(l);
    save();
    return l;
  }

  void deleteList(WordList l) {
    lists.remove(l);
    for (final w in words) {
      w.lists.remove(l.id);
    }
    save();
  }

  void addLog(ReviewLog l) => logs.add(l);
  void removeLog(ReviewLog l) => logs.remove(l);

  void resetProgress() {
    for (final w in words) {
      w.srsLevel = 0;
      w.dueDate = null;
      w.lastReviewed = null;
      w.reviewCount = 0;
    }
    logs.clear();
    save();
  }

  void wipe() {
    _byTerm.clear();
    lists.clear();
    logs.clear();
    save();
  }

  // MARK: 備份與分享清單

  /// 內建字典裡拼法完全相同的字，備份會省略和它一樣的內容
  static DictEntry? _dictionary(String term) {
    final e = Dict.lookup(term);
    return e != null && e.w == term ? e : null;
  }

  /// 備份（有進度）省略字典已有的內容和預設值，大小能少掉大半；分享的清單照舊全部寫出，舊版也讀得懂
  static Map<String, dynamic> _record(Word w, {required bool progress}) {
    final d = progress ? _dictionary(w.term) : null;
    return {
      'term': w.term,
      if (d?.ipa != w.ipa) 'ipa': w.ipa,
      if (d?.pos != w.pos) 'pos': w.pos,
      if (d == null || !listEquals(d.zh, w.meanings)) 'meanings': w.meanings,
      if (d?.def != w.definition) 'definition': w.definition,
      if (d?.ex != w.example) 'example': w.example,
      if (d?.exZh != w.exampleZh) 'exampleZh': w.exampleZh,
      if (d?.lv != w.cefr) 'cefr': w.cefr,
      if (progress) ...{
        'srsLevel': w.srsLevel,
        if (w.dueDate != null) 'dueDate': dateJson(w.dueDate),
        if (w.lastReviewed != null) 'lastReviewed': dateJson(w.lastReviewed),
        'addedAt': dateJson(w.addedAt),
        if (w.favorite) 'favorite': true,
        if (!w.inMyWords) 'inMyWords': false,
        if (w.fromExam) 'fromExam': true,
        'reviewCount': w.reviewCount,
      },
    };
  }

  Map<String, dynamic> fullBackup() {
    final sorted = wordList..sort((a, b) => a.addedAt.compareTo(b.addedAt));
    return {
      'app': 'JuanGo',
      'format': 2,
      'kind': 'backup',
      'exportedAt': dateJson(DateTime.now()),
      'words': sorted.map((w) => _record(w, progress: true)).toList(),
      'lists': lists
          .map((l) => {
                'name': l.name,
                'createdAt': dateJson(l.createdAt),
                'terms': wordsIn(l).map((w) => w.term).toList(),
              })
          .toList(),
      'logs': logs.map((l) => l.toJson()).toList(),
      'settings': AppSettings.shared.backupValues,
      if (removed.isNotEmpty) 'removed': _removedJson(),
    };
  }

  List<Map<String, dynamic>> _removedJson() =>
      [for (final e in removed.entries) {'term': e.key, 'at': dateJson(e.value)}];

  void _readRemoved(Object? raw) {
    for (final r in (raw as List? ?? const []).cast<Map<String, dynamic>>()) {
      final t = r['term'] as String?, at = parseDate(r['at']);
      if (t == null || at == null) continue;
      final had = removed[t];
      if (had == null || at.isAfter(had)) removed[t] = at;
    }
  }

  /// 免費版上限到期：刪掉這些字和它們的複習進度，清單本身留著
  void removeForQuota(List<Word> ws) {
    final now = DateTime.now();
    for (final w in ws) {
      removed[w.term] = now;
      _byTerm.remove(w.term.toLowerCase());
    }
    save();
  }

  Map<String, dynamic> listFile(String name, List<Word> ws) => {
        'app': 'JuanGo',
        'format': 1,
        'kind': 'list',
        'exportedAt': dateJson(DateTime.now()),
        'words': ws.map((w) => _record(w, progress: false)).toList(),
        'lists': [
          {'name': name, 'terms': ws.map((w) => w.term).toList()},
        ],
      };

  /// 寫到暫存資料夾，交給系統的分享選單
  Future<File> writeShareFile(Map<String, dynamic> f) async {
    final day = (f['exportedAt'] as String).substring(0, 10);
    final name = f['kind'] == 'backup'
        ? 'JuanGo 備份 $day'
        : '${((f['lists'] as List).first as Map)['name']} - JuanGo 清單';
    final safe = name.replaceAll(RegExp(r'[/\\:?*"<>|]'), '-');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$safe.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(f));
    return file;
  }

  /// 讀 JuanGo 的備份或清單檔；不是的話丟出中文訊息
  static BackupFile parseFile(String text) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {}
    return parseMap(j);
  }

  /// 備份檔和雲端的資料是同一種格式
  static BackupFile parseMap(Map<String, dynamic>? j) {
    if (j == null || j['app'] != 'JuanGo' || j['words'] is! List) {
      throw const FormatException('這不是 JuanGo 的備份或清單檔');
    }
    if ((j['format'] as int? ?? 1) > 2) throw const FormatException('這個檔案來自較新版的 JuanGo，請先更新 App');
    // 第 2 版的備份省略了字典裡就有的內容和預設值，先補回來
    for (final raw in j['words'] as List) {
      if (raw is! Map<String, dynamic>) continue;
      final d = _dictionary(raw['term'] as String? ?? '');
      if (d != null) {
        raw.putIfAbsent('ipa', () => d.ipa);
        raw.putIfAbsent('pos', () => d.pos);
        raw.putIfAbsent('meanings', () => List.of(d.zh));
        raw.putIfAbsent('definition', () => d.def);
        raw.putIfAbsent('example', () => d.ex);
        raw.putIfAbsent('exampleZh', () => d.exZh);
        raw.putIfAbsent('cefr', () => d.lv);
      }
      if (raw['addedAt'] != null) {
        raw.putIfAbsent('favorite', () => false);
        raw.putIfAbsent('inMyWords', () => true);
      }
    }
    return BackupFile(j);
  }

  /// 合併進這台裝置，不刪任何東西；同一個字保留最近複習過的進度
  /// only：分享清單裡放得進免費版上限的字（null 是全部）
  String restore(BackupFile f, {bool settings = true, Set<String>? only}) {
    final isBackup = f.isBackup;
    var added = 0, updated = 0;
    // 別台裝置因為上限刪掉的字：這裡也刪，而且不再收回來
    if (isBackup) {
      _readRemoved(f.json['removed']);
      for (final e in removed.entries) {
        final w = word(e.key);
        if (w != null && !w.addedAt.isAfter(e.value)) _byTerm.remove(w.term.toLowerCase());
      }
    }
    void applyProgress(Map<String, dynamic> r, Word w) {
      w.srsLevel = r['srsLevel'] as int? ?? w.srsLevel;
      w.dueDate = parseDate(r['dueDate']);
      w.lastReviewed = parseDate(r['lastReviewed']);
      w.reviewCount = r['reviewCount'] as int? ?? w.reviewCount;
    }

    for (final raw in f.json['words'] as List) {
      final r = raw as Map<String, dynamic>;
      final term = r['term'] as String? ?? '';
      if (term.isEmpty || (only != null && !only.contains(term))) continue;
      final gone = isBackup ? removed[term] : null;
      if (gone != null && word(term) == null && !(parseDate(r['addedAt']) ?? DateTime(1970)).isAfter(gone)) continue;
      final meanings = (r['meanings'] as List?)?.cast<String>() ?? const <String>[];
      final e = word(term);
      if (e != null) {
        if (e.meanings.isEmpty) e.meanings = List.of(meanings);
        if (e.pos.isEmpty) e.pos = r['pos'] as String? ?? '';
        if (e.definition.isEmpty) e.definition = r['definition'] as String? ?? '';
        if (e.example.isEmpty) {
          e.example = r['example'] as String? ?? '';
          e.exampleZh = r['exampleZh'] as String? ?? '';
        }
        if (e.ipa.isEmpty) e.ipa = r['ipa'] as String? ?? '';
        final theirs = parseDate(r['lastReviewed']) ?? DateTime(1970);
        if (isBackup && theirs.isAfter(e.lastReviewed ?? DateTime(1970))) {
          applyProgress(r, e);
          updated += 1;
        }
        if (r['favorite'] == true) e.favorite = true;
        if (isBackup && r['fromExam'] == true) e.fromExam = true;
        if (r['inMyWords'] == true || !isBackup) e.inMyWords = true;
      } else {
        final w = Word(
          term: term,
          ipa: r['ipa'] as String? ?? '',
          pos: r['pos'] as String? ?? '',
          meanings: List.of(meanings),
          definition: r['definition'] as String? ?? '',
          example: r['example'] as String? ?? '',
          exampleZh: r['exampleZh'] as String? ?? '',
          cefr: r['cefr'] as String? ?? '—',
        );
        if (isBackup) {
          applyProgress(r, w);
          w.addedAt = parseDate(r['addedAt']) ?? w.addedAt;
          w.favorite = r['favorite'] as bool? ?? false;
          w.inMyWords = r['inMyWords'] as bool? ?? true;
          w.fromExam = r['fromExam'] as bool? ?? false;
        }
        _byTerm[term.toLowerCase()] = w;
        added += 1;
      }
    }

    for (final raw in f.json['lists'] as List? ?? const []) {
      final r = raw as Map<String, dynamic>;
      final name = r['name'] as String? ?? '';
      final terms = (r['terms'] as List?)?.cast<String>() ?? const <String>[];
      if (WordList.builtInNames.contains(name)) {
        for (final t in terms) {
          final w = word(t);
          if (w == null) continue;
          if (name == '喜歡') {
            w.favorite = true;
          } else {
            w.inMyWords = true;
          }
        }
        continue;
      }
      final matches = lists.where((l) => l.name == name);
      final l = matches.isNotEmpty ? matches.first : createList(name, createdAt: parseDate(r['createdAt']));
      for (final t in terms) {
        if (only != null && !only.contains(t)) continue;
        word(t)?.lists.add(l.id);
      }
    }

    var logCount = 0;
    final incoming = f.json['logs'] as List?;
    if (incoming != null && incoming.isNotEmpty) {
      String key(String t, DateTime d) => '$t|${d.millisecondsSinceEpoch ~/ 1000}';
      final have = logs.map((l) => key(l.term, l.date)).toSet();
      for (final raw in incoming) {
        final l = ReviewLog.fromJson(raw as Map<String, dynamic>);
        if (have.add(key(l.term, l.date))) {
          logs.add(l);
          logCount += 1;
        }
      }
      logs.sort((a, b) => a.date.compareTo(b.date));
    }

    final s = f.json['settings'];
    if (isBackup && settings && s is Map<String, dynamic>) AppSettings.shared.applyBackup(s);
    save();

    return [
      '新增 $added 個單字',
      if (updated > 0) '更新 $updated 個字的進度',
      if (logCount > 0) '還原 $logCount 筆複習紀錄',
      if (!isBackup && f.listName != null) '加入清單「${f.listName}」',
    ].join('，');
  }
}

class BackupFile {
  BackupFile(this.json);
  final Map<String, dynamic> json;

  bool get isBackup => json['kind'] == 'backup';
  int get wordCount => (json['words'] as List).length;
  int get listCount => (json['lists'] as List? ?? const []).length;
  int get logCount => (json['logs'] as List? ?? const []).length;
  String? get listName {
    final l = json['lists'] as List?;
    return l == null || l.isEmpty ? null : (l.first as Map)['name'] as String?;
  }

  String get title {
    if (!isBackup) return '單字清單「${listName ?? '未命名'}」';
    final d = parseDate(json['exportedAt']);
    return d == null ? 'JuanGo 備份' : 'JuanGo 備份（${d.year}/${d.month}/${d.day} ${hourMinute(d)}）';
  }

  String get summary => [
        '$wordCount 個單字',
        if (listCount > 0) '$listCount 個清單',
        if (logCount > 0) '$logCount 筆複習紀錄',
      ].join('、');
}
