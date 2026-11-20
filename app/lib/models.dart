// 資料模型和學習規則：間隔複習、題型、統計、成就都照 iOS 版（Core.swift、StudyTab.swift、Examples.swift）。

import 'dart:math';

final rng = Random();

DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);
bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

const weekdayNames = ['一', '二', '三', '四', '五', '六', '日'];
String monthDay(DateTime d) => '${d.month}月${d.day}日';
String monthDayWeek(DateTime d) => '${monthDay(d)} 週${weekdayNames[d.weekday - 1]}';
String monthDayWeekFull(DateTime d) => '${monthDay(d)} 星期${weekdayNames[d.weekday - 1]}';
String hourMinute(DateTime d) => '${d.hour}:${d.minute.toString().padLeft(2, '0')}';

const examLevels = ['1', '2', '3', '4', '5', '6'];
const levelNames = ['未學', '初見', '認得', '熟悉', '穩固', '精通'];
const cefrToExam = {'A1': '1', 'A2': '2', 'B1': '3', 'B2': '4', 'C1': '5', 'C2': '6'};
String levelLabel(String lv) => examLevels.contains(lv) ? '第$lv級' : lv;
String levelName(int level) => levelNames[level.clamp(0, 5)];

/// 什麼時候到期，用天數講（複習都排在一天的開始）
String dueText(DateTime due) {
  final now = DateTime.now();
  if (!due.isAfter(now)) return '已到期';
  final d = startOfDay(due).difference(startOfDay(now)).inHours ~/ 24;
  return d <= 0 ? '今天' : d == 1 ? '明天' : d == 2 ? '後天' : '$d 天後';
}

class DictEntry {
  DictEntry({
    required this.w,
    this.ipa = '',
    this.pos = '',
    this.zh = const [],
    this.def = '',
    this.ex = '',
    this.exZh = '',
    this.lv = '—',
    this.alt = const [],
    this.tags = const [],
    this.sim = const [],
  });

  factory DictEntry.fromJson(Map<String, dynamic> j) => DictEntry(
        w: j['w'] as String,
        ipa: j['ipa'] as String? ?? '',
        pos: j['pos'] as String? ?? '',
        zh: (j['zh'] as List?)?.cast<String>() ?? const [],
        def: j['def'] as String? ?? '',
        ex: j['ex'] as String? ?? '',
        exZh: j['exZh'] as String? ?? '',
        lv: j['lv'] as String? ?? '—',
        alt: (j['alt'] as List?)?.cast<String>() ?? const [],
        tags: (j['tags'] as List?)?.cast<String>() ?? const [],
        sim: (j['sim'] as List?)?.cast<String>() ?? const [],
      );

  factory DictEntry.custom(String term, String meaning) =>
      DictEntry(w: term.toLowerCase(), zh: meaning.isEmpty ? const [] : [meaning]);

  String w, ipa, pos, def, ex, exZh, lv;
  List<String> zh;
  final List<String> alt, tags, sim;

  /// "v./(n.)" → ["v.", "n."]
  late final List<String> posTags = posTagsOf(pos);
}

List<String> posTagsOf(String pos) => pos
    .split('/')
    .map((s) => s.replaceAll(RegExp(r'^[() ]+|[() ]+$'), ''))
    .where((s) => s.isNotEmpty)
    .toList();

class Word {
  Word({
    required this.term,
    this.ipa = '',
    this.pos = '',
    List<String>? meanings,
    this.definition = '',
    this.example = '',
    this.exampleZh = '',
    this.cefr = '—',
    this.srsLevel = 0,
    this.dueDate,
    this.lastReviewed,
    DateTime? addedAt,
    this.favorite = false,
    this.inMyWords = true,
    this.reviewCount = 0,
    this.fromExam = false,
    Set<int>? lists,
  })  : meanings = meanings ?? [],
        addedAt = addedAt ?? DateTime.now(),
        lists = lists ?? {};

  factory Word.fromEntry(DictEntry e, {List<String>? meanings}) => Word(
        term: e.w,
        ipa: e.ipa,
        pos: e.pos,
        meanings: List.of(meanings ?? e.zh),
        definition: e.def,
        example: e.ex,
        exampleZh: e.exZh,
        cefr: e.lv,
      );

