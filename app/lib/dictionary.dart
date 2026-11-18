// 內建字典：查字（含字形還原）、搜尋建議、相似字詞。邏輯照 iOS 版的 Dictionary_。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

List<DictEntry> _parse(String json) =>
    (jsonDecode(json) as List).map((e) => DictEntry.fromJson(e as Map<String, dynamic>)).toList();

class Dict {
  static List<DictEntry> all = const [];
  static final _index = <String, DictEntry>{};
  static final _byMeaning = <String, List<DictEntry>>{};
  static final _byLevel = <String, List<DictEntry>>{};
  static final _deckCache = <Deck, List<DictEntry>>{};
  static final byPos = <String, List<DictEntry>>{};
  static List<DictEntry> phrases = const [];

  /// 字典 3 MB，放到背景執行緒解析，開 App 時畫面才不會卡住
  static Future<void> load() async {
    final json = await rootBundle.loadString('assets/words.json');
    setEntries(await compute(_parse, json));
  }

  static void loadFromJson(String json) => setEntries(_parse(json));

  static void setEntries(List<DictEntry> list) {
    all = list;
    _index.clear();
    _byMeaning.clear();
    _byLevel.clear();
    _deckCache.clear();
    byPos.clear();
    for (final e in list) {
      _index.putIfAbsent(e.w.toLowerCase(), () => e);
      for (final z in e.zh) {
        (_byMeaning[z] ??= []).add(e);
      }
      (_byLevel[e.lv] ??= []).add(e);
      if (e.zh.isNotEmpty) (byPos[e.pos] ??= []).add(e);
    }
    for (final e in list) {
      for (final a in e.alt) {
        _index.putIfAbsent(a.toLowerCase(), () => e);
      }
    }
    phrases = list.where((e) => e.w.contains(' ') && e.zh.isNotEmpty).toList();
  }

  static List<DictEntry> entriesOfLevel(String level) => _byLevel[level] ?? const [];
  static List<DictEntry> entriesOfDeck(Deck d) => _deckCache.putIfAbsent(d, () => all.where(d.contains).toList());

  static final _edges = RegExp(r"^[\s\p{P}]+|[\s\p{P}]+$", unicode: true);

  static DictEntry? lookup(String term) {
    final t = term.toLowerCase().replaceAll("'", '’').replaceAll(_edges, '');
    final hit = _index[t] ?? _index[t.replaceAll('’', "'")];
    if (hit != null) return hit;
    final base = _irregular[t];
    if (base != null && _index[base] != null) return _index[base];
    if (t.endsWith('ies') || t.endsWith('ied')) {
      final e = _index['${t.substring(0, t.length - 3)}y'];
      if (e != null) return e;
    }
    for (final suffix in const ['s', 'es', 'ed', 'd', 'ing', 'ly', 'er', 'est']) {
      if (!t.endsWith(suffix) || t.length <= suffix.length + 2) continue;
      final stem = t.substring(0, t.length - suffix.length);
      final e = _index[stem] ?? _index['${stem}e'];
      if (e != null) return e;
      if (stem.length >= 2 && stem[stem.length - 1] == stem[stem.length - 2]) {
        final doubled = _index[stem.substring(0, stem.length - 1)]; // stopped, running
        if (doubled != null) return doubled;
      }
    }
    return null;
  }

  static bool hasChinese(String s) => s.runes.any((r) => r > 0x2E80);

