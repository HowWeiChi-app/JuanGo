// 課文書架：版面整理、掃錯字修正、跟 iPhone 共用的 JSON 格式、免費版上限。
// 測試用的課文是自己寫的英文短文。

import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:juango/pro.dart';
import 'package:juango/textbook.dart';

import 'harness.dart';

/// 把一行字變成 OcrLine：top 是這行上緣（0~1），每行高 0.03
OcrLine line(String text, double top, {double left = 0.06, double width = 0.85, double conf = 0.95}) =>
    OcrLine([for (final t in text.split(' ')) TBWord(t, conf: conf)], Rect.fromLTWH(left, top, width, 0.03));

void main() {
  setUpAll(setUpData);
  setUp(resetState);

  test('排成段落：空行換段、連字號接回去、頁碼拿掉', () {
    final c = PageLayout.layout([
      line('Every morning, Lily takes a walk in the park', 0.10),
      line('near her house. She likes to watch the impor-', 0.14),
      line('tant birds in the trees.', 0.18, width: 0.4),
      line('Two days later, an old man knocked on her door.', 0.26),
      line('12', 0.96, left: 0.48, width: 0.04),
    ]);
    expect(c.paragraphs.length, 2);
    final first = c.paragraphs[0].sentences.map((s) => s.words.map((w) => w.t).join(' ')).toList();
    expect(first, ['Every morning, Lily takes a walk in the park near her house.', 'She likes to watch the important birds in the trees.']);
    expect(c.paragraphs[1].sentences.single.words.first.t, 'Two');
    expect(c.allWords.any((w) => w.$2.t == '12'), isFalse);
  });

  test('縮排開頭的句子換段，縮寫不斷句', () {
    final c = PageLayout.layout([
      line('Mr. Brown found a dog under the bench. It was tired.', 0.10),
      line('Lily decided to put up posters around the town', 0.14, left: 0.12),
      line('and waited for the owner.', 0.18),
    ]);
    expect(c.paragraphs.length, 2);
    expect(c.paragraphs[0].sentences.first.words.map((w) => w.t).join(' '), 'Mr. Brown found a dog under the bench.');
  });

  test('字典比對：常見的辨識錯誤會建議，正確的字不會被改', () {
    expect(OcrFixer.fix('srnall'), 'small');
    expect(OcrFixer.fix('cornpanion'), 'companion');
    expect(OcrFixer.fix('1ike'), 'like');
    final c = PageLayout.layout([
      line('Every morning, Lily takes a walk in the park. She found a srnall dog', 0.10),
      line('sitting alone. It was his only cornpanion and best friend.', 0.14),
    ]);
    final fixes = OcrFixer.suggest(c);
    expect({for (final f in fixes) f.original: f.suggestion}, {'srnall': 'small', 'cornpanion': 'companion'});
    expect(fixes.every((f) => f.isPending && f.source == 'dictionary'), isTrue);
  });

  test('人名、全大寫標題、字典裡有的字都不算可疑', () {
    final c = PageLayout.layout([line('UNIT THREE: She met Lily and Brown at the station yesterday.', 0.10)]);
    expect(OcrFixer.candidates(c), isEmpty);
  });

  test('修正只在接受後套用，保留原文就回到原本的字', () {
    final c = PageLayout.layout([line('a srnall dog.', 0.1)]);
    final page = TBPage(id: 'x', lessonId: 'l', sort: 0, content: c, corrections: OcrFixer.suggest(c));
    const pos = (p: 0, s: 0, w: 1);
    expect(page.shown(pos), 'srnall');
    page.correction(pos)!.status = 'accepted';
    expect(page.shown(pos), 'small');
    expect(page.sentence(0, 0), 'a small dog.');
    page.correction(pos)!.status = 'rejected';
    expect(page.shown(pos), 'srnall');
  });

  test('JSON 格式跟 iPhone 版、supabase/textbook.sql 一樣', () {
    final c = TBContent([
      TBParagraph([TBSentence([TBWord('modem,', box: [0.1, 0.2, 0.05, 0.02], conf: 0.42)])])
    ]);
    final page = TBPage(id: 'p1', lessonId: 'l1', sort: 0, content: c, corrections: [
      TBCorrection(p: 0, s: 0, w: 0, original: 'modem', suggestion: 'modern', source: 'ai', status: 'pending'),
    ]);
    final row = jsonDecode(jsonEncode(page.toRow())) as Map<String, dynamic>;
    expect(row['content'], {
      'v': 1,
      'paragraphs': [
        {'sentences': [
          {'words': [
            {'t': 'modem,', 'box': [0.1, 0.2, 0.05, 0.02], 'conf': 0.42}
          ]}
        ]}
      ]
    });
    expect(row['corrections'], [
      {'p': 0, 's': 0, 'w': 0, 'original': 'modem', 'suggestion': 'modern', 'source': 'ai', 'status': 'pending'}
    ]);
    final back = TBPage.fromJson({...row, 'updated_at': '2026-11-21T10:00:00.123456+00:00'});
    expect(back.content.word((p: 0, s: 0, w: 0))!.core, 'modem');
    expect(back.updatedAt.toUtc().hour, 10);
  });

  test('免費版只能建 1 本書、1 課、3 頁', () async {
    final shelf = Shelf.shared..ephemeral = true;
    final pro = ProStore.shared;
    final wasOn = pro.has(ProFeature.textbook);
    if (pro.isPro) await pro.setDev(ProFeature.textbook, false);
    expect(shelf.isPro, isFalse);
    expect(shelf.canAddBook, isTrue);
    final b = shelf.addBook('示範課本', '英文');
    expect(shelf.canAddBook, isFalse);
    expect(shelf.canAddLesson, isTrue);
    final l = shelf.addLesson(b.id, 'Lesson 1');
    expect(shelf.canAddLesson, isFalse);
    for (var i = 0; i < 3; i++) {
      await shelf.addPage(l.id, TBContent([]), [], null);
    }
    expect(shelf.pagesLeft, 0);
    if (pro.isPro && wasOn) await pro.setDev(ProFeature.textbook, true);
  });
}