  factory Word.fromJson(Map<String, dynamic> j) => Word(
        term: j['term'] as String,
        ipa: j['ipa'] as String? ?? '',
        pos: j['pos'] as String? ?? '',
        meanings: (j['meanings'] as List?)?.cast<String>().toList(),
        definition: j['definition'] as String? ?? '',
        example: j['example'] as String? ?? '',
        exampleZh: j['exampleZh'] as String? ?? '',
        cefr: j['cefr'] as String? ?? '—',
        srsLevel: j['srsLevel'] as int? ?? 0,
        dueDate: parseDate(j['dueDate']),
        lastReviewed: parseDate(j['lastReviewed']),
        addedAt: parseDate(j['addedAt']),
        favorite: j['favorite'] as bool? ?? false,
        inMyWords: j['inMyWords'] as bool? ?? true,
        reviewCount: j['reviewCount'] as int? ?? 0,
        fromExam: j['fromExam'] as bool? ?? false,
        lists: (j['lists'] as List?)?.cast<int>().toSet(),
      );

  String term, ipa, pos, definition, example, exampleZh, cefr;
  List<String> meanings;
  int srsLevel, reviewCount;
  DateTime? dueDate, lastReviewed;
  DateTime addedAt;
  bool favorite, inMyWords;

  /// 考古題答錯加入的字，不算進免費版 1000 個
  bool fromExam;

  /// 這個字屬於哪些自訂清單（WordList.id）
  Set<int> lists;

  String get primaryMeaning => meanings.isEmpty ? '—' : meanings.first;
  String get meaningLine => meanings.join(' · ');
  bool get isNew => srsLevel == 0;
  bool get isDue => !isNew && !(dueDate ?? DateTime(1970)).isAfter(DateTime.now());
  bool get isMastered => srsLevel >= 5;
  bool get studyable => inMyWords || lists.isNotEmpty;

  /// 例句挖空；例句裡沒有這個字時是 null
  String? get clozeSentence => WordMatch.cloze(term, example);

  DictEntry toEntry() => DictEntry(
      w: term, ipa: ipa, pos: pos, zh: List.of(meanings), def: definition, ex: example, exZh: exampleZh, lv: cefr);

  Map<String, dynamic> toJson() => {
        'term': term,
        'ipa': ipa,
        'pos': pos,
        'meanings': meanings,
        'definition': definition,
        'example': example,
        'exampleZh': exampleZh,
        'cefr': cefr,
        'srsLevel': srsLevel,
        'dueDate': dateJson(dueDate),
        'lastReviewed': dateJson(lastReviewed),
        'addedAt': dateJson(addedAt),
        'favorite': favorite,
        'inMyWords': inMyWords,
        'reviewCount': reviewCount,
        if (fromExam) 'fromExam': true,
        'lists': lists.toList(),
      };
}

/// iOS 的備份用 ISO 8601（到秒、UTC），這裡輸出同樣的格式，兩邊的備份才能互相還原
String? dateJson(DateTime? d) {
  if (d == null) return null;
  final s = d.toUtc().toIso8601String();
  return '${s.split('.').first.replaceAll('Z', '')}Z';
}

DateTime? parseDate(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

class WordList {
  WordList({required this.id, required this.name, DateTime? createdAt}) : createdAt = createdAt ?? DateTime.now();
  factory WordList.fromJson(Map<String, dynamic> j) =>
      WordList(id: j['id'] as int, name: j['name'] as String, createdAt: parseDate(j['createdAt']));

  final int id;
  String name;
  DateTime createdAt;

  static const builtInNames = {'我的單字', '喜歡'};
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'createdAt': dateJson(createdAt)};
}

class ReviewLog {
  ReviewLog({required this.term, required this.result, required this.wasNew, DateTime? date})
      : date = date ?? DateTime.now();
  factory ReviewLog.fromJson(Map<String, dynamic> j) => ReviewLog(
      term: j['term'] as String,
      result: j['result'] as int,
      wasNew: j['wasNew'] as bool? ?? false,
      date: parseDate(j['date']));

