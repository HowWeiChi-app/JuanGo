import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:juango/dictionary.dart';
import 'package:juango/models.dart';
import 'package:juango/store.dart';
import 'package:juango/word_quota.dart';

import 'harness.dart';

// 和 iOS 用同一份案例：tools/word_quota_cases.json（iOS 用 tools/word_quota_test.sh 跑）
void main() {
  setUpAll(setUpData);
  setUp(resetState);
  final cases = jsonDecode(
    File('../tools/word_quota_cases.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  test('哪些字算進 1000 個', () {
    for (final c in (cases['counts'] as List).cast<Map<String, dynamic>>()) {
      final got = WordQuota.counts(
        cefr: c['cefr'] as String,
        fromExam: c['fromExam'] as bool,
        inMyWords: c['inMyWords'] as bool,
        favorite: c['favorite'] as bool,
        inList: c['inList'] as bool,
      );
      expect(got, c['counts'], reason: c['note'] as String);
    }
  });

  test('名額不夠時只加前面的字', () {
    for (final c in (cases['fit'] as List).cast<Map<String, dynamic>>()) {
      final got = WordQuota.fit(
        (c['wanted'] as List).cast<bool>(),
        used: c['used'] as int,
        unlimited: c['unlimited'] as bool,
      );
      expect(
        got,
        (c['allowed'] as List).cast<bool>(),
        reason: c['note'] as String,
      );
    }
  });

  test('已用 x / 1000 從 900 個開始顯示', () {
    for (final c in (cases['usage'] as List).cast<Map<String, dynamic>>()) {
      expect(
        WordQuota.usage(c['used'] as int, unlimited: c['unlimited'] as bool),
        c['text'],
      );
    }
  });

  test('滿 1000 個後擋下新字，大考字和考古題的字照樣加入', () {
    final s = AppStore.shared;
    final others = Dict.all
        .where((e) => !examLevels.contains(e.lv))
        .take(1001)
        .toList();
    for (final e in others.take(1000)) {
      expect(s.add(e), isNotNull);
    }
    expect(WordQuota.used(), 1000);
    var stops = WordQuota.stops.value;
    expect(s.add(others.last), isNull);
    expect(WordQuota.stops.value, stops + 1);
    expect(s.word(others.last.w), isNull);

    final ceec = Dict.all.firstWhere(
      (e) => examLevels.contains(e.lv) && s.word(e.w) == null,
    );
    expect(s.add(ceec), isNotNull);
    expect(s.add(others.last, fromExam: true)?.fromExam, isTrue);
    expect(WordQuota.used(), 1000);

    // 已經存在的字再加一次不多佔名額
    expect(s.add(others.first), isNotNull);

    // 一批 3 個裡有 1 個大考字：只放得下大考字
    final batch = [
      Dict.all.firstWhere(
        (e) => !examLevels.contains(e.lv) && s.word(e.w) == null,
      ),
      ceec,
    ];
    expect(WordQuota.admitted(batch).map((e) => e.w), [ceec.w]);

    stops = WordQuota.stops.value;
    WordQuota.quietly(() => s.add(batch.first));
    expect(WordQuota.stops.value, stops);
  });

  test('考古題標記會寫進備份', () {
    final w = AppStore.shared.add(Dict.lookup('maintain')!, fromExam: true)!;
    expect(w.toJson()['fromExam'], isTrue);
    expect(Word.fromJson(w.toJson()).fromExam, isTrue);
    expect(Word.fromJson({'term': 'x'}).fromExam, isFalse);
  });

  test('超過上限（例如 Pro 到期）不刪任何字，只暫停新增', () {
    final s = AppStore.shared;
    final others = Dict.all
        .where((e) => !examLevels.contains(e.lv))
        .take(1004)
        .toList();
    s.restore(
      BackupFile({
        'app': 'JuanGo',
        'format': 2,
        'kind': 'backup',
        'words': [
          for (final (i, e) in others.take(1003).indexed)
            (Word.fromEntry(e)
                  ..addedAt = DateTime(2026, 1, 1).add(Duration(minutes: i)))
                .toJson(),
        ],
        'lists': [],
      }),
      settings: false,
    );
    expect(WordQuota.used(), 1003);
    // 舊版留下、已經到期的刪字倒數
    s.countdown = const Countdown(overSince: 1, deleteOn: 2, lastStart: 1);
    expect(QuotaBanner.showing, isTrue);
    expect(WordQuota.hasRoom, isFalse);
    expect(WordQuota.admitted([others.last]), isEmpty);
    // 大考詞彙不佔名額，照樣可以加
    final ceec = Dict.all.firstWhere((e) => examLevels.contains(e.lv));
    expect(WordQuota.admitted([ceec]), [ceec]);
    expect(WordQuota.used(), 1003);
    expect(s.word(others.first.w), isNotNull);
    expect(s.countdown.isEmpty, isFalse);
  });
}
