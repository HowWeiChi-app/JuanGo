// 課文書架：版面整理、掃錯字修正、跟 iPhone 共用的 JSON 格式、免費版上限、單字表和文法重點。
// 測試用的課文是自己寫的英文短文。

import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:juango/pro.dart';
import 'package:juango/textbook.dart';
import 'package:juango/textbook_structure.dart';

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
      await shelf.addPage(l.id, TBContent([]), []);
    }
    expect(shelf.pagesLeft, 0);
    if (pro.isPro && wasOn) await pro.setDev(ProFeature.textbook, true);
  });

  // 跟 iOS 版 Textbook.swift 的示範單字表同一份
  List<OcrLine> wordList() => [
        for (final (i, t) in const [
          'Vocabulary 生字',
          '1. bench n. 長椅',
          '2. poster n. 海報',
          '3. grateful adj. 感激的',
          '4. companion n. 同伴；伴侶',
          'Words for Recognition 一般生字',
          '5. neighborhood n. 鄰近地區',
          '6. hungry adj. 飢餓的',
          'Phrases 片語',
          '7. put up 張貼',
          '8. all the way 一路上',
          'Grammar 文法重點',
          '1. not only … but also … 不但…而且…',
          '2. so + adj. + that … 如此…以致於…',
        ].indexed)
          line(t, 0.05 + i * 0.05),
      ];

  test('單字表頁：生字、一般生字、片語和文法重點分開', () {
    final c = VocabPage.read(wordList())!;
    expect(c.isVocab, isTrue);
    final kinds = {for (final e in c.entries!) e.t: e.kind};
    expect(kinds['bench'], 'word');
    expect(kinds['neighborhood'], 'general');
    expect(kinds['put up'], 'phrase');
    expect(c.entries!.firstWhere((e) => e.t == 'companion').zh, ['同伴', '伴侶']);
    expect(c.grammar!.first.title, startsWith('not only … but also …'));
  });

  test('課文頁不會被當成單字表', () {
    expect(VocabPage.read([line('Every morning, Lily takes a walk in the park near her house.', 0.1)]), isNull);
  });

  test('課文裡標出單字表的字、片語和用到文法的句子', () {
    final list = TBPage(id: 'v', lessonId: 'l', sort: 0, content: VocabPage.read(wordList())!);
    final text = TBPage(
        id: 't',
        lessonId: 'l',
        sort: 1,
        content: PageLayout.layout([
          line('Lily decided to put up posters near the bench.', 0.10),
          line('He was not only kind but also very grateful.', 0.14),
        ]));
    final index = LessonIndex([list, text]);
    final found = index.marks(text);
    expect(found.kinds[(p: 0, s: 0, w: 5)], 'word'); // posters → poster
    expect(found.phrase.containsAll([(p: 0, s: 0, w: 3), (p: 0, s: 0, w: 4)]), isTrue); // put up
    expect(LessonIndex.forms('benches'), contains('bench'));
    final marks = GrammarMarker.ruleMarks(text, index.grammar);
    expect(marks.map((m) => (m.p, m.s)), [(0, 1)]);
    expect(marks.single.why, 'not only … but also');
  });

  test('單字表的一列：全形轉半形、去掉等級記號', () {
    final e = GlossaryParser.entries('3. pressure （n.） 壓力；壓迫 *5')!.single;
    expect(e.term, 'pressure');
    expect(e.pos, 'n.');
    expect(e.meanings, ['壓力', '壓迫']);
    expect(GlossaryParser.entries('Every morning, Lily takes a walk.'), isNull);
  });

  // 每個字都有框的一行：left 起，每個字母寬 0.012、字距 0.008；gapAfter 是第幾個字後面空很大（行號）
  OcrLine boxed(String text, double top, {double left = 0.1, double h = 0.03, int? gapAfter}) {
    var x = left;
    final words = <TBWord>[];
    for (final (i, t) in text.split(' ').indexed) {
      final w = t.length * 0.012;
      words.add(TBWord(t, box: [x, top, w, h], conf: 0.95));
      x += w + (i == gapAfter ? 0.05 : 0.008);
    }
    return OcrLine(words, Rect.fromLTWH(left, top, x - left, h));
  }

  test('濾字：註記數字、星號和記號拿掉，正常的字不動', () {
    expect(PageCleaner.strip('accompany²,'), 'accompany,');
    expect(PageCleaner.strip('deceased*'), 'deceased');
    expect(PageCleaner.strip('occasion7,'), 'occasion,');
    expect(PageCleaner.strip('“reunion8”'), '“reunion”');
    expect(PageCleaner.strip('JuanGo®'), 'JuanGo');
    expect(PageCleaner.strip('▶'), '');
    expect(PageCleaner.strip('MP3'), 'MP3');
    expect(PageCleaner.strip('14th'), '14th');
    expect(PageCleaner.strip('1519'), '1519');
  });

  test('行號拿掉、只剩標點就接回前一個字、項目符號拿掉', () {
    final l = PageCleaner.tidy(boxed('5 on end, the afterlife *.', 0.3, gapAfter: 0), 0.03)!;
    expect(l.words.map((w) => w.t).join(' '), 'on end, the afterlife.');
    expect(PageCleaner.tidy(boxed('• Twins are thought', 0.3), 0.03)!.words.first.t, 'Twins');
    // 句子裡的數字不是行號
    expect(PageCleaner.tidy(boxed('In 2008 the list grew', 0.3), 0.03)!.words.length, 5);
  });

  test('首字放大接回它的字', () {
    final cap = OcrLine([TBWord('H')], const Rect.fromLTWH(0.06, 0.10, 0.06, 0.08));
    final first = boxed('ave you ever thought about it', 0.105, left: 0.13);
    final second = boxed('to have a loved one return', 0.145, left: 0.13);
    final out = PageCleaner.joinDropCaps([cap, first, second], 0.03);
    expect(out.length, 2);
    expect(out.first.words.first.t, 'Have');
    // 拆不出來的情況（"A" "long"）保留成兩個字
    final a = OcrLine([TBWord('A')], const Rect.fromLTWH(0.06, 0.10, 0.06, 0.08));
    final out2 = PageCleaner.joinDropCaps([a, boxed('long time ago there was', 0.105, left: 0.13)], 0.03);
    expect(out2.single.words.take(2).map((w) => w.t), ['A', 'long']);
  });

  test('分塊：被切到的行、側欄的小字和 Word Bank 拿掉，課文留下', () {
    final lines = [
      for (var i = 0; i < 6; i++) boxed('Every morning Lily takes a walk in the park', 0.2 + i * 0.045, left: 0.35),
      // 側欄：比較小的字、在課文左邊自成一欄
      for (var i = 0; i < 4; i++) boxed('In Paragraph 4 a word', 0.2 + i * 0.03, left: 0.05, h: 0.02),
      // 拍到隔壁頁，被照片右邊切到
      OcrLine([TBWord('rather'), TBWord('e')], const Rect.fromLTWH(0.95, 0.3, 0.05, 0.03)),
      boxed('Word Bank spire cathedral', 0.6, left: 0.5),
    ];
    final r = PageCleaner.regions(lines, null, CleanMode.lesson);
    expect(r.keep.sublist(0, 6), everyElement(isTrue));
    expect(r.keep.sublist(6), everyElement(isFalse));
    expect(r.block.sublist(0, 6).toSet().length, 1);
    // 單字表模式只去掉被切到的行
    final list = PageCleaner.regions(lines, null, CleanMode.list);
    expect(list.keep.where((k) => !k).length, 1);
  });

  test('英文辨識器讀成亂碼的中文拿掉', () {
    final en = boxed('believe FA EA said', 0.4);
    final zh = OcrLine([TBWord('等等', box: [en.words[1].box![0], 0.4, 0.05, 0.03])], const Rect.fromLTWH(0.1, 0.4, 0.3, 0.03));
    final out = PageCleaner.dropChinese([en], [zh]);
    expect(out.single.words.map((w) => w.t), isNot(contains('FA')));
    expect(out.single.words.first.t, 'believe');
  });

  test('圖片地圖：彩色照片上的字拿掉，白紙上的字留下', () {
    final image = img.Image(width: 600, height: 800);
    img.fill(image, color: img.ColorRgb8(250, 250, 248));
    final rnd = Random(1);
    for (var y = 420; y < 800; y++) {
      for (var x = 0; x < 600; x++) {
        image.setPixelRgb(x, y, 80 + rnd.nextInt(170), 40 + rnd.nextInt(120), rnd.nextInt(200));
      }
    }
    final map = PictureMap.from(image)!;
    final onPhoto = map.around(const Rect.fromLTWH(0.3, 0.75, 0.4, 0.03), 0.018, 0.075);
    final onPaper = map.around(const Rect.fromLTWH(0.1, 0.2, 0.8, 0.03), 0.018, 0.075);
    expect(onPhoto.all!, greaterThan(0.9));
    expect(onPaper.all!, lessThan(0.1));
    final lines = [
      for (var i = 0; i < 5; i++) boxed('Every morning Lily takes a walk in the park', 0.1 + i * 0.045),
      boxed('Mexico City', 0.75, left: 0.4),
    ];
    final r = PageCleaner.regions(lines, map, CleanMode.lesson);
    expect(r.keep, [true, true, true, true, true, false]);
  });

  test('清乾淨以後重新排版：新的一塊換段、字上的記號拿掉', () {
    final lines = [
      for (final (i, t) in const ['Every morning Lily takes a walk*', 'in the park near her house2.', 'She likes to watch the birds.'].indexed)
        boxed(t, 0.2 + i * 0.045, left: 0.1),
      // 同樣大小、但隔很遠的另一塊
      boxed('Two days later an old man came.', 0.5, left: 0.1),
    ];
    final c = PageLayout.layout(PageCleaner.clean(lines, null, CleanMode.lesson));
    expect(c.paragraphs.length, 2);
    expect(c.paragraphs[0].sentences.first.words.map((w) => w.t).join(' '), 'Every morning Lily takes a walk in the park near her house.');
  });
}