  String term;
  final DateTime date;

  /// 0 不會、1 不確定、2 會
  final int result;
  final bool wasNew;
  Map<String, dynamic> toJson() => {'term': term, 'date': dateJson(date), 'result': result, 'wasNew': wasNew};
}

enum Deck {
  recommended('為你精選', '依你的程度推薦', examLevels, null),
  basic('基礎 2000', '大考詞彙第 1–2 級', ['1', '2'], null),
  middle('進階 4000', '大考詞彙第 3–4 級', ['3', '4'], null),
  advanced('學測 6000+', '大考詞彙第 5–6 級', ['5', '6'], null),
  elementary('國中小 1200', '教育部國中小基本字彙', [], 'elem'),
  toeic('多益 TOEIC', '職場與生活常用字', [], 'toeic'),
  ielts('雅思 IELTS', '雅思考試常見字', [], 'ielts'),
  toefl('托福 TOEFL', '托福考試常見字', [], 'toefl');

  const Deck(this.label, this.subtitle, this.levels, this.tag);
  final String label, subtitle;
  final List<String> levels;
  final String? tag;

  bool contains(DictEntry e) => tag != null ? e.tags.contains(tag) : levels.contains(e.lv);

  static const examDecks = [basic, middle, advanced];
  static const testDecks = [elementary, toeic, ielts, toefl];
}

enum Grade {
  again('不會'),
  unsure('不確定'),
  good('會');

  const Grade(this.label);
  final String label;
}

class SRS {
  /// 升到第 n 級之後幾天再複習
  static const intervals = [0, 1, 2, 4, 7, 15, 30];

  static void apply(Grade g, Word w, [DateTime? at]) {
    final now = at ?? DateTime.now();
    switch (g) {
      case Grade.good:
        final wasMastered = w.srsLevel >= 5;
        w.srsLevel = min(5, w.srsLevel + 1);
        w.dueDate = _day(wasMastered ? intervals[6] : intervals[w.srsLevel], now);
      case Grade.unsure:
        w.srsLevel = max(1, w.srsLevel);
        w.dueDate = _day(1, now);
      case Grade.again:
        w.srsLevel = max(1, w.srsLevel - 1);
        w.dueDate = now.add(const Duration(minutes: 20));
    }
    w.lastReviewed = now;
    w.reviewCount += 1;
  }

  /// 到期時間排在當天開始：晚上十點學的字，隔天早上就等著你
  static DateTime _day(int days, DateTime now) => startOfDay(now.add(Duration(days: days)));
}

enum QType {
  flashcard('翻卡片', '認得'),
  enToZh('英翻中', '認得'),
  zhToEn('中翻英', '想得起來'),
  cloze('克漏字', '想得起來'),
  spelling('拼單字', '寫得出來'),
  listenZh('聽音選中文', '聽力'),
  listenEn('聽音選英文', '聽力'),
  listenSpell('聽音拼字', '聽力');

  const QType(this.label, this.group);
  final String label, group;
  static const groups = ['認得', '想得起來', '寫得出來', '聽力'];

  static QType smart(Word w, bool listening) {
    switch (w.srsLevel) {
      case 0:
      case 1:
        return flashcard;
      case 2:
        return listening && rng.nextBool() ? listenZh : enToZh;
      case 3:
        return listening && rng.nextBool() ? listenEn : zhToEn;
      case 4:
        return w.clozeSentence != null ? cloze : zhToEn;
      default:
        return listening && rng.nextBool() ? listenSpell : spelling;
    }
  }

  /// 這個字實際會用什麼題型問（片語不拼字；例句沒有這個字就不考克漏字）
  static QType fitted(QType type, Word w) {
    var t = type;
    if ((t == spelling || t == listenSpell) && WordMatch.blankParts(w.term).join(' ') != w.term) t = cloze;
    if (t == cloze && w.clozeSentence == null) t = zhToEn;
    return t;
  }
}