  static List<DictEntry> suggestions(String query, {int limit = 8}) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return const [];
    if (hasChinese(q)) {
      final exact = all.where((e) => e.zh.any((z) => z == q || z == '$q的')).toList();
      final seen = exact.toSet();
      final partial = all.where((e) => !seen.contains(e) && e.zh.any((z) => z.contains(q)));
      return [...exact, ...partial].take(limit).toList();
    }
    final prefix = all.where((e) => e.w.toLowerCase().startsWith(q)).toList()
      ..sort((a, b) => a.w.length.compareTo(b.w.length));
    final inner = all.where((e) {
      final w = e.w.toLowerCase();
      return !w.startsWith(q) && w.contains(q);
    });
    return [...prefix, ...inner].take(limit).toList();
  }

  /// 同義字：中文意思相同的字，詞性相同的排前面
  static List<DictEntry> synonyms(String term, List<String> meanings, String pos, {int limit = 4}) {
    final tags = posTagsOf(pos).toSet();
    final score = <DictEntry, int>{};
    for (final z in meanings) {
      for (final e in _byMeaning[z] ?? const <DictEntry>[]) {
        if (e.w != term) score[e] = (score[e] ?? 0) + 1;
      }
    }
    final list = score.keys.toList()
      ..sort((a, b) {
        final pa = tags.intersection(a.posTags.toSet()).isEmpty ? 0 : 1;
        final pb = tags.intersection(b.posTags.toSet()).isEmpty ? 0 : 1;
        if (pa != pb) return pb - pa;
        if (score[a] != score[b]) return score[b]! - score[a]!;
        return a.w.compareTo(b.w);
      });
    return list.take(limit).toList();
  }

  /// 相似字詞：先用預先算好的清單，沒有才找中文意思相同的字
  static List<DictEntry> similar(String term, List<String> meanings, String pos, {int limit = 3}) {
    final listed = (lookup(term)?.sim ?? const <String>[])
        .map(lookup)
        .whereType<DictEntry>()
        .where((e) => e.w.toLowerCase() != term.toLowerCase())
        .toList();
    return (listed.isEmpty ? synonyms(term, meanings, pos, limit: limit) : listed).take(limit).toList();
  }

  static const _irregular = {
    'went': 'go', 'gone': 'go', 'was': 'be', 'were': 'be', 'been': 'be', 'is': 'be', 'are': 'be',
    'had': 'have', 'has': 'have', 'did': 'do', 'does': 'do', 'done': 'do', 'made': 'make', 'said': 'say', 'took': 'take',
    'taken': 'take', 'came': 'come', 'saw': 'see', 'seen': 'see', 'got': 'get', 'gotten': 'get', 'gave': 'give', 'given': 'give',
    'knew': 'know', 'known': 'know', 'thought': 'think', 'told': 'tell', 'found': 'find', 'left': 'leave', 'felt': 'feel',
    'brought': 'bring', 'bought': 'buy', 'began': 'begin', 'begun': 'begin', 'kept': 'keep', 'held': 'hold', 'wrote': 'write',
    'written': 'write', 'stood': 'stand', 'heard': 'hear', 'meant': 'mean', 'met': 'meet', 'ran': 'run', 'paid': 'pay',
    'sat': 'sit', 'spoke': 'speak', 'spoken': 'speak', 'led': 'lead', 'grew': 'grow', 'grown': 'grow', 'lost': 'lose',
    'fell': 'fall', 'fallen': 'fall', 'sent': 'send', 'built': 'build', 'understood': 'understand', 'drew': 'draw',
    'broke': 'break', 'broken': 'break', 'spent': 'spend', 'rose': 'rise', 'drove': 'drive', 'driven': 'drive', 'ate': 'eat',
    'eaten': 'eat', 'chose': 'choose', 'chosen': 'choose', 'wore': 'wear', 'worn': 'wear', 'children': 'child', 'men': 'man',
    'women': 'woman', 'people': 'person', 'feet': 'foot', 'teeth': 'tooth', 'mice': 'mouse', 'better': 'good', 'best': 'good',
    'worse': 'bad', 'worst': 'bad', 'taught': 'teach', 'caught': 'catch', 'fought': 'fight', 'flew': 'fly', 'slept': 'sleep',
    'threw': 'throw', 'thrown': 'throw', 'sold': 'sell', 'won': 'win', 'sang': 'sing', 'swam': 'swim', 'drank': 'drink',
    'lives': 'life', 'leaves': 'leaf', 'wives': 'wife', 'knives': 'knife', 'halves': 'half', 'shelves': 'shelf', 'wolves': 'wolf',
    'thieves': 'thief', 'loaves': 'loaf', 'geese': 'goose', 'data': 'datum', 'criteria': 'criterion', 'phenomena': 'phenomenon',
    'analyses': 'analysis', 'crises': 'crisis', 'hid': 'hide', 'hidden': 'hide', 'lay': 'lie', 'lain': 'lie', 'laid': 'lay',
    'rode': 'ride', 'ridden': 'ride', 'shook': 'shake', 'shaken': 'shake', 'stole': 'steal', 'stolen': 'steal', 'struck': 'strike',
    'swore': 'swear', 'sworn': 'swear', 'tore': 'tear', 'torn': 'tear', 'woke': 'wake', 'woken': 'wake', 'wove': 'weave',
    'bent': 'bend', 'bled': 'bleed', 'bred': 'breed', 'dealt': 'deal', 'dug': 'dig', 'fed': 'feed', 'fled': 'flee', 'hung': 'hang',
    'lent': 'lend', 'lit': 'light', 'sought': 'seek', 'shot': 'shoot', 'slid': 'slide', 'spun': 'spin', 'stuck': 'stick',
    'stung': 'sting', 'swept': 'sweep', 'swung': 'swing', 'wept': 'weep', 'wound': 'wind', 'arose': 'arise', 'arisen': 'arise',
    'forgot': 'forget', 'forgotten': 'forget', 'forgave': 'forgive', 'forgiven': 'forgive', 'froze': 'freeze', 'frozen': 'freeze',
    'mistook': 'mistake', 'mistaken': 'mistake', 'overcame': 'overcome', 'withdrew': 'withdraw', 'withdrawn': 'withdraw',
  };
}
