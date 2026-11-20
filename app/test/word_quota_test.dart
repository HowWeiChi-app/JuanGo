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
  final cases = jsonDecode(File('../tools/word_quota_cases.json').readAsStringSync()) as Map<String, dynamic>;

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
      final got = WordQuota.fit((c['wanted'] as List).cast<bool>(), used: c['used'] as int, unlimited: c['unlimited'] as bool);
      expect(got, (c['allowed'] as List).cast<bool>(), reason: c['note'] as String);
    }
  });

  test('已用 x / 1000 從 900 個開始顯示', () {
    for (final c in (cases['usage'] as List).cast<Map<String, dynamic>>()) {
      expect(WordQuota.usage(c['used'] as int, unlimited: c['unlimited'] as bool), c['text']);
    }
  });

  test('滿 1000 個後擋下新字，大考字和考古題的字照樣加入', () {
    final s = AppStore.shared;
    final others = Dict.all.where((e) => !examLevels.contains(e.lv)).take(1001).toList();
    for (final e in others.take(1000)) {
      expect(s.add(e), isNotNull);
    }
    expect(WordQuota.used(), 1000);
    var stops = WordQuota.stops.value;
    expect(s.add(others.last), isNull);
    expect(WordQuota.stops.value, stops + 1);
    expect(s.word(others.last.w), isNull);

    final ceec = Dict.all.firstWhere((e) => examLevels.contains(e.lv) && s.word(e.w) == null);
    expect(s.add(ceec), isNotNull);
    expect(s.add(others.last, fromExam: true)?.fromExam, isTrue);
    expect(WordQuota.used(), 1000);

    // 已經存在的字再加一次不多佔名額
    expect(s.add(others.first), isNotNull);

    // 一批 3 個裡有 1 個大考字：只放得下大考字
    final batch = [Dict.all.firstWhere((e) => !examLevels.contains(e.lv) && s.word(e.w) == null), ceec];
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

  test('超過上限的倒數、提醒和到期', () {
    Countdown cd(Map<String, dynamic> j) => Countdown.fromJson(j);
    for (final c in (cases['countdown'] as List).cast<Map<String, dynamic>>()) {
      final note = c['note'] as String, today = c['today'] as int;
      final got = WordQuota.countdown(cd((c['before'] as Map).cast()), used: c['used'] as int, unlimited: c['unlimited'] as bool, today: today);
      expect(got, cd((c['after'] as Map).cast()), reason: note);
      expect(WordQuota.reminder(got, today: today), c['reminder'], reason: note);
      expect(WordQuota.due(got, today: today), c['due'], reason: note);
    }
  });

  test('到期刪掉最早加入的字，同步回來的備份不會把它們帶回來', () {
    final s = AppStore.shared;
    final others = Dict.all.where((e) => !examLevels.contains(e.lv)).take(1003).toList();
    s.restore(
        BackupFile({
          'app': 'JuanGo',
          'format': 2,
          'kind': 'backup',
          'words': [
            for (final (i, e) in others.indexed)
              (Word.fromEntry(e)..addedAt = DateTime(2026, 1, 1).add(Duration(minutes: i))).toJson(),
          ],
          'lists': [],
        }),
        settings: false);
    final ceec = s.add(Dict.all.firstWhere((e) => examLevels.contains(e.lv)))!..addedAt = DateTime(2020);
    final list = s.createList('考前');
    s.word(others.first.w)!.lists.add(list.id);
    expect(WordQuota.used(), 1003);
    final cloud = s.fullBackup();

    s.countdown = Countdown(overSince: QuotaCountdown.day() - 30, deleteOn: QuotaCountdown.day(), lastStart: QuotaCountdown.day() - 30);
    expect(QuotaCountdown.doomed().map((w) => w.term), others.take(3).map((e) => e.w));
    final r = QuotaCountdown.refresh(popUps: true);
    expect(r.deleted, 3);
    expect(WordQuota.used(), 1000);
    expect(s.word(ceec.term), isNotNull);
    expect(s.lists.map((l) => l.name), contains('考前'));
    expect(s.countdown.deleteOn, isNull);

    // 雲端還是刪除前的備份：合併後也不會回來
    s.restore(BackupFile(cloud), settings: false);
    expect(s.word(others.first.w), isNull);
    expect(WordQuota.used(), 1000);
    // 刪除標記會放進備份，別台裝置收到也會刪
    expect((s.fullBackup()['removed'] as List).length, 3);
  });
}