String reEscape(String s) => s.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\/-]'), (m) => '\\${m[0]}');

/// 在句子裡找單字，容許簡單的字形變化（use → using、keep sth alive → kept the fire alive）
class WordMatch {
  static String _lit(String s) => reEscape(s.replaceAll('’', "'")).replaceAll("'", "['’]");

  static const placeholders = {
    'sth', 'sth.', 'sb', 'sb.', "sb's", 'someone', 'something', "one's", 'oneself', 'somebody',
    '…', '...', '~', 'sb/sth', 'sth/sb',
  };

  static const _irregular = {
    'keep': ['kept'], 'take': ['took', 'taken'], 'make': ['made'], 'give': ['gave', 'given'],
    'get': ['got', 'gotten'], 'come': ['came'], 'go': ['went', 'gone'], 'bring': ['brought'],
    'think': ['thought'], 'find': ['found'], 'hold': ['held'], 'run': ['ran'], 'see': ['saw', 'seen'],
    'tell': ['told'], 'say': ['said'], 'leave': ['left'], 'feel': ['felt'], 'stand': ['stood'],
    'fall': ['fell', 'fallen'], 'break': ['broke', 'broken'], 'catch': ['caught'], 'buy': ['bought'],
    'teach': ['taught'], 'lose': ['lost'], 'pay': ['paid'], 'lay': ['laid'], 'lead': ['led'],
    'send': ['sent'], 'spend': ['spent'], 'build': ['built'], 'write': ['wrote', 'written'],
    'speak': ['spoke', 'spoken'], 'drive': ['drove', 'driven'], 'rise': ['rose', 'risen'],
    'grow': ['grew', 'grown'], 'know': ['knew', 'known'], 'throw': ['threw', 'thrown'],
    'show': ['showed', 'shown'], 'wear': ['wore', 'worn'], 'tear': ['tore', 'torn'],
    'choose': ['chose', 'chosen'], 'begin': ['began', 'begun'], 'drink': ['drank', 'drunk'],
    'sing': ['sang', 'sung'], 'swim': ['swam', 'swum'], 'fly': ['flew', 'flown'], 'draw': ['drew', 'drawn'],
    'eat': ['ate', 'eaten'], 'forget': ['forgot', 'forgotten'], 'hide': ['hid', 'hidden'],
    'ride': ['rode', 'ridden'], 'shake': ['shook', 'shaken'], 'steal': ['stole', 'stolen'],
    'wake': ['woke', 'woken'], 'sell': ['sold'], 'seek': ['sought'], 'fight': ['fought'],
    'sleep': ['slept'], 'meet': ['met'], 'sit': ['sat'], 'win': ['won'], 'hang': ['hung'],
    'dig': ['dug'], 'stick': ['stuck'], 'strike': ['struck'], 'lend': ['lent'], 'bend': ['bent'],
    'feed': ['fed'], 'hear': ['heard'], 'mean': ['meant'], 'deal': ['dealt'], 'light': ['lit'],
  };

  static final _cache = <String, RegExp?>{};

  static RegExp? pattern(String term) => _cache.putIfAbsent(term, () {
        final parts = term.toLowerCase().split(' ').where((s) => s.isNotEmpty).toList();
        if (parts.isEmpty) return null;
        final first = parts.first;
        var forms = ['${_lit(first)}\\w*'];
        if (first.length >= 3 && first.endsWith('e')) {
          forms.add('${_lit(first.substring(0, first.length - 1))}(?:ing|ion|ions|able)\\b');
        }
        if (first.length >= 3 && first.endsWith('y')) {
          forms.add('${_lit(first.substring(0, first.length - 1))}i(?:ed|es|er|est|ly|ness|ful)\\b');
        }
        forms.addAll((_irregular[first] ?? const []).map((p) => '${reEscape(p)}\\b'));
        if (first == 'be') forms = ['be', 'is', 'am', 'are', 'was', 'were', 'been', 'being', "'s", "'re", "'m"];
        final rest = parts.skip(1).map((p) => placeholders.contains(p) ? "((?:\\s+[\\w'’-]+){1,3}?)" : '\\s+${_lit(p)}').join();
        return RegExp('\\b(?:${forms.join('|')})$rest${parts.length > 1 ? r'\w*' : ''}', caseSensitive: false);
      });

