import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:juango/dictionary.dart';
import 'package:juango/exam.dart';
import 'package:juango/models.dart';
import 'package:juango/onboarding.dart';
import 'package:juango/store.dart';
import 'package:juango/study_flow.dart';

import 'harness.dart';

void main() {
  setUpAll(setUpData);
  setUp(resetState);

  test('字典和 iOS 共用同一份資料', () {
    expect(Dict.all.length, greaterThan(5000));
    expect(Dict.lookup('resilience'), isNotNull);
    for (final lv in examLevels) {
      expect(Dict.entriesOfLevel(lv), isNotEmpty, reason: '第$lv級');
    }
  });

  test('間隔複習：答對升級、答錯降級但不回到未學', () {
    final w = AppStore.shared.add(Dict.lookup('maintain')!)!;
    SRS.apply(Grade.good, w);
    SRS.apply(Grade.good, w);
    expect(w.srsLevel, 2);
    SRS.apply(Grade.again, w);
    expect(w.srsLevel, 1);
    SRS.apply(Grade.again, w);
    expect(w.srsLevel, 1);
    expect(w.reviewCount, 4);
  });

  test('練習流程：全部答對會結束，撤銷能退回上一題', () {
    final words = [for (final t in ['maintain', 'benefit', 'curious']) AppStore.shared.add(Dict.lookup(t)!)!];
    final e = SessionEngine(words);
    final first = e.current!.word;
    e.grade(Grade.good);
    expect(e.canUndo, isTrue);
    e.undo();
    expect(e.current!.word, first);
    expect(first.srsLevel, 0);
    for (var guard = 0; e.current != null && guard < 20; guard++) {
      e.grade(Grade.good);
    }
    expect(e.current, isNull);
    expect(e.results.length, 3);
    expect(words.every((w) => w.srsLevel == 1), isTrue);
  });

  group('程度測驗', () {
    LevelTest play(bool right) {
      final t = LevelTest();
      while (!t.isDone) {
        final item = t.current!;
        t.record(right ? item.correct : (item.correct + 1) % 4);
      }
      return t;
    }

    test('題目完整：18 題不重複、四個不同選項', () {
      final t = play(true);
      expect(t.picks.length, LevelTest.length);
      expect(t.items.map((i) => i.entry.w).toSet().length, LevelTest.length);
      for (final i in t.items) {
        expect(i.options.toSet().length, 4, reason: i.entry.w);
        expect(i.correct, inInclusiveRange(0, 3));
        if (i.kind == LevelKind.cloze) {
          expect(i.sentence, contains('______'));
          expect(i.options[i.correct], i.entry.w);
        }
      }
    });

    test('有鑑別度：全對落在高等級、全錯落在低等級', () {
      expect(int.parse(play(true).estimate), greaterThanOrEqualTo(5));
      expect(int.parse(play(false).estimate), lessThanOrEqualTo(2));
    });

    test('撤銷回到上一題，估計值也還原', () {
      final t = LevelTest();
      final before = t.estimate, first = t.current!;
      t.record(first.correct);
      t.undo();
      expect(t.picks, isEmpty);
      expect(t.estimate, before);
      expect(t.current, same(first));
    });
  });

  test('備份還原：單字、進度、清單都回得來，也能讀回 JSON', () {
    seedWords();
    final s = AppStore.shared;
    final list = s.lists.single;
    s.word('maintain')!.lists.add(list.id);
    final level = s.word('efficient')!.srsLevel;
    final text = jsonEncode(s.fullBackup());
    final count = s.words.length, logs = s.logs.length;

    AppStore.resetForTest();
    final restored = AppStore.shared;
    final file = AppStore.parseFile(text);
    expect(file.isBackup, isTrue);
    restored.restore(file, settings: false);
    expect(restored.words.length, count);
    expect(restored.logs.length, logs);
    expect(restored.word('efficient')!.srsLevel, level);
    expect(restored.word('resilience')!.favorite, isTrue);
    expect(restored.wordsIn(restored.lists.single).map((w) => w.term), ['maintain']);
  });

  test('備份省略字典裡就有的內容，還原時補回來；自己改過的意思照樣保留', () {
    final s = AppStore.shared;
    final e = Dict.all.firstWhere((e) => e.zh.isNotEmpty && e.ex.isNotEmpty && Dict.lookup(e.w)?.w == e.w);
    final mine = Dict.all.firstWhere((x) => x.w != e.w && x.zh.isNotEmpty && Dict.lookup(x.w)?.w == x.w);
    s.add(e);
    s.add(mine);
    s.word(mine.w)!.meanings = ['我自己的意思'];
    final backup = s.fullBackup();
    final words = (backup['words'] as List).cast<Map<String, dynamic>>();
    final plain = words.firstWhere((r) => r['term'] == e.w);
    expect(plain.keys, isNot(contains('meanings')));
    expect(plain.keys, isNot(contains('example')));
    expect(plain.keys, isNot(contains('inMyWords')));
    expect(words.firstWhere((r) => r['term'] == mine.w)['meanings'], ['我自己的意思']);

    final text = jsonEncode(backup);
    AppStore.resetForTest();
    final restored = AppStore.shared;
    restored.restore(AppStore.parseFile(text), settings: false);
    final w = restored.word(e.w)!;
    expect(w.meanings, e.zh);
    expect(w.example, e.ex);
    expect(w.ipa, e.ipa);
    expect(w.inMyWords, isTrue);
    expect(restored.word(mine.w)!.meanings, ['我自己的意思']);
  });

  test('壞掉的備份檔會被擋下來', () {
    expect(() => AppStore.parseFile('not json'), throwsFormatException);
    expect(() => AppStore.parseFile('{"app":"Other"}'), throwsFormatException);
  });

  test('考古題：答案都在選項範圍內，空格都對得到題號', () {
    expect(ExamStore.all, isNotEmpty);
    for (final e in ExamStore.all) {
      for (final g in e.groups) {
        for (final q in g.questions) {
          expect(q.answer, inInclusiveRange(0, g.optionsOf(q).length - 1), reason: '${e.year} 第${q.n}題');
          if (g.kind != 'reading' && g.passage != null) expect(g.passage, contains('⟨${q.n}⟩'), reason: '${e.year} 第${q.n}題');
        }
      }
    }
    final tested = ExamStore.all.first.groups.firstWhere((g) => g.kind == 'vocab').questions.first;
    expect(tested.options.any((o) => ExamStore.years(o).isNotEmpty), isTrue);
  });
}