  static bool found(String term, String sentence) => pattern(term)?.hasMatch(sentence) ?? false;

  /// 克漏字：單字本身變成空格，代表 sth / sb 的部分留著
  static String? cloze(String term, String sentence) {
    final p = pattern(term);
    if (p == null || !p.hasMatch(sentence)) return null;
    return sentence.replaceAllMapped(p, (m) {
      final out = StringBuffer();
      var group = 0, lastBlank = false;
      for (final part in term.toLowerCase().split(' ').where((s) => s.isNotEmpty)) {
        if (placeholders.contains(part) && out.isNotEmpty) {
          group += 1;
          out.write(m[group] ?? '');
          lastBlank = false;
        } else if (!lastBlank) {
          out.write(out.isEmpty ? '____' : ' ____');
          lastBlank = true;
        }
      }
      return out.toString();
    });
  }

  /// 空格對應的片段："keep sth alive" → ["keep", "alive"]
  static List<String> blankParts(String term) {
    final parts = <List<String>>[[]];
    final words = term.split(' ').where((s) => s.isNotEmpty).toList();
    for (var i = 0; i < words.length; i++) {
      if (i > 0 && placeholders.contains(words[i].toLowerCase())) {
        if (parts.last.isNotEmpty) parts.add([]);
      } else {
        parts.last.add(words[i]);
      }
    }
    return parts.where((p) => p.isNotEmpty).map((p) => p.join(' ')).toList();
  }
}

/// 主頁和「我的」顯示的數字，一次算完
class Stats {
  Stats(List<ReviewLog> logs, List<Word> words) {
    final now = DateTime.now(), today = startOfDay(now);
    final termsByDay = <DateTime, Set<String>>{};
    final newTerms = <String>{};
    for (final l in logs) {
      final d = startOfDay(l.date);
      (termsByDay[d] ??= {}).add(l.term);
      if (d == today && l.wasNew) newTerms.add(l.term);
    }
    activeDays = termsByDay.keys.toSet();
    _perDay = {for (final e in termsByDay.entries) e.key: e.value.length};
    newToday = newTerms.length;
    studiedToday = termsByDay[today]?.length ?? 0;
    var day = activeDays.contains(today) ? today : addDays(today, -1);
    while (activeDays.contains(day)) {
      streak += 1;
      day = addDays(day, -1);
    }
    wordCount = words.length;
    for (final w in words) {
      if (w.srsLevel > 0) learnedTotal += 1;
      if (w.isMastered) masteredTotal += 1;
      if (w.isDue) dueCount += 1;
      if (w.srsLevel >= 0 && w.srsLevel <= 5) distribution[w.srsLevel] += 1;
    }
  }

  late final Set<DateTime> activeDays;
  late final Map<DateTime, int> _perDay;
  int streak = 0, newToday = 0, studiedToday = 0, learnedTotal = 0, masteredTotal = 0, dueCount = 0, wordCount = 0;
  final distribution = List.filled(6, 0);

  int count(DateTime day) => _perDay[startOfDay(day)] ?? 0;
}

class BadgeKind {
  const BadgeKind(this.id, this.title, this.tiers);
  final String id, title;
  final List<int> tiers;

  int next(int value) => tiers.firstWhere((t) => t > value, orElse: () => tiers.last);
  int earned(int value) => tiers.where((t) => value >= t).length;

  int value(Stats s) => switch (id) {
        'streak' => s.streak,
        'imported' => s.wordCount,
        'learned' => s.learnedTotal,
        _ => s.masteredTotal,
      };

  static const all = [
    BadgeKind('streak', '連續天數', [3, 7, 30, 100, 365]),
    BadgeKind('imported', '匯入單字', [100, 500, 1000, 3000]),
    BadgeKind('learned', '學過單字', [100, 500, 1000, 3000]),
    BadgeKind('mastered', '學會單字', [10, 50, 200, 1000]),
  ];
}
