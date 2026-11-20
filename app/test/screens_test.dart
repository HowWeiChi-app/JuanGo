// 走過每個主要畫面：小螢幕和大螢幕都不能爆版或丟例外。
// 加上 --dart-define=SHOTS=資料夾 會順便輸出截圖，方便和 iOS 版對照。

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juango/exam.dart';
import 'package:juango/main.dart';
import 'package:juango/models.dart' show QType;
import 'package:juango/pro.dart';
import 'package:juango/settings.dart';
import 'package:juango/sheets.dart';
import 'package:juango/store.dart';
import 'package:juango/study_flow.dart';
import 'package:juango/summary.dart';
import 'package:juango/theme.dart';
import 'package:juango/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

const _shots = String.fromEnvironment('SHOTS');
final _root = GlobalKey();

Future<void> _loadFonts() async {
  Future<void> load(String family, String path) async {
    final bytes = File(path).readAsBytesSync();
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }

  const sdk = '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts';
  const cjk = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
  await load('MaterialIcons', '$sdk/MaterialIcons-Regular.otf');
  await load('Roboto', cjk);
  await load('monospace', cjk);
  await load('serif', cjk);
}

extension on WidgetTester {
  Future<void> settle([int ms = 700]) async {
    await pump();
    await pump(Duration(milliseconds: ms));
    await pump(const Duration(milliseconds: 100));
  }

  Future<void> tapText(String text) async {
    await ensureVisible(find.text(text).first);
    await pump();
    await tap(find.text(text).first, warnIfMissed: false);
    await settle();
  }

  Future<void> tapIcon(IconData icon) async {
    await tap(find.byIcon(icon).first, warnIfMissed: false);
    await settle();
  }

  // 分頁列疊在最上層，同樣的圖示取最後一個才是分頁按鈕
  Future<void> tapTab(IconData icon) async {
    await tap(find.byIcon(icon).last, warnIfMissed: false);
    await settle();
  }

  Future<void> back() async {
    await binding.handlePopRoute();
    await settle();
  }

  Future<void> shot(String name) async {
    if (_shots.isEmpty) return;
    final box = _root.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await runAsync(() async {
      final image = await box.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_shots/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }
}

Future<void> _open(WidgetTester t, Size size, {bool onboarded = true, bool dark = false}) async {
  debugDisableShadows = _shots.isEmpty;
  await t.runAsync(() => resetState(onboarded: onboarded));
  if (onboarded) seedWords();
  AppSettings.shared.appearance = dark ? 2 : 1;
  t.view
    ..devicePixelRatio = 2
    ..physicalSize = size * 2
    ..padding = const FakeViewPadding(top: 64, bottom: 40);
  addTearDown(t.view.reset);
  await t.pumpWidget(RepaintBoundary(
    key: _root,
    child: ListenableBuilder(
      listenable: AppSettings.shared,
      builder: (_, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: AppSettings.shared.themeMode,
        home: const RootView(),
      ),
    ),
  ));
  await t.settle();
}

Future<void> _close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump(const Duration(seconds: 1));
  debugDisableShadows = true;
}

void main() {
  setUpAll(() async {
    await setUpData();
    if (_shots.isNotEmpty) {
      await _loadFonts();
      Directory(_shots).createSync(recursive: true);
    }
  });

  for (final (label, size) in const [('小', Size(360, 680)), ('大', Size(412, 892))]) {
    final tag = size.width.toInt();

    testWidgets('新手導覽（$label螢幕）', (t) async {
      await _open(t, size, onboarded: false);
      await t.shot('${tag}_onboard_0_language');
      await t.tapText('18 題程度測驗・約 3 分鐘');
      await t.shot('${tag}_onboard_1_test');
      await t.tapText('不知道');
      await t.pump(const Duration(milliseconds: 300));
      await t.shot('${tag}_onboard_1_answered');
      await t.settle(1400);
      await t.tapText('略過');
      await t.shot('${tag}_onboard_2_result');
      await t.tapText('設定學習目標');
      await t.shot('${tag}_onboard_3_goal');
      await t.tapText('繼續');
      await t.shot('${tag}_onboard_4_theme');
      await t.tapText('完成並開始使用');
      expect(AppSettings.shared.onboarded, isTrue);
      expect(find.byType(MainTabs), findsOneWidget);
      await _close(t);
    });

    testWidgets('五個分頁（$label螢幕）', (t) async {
      await _open(t, size);
      await t.shot('${tag}_tab_home');
      await t.tapTab(Icons.auto_awesome_motion_rounded);
      await t.shot('${tag}_tab_explore');
      await t.tapTab(Icons.add_circle_rounded);
      await t.shot('${tag}_tab_add');
      await t.tapTab(Icons.menu_book_rounded);
      await t.shot('${tag}_tab_words');
      await t.tapText('清單');
      await t.shot('${tag}_words_lists');
      await t.tapText('內建字庫');
      await t.shot('${tag}_words_decks');
      await t.tapText('全部 10');
      await t.tapText('efficient');
      await t.shot('${tag}_word_detail');
      await t.back();
      await t.tapTab(Icons.account_circle_rounded);
      await t.shot('${tag}_tab_profile');
      await t.tapIcon(Icons.tune_rounded);
      await t.shot('${tag}_settings');
      await t.tapText('答題與發音');
      await t.shot('${tag}_settings_practice');
      await t.back();
      await t.tapText('每日提醒');
      await t.back();
      await t.tapText('完成');
      await _close(t);
    });

    testWidgets('考前倒數（$label螢幕）', (t) async {
      await _open(t, size);
      final now = DateTime.now();
      AppSettings.shared.update((x) => x
        ..examOn = true
        ..examDate = DateTime(now.year, now.month, now.day + 60));
      await t.settle();
      expect(find.text('距學測還有 60 天'), findsOneWidget);
      await t.shot('${tag}_countdown_home');
      await t.tapTab(Icons.account_circle_rounded);
      await t.tapIcon(Icons.tune_rounded);
      await t.tapText('每日計畫');
      await t.shot('${tag}_countdown_settings');
      await t.tapText('考試日期');
      await t.shot('${tag}_countdown_date');
      await t.tapText('完成');
      await t.back();
      await t.tapText('完成');
      AppSettings.shared.update((x) => x.examOn = false);
      await _close(t);
    });

    testWidgets('捲字 Pro（$label螢幕）', (t) async {
      await _open(t, size);
      await t.tapTab(Icons.account_circle_rounded);
      await t.tapIcon(Icons.tune_rounded);
      await t.tapText('捲字 Pro');
      await t.shot('${tag}_pro_settings');
      // 開發版直接是 GOs PRO，沒有購買按鈕
      if (devGosPro) {
        expect(find.text('開發版：已解鎖所有 Pro 功能'), findsOneWidget);
        await _close(t);
        return;
      }
      await t.tapText('查看 Pro 方案');
      await t.shot('${tag}_pro_paywall');
      await t.tapText('免費試用 7 天');
      expect(find.text(ProStore.notOpen), findsOneWidget);
      await t.shot('${tag}_pro_not_open');
      await _close(t);
    });

    testWidgets('考古題（$label螢幕）', (t) async {
      await _open(t, size);
      presentFull(t.element(find.byType(MainTabs)), ExamView(exam: ExamStore.all.first));
      await t.settle();
      await t.shot('${tag}_exam_menu');
      await t.tapText('詞彙題');
      await t.shot('${tag}_exam_vocab');
      await t.tapText('不知道');
      await t.shot('${tag}_exam_wrong');
      await t.tapIcon(Icons.chevron_left_rounded);
      await t.tapText('文意選填');
      await t.shot('${tag}_exam_fill');
      await t.tapIcon(Icons.chevron_left_rounded);
      await t.tapText('閱讀測驗');
      await t.shot('${tag}_exam_reading');
      await _close(t);
    });

    testWidgets('連續學習畫面（$label螢幕）', (t) async {
      await _open(t, size);
      final context = t.element(find.byType(MainTabs));
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Material(child: StreakView(stats: AppStore.shared.stats, onContinue: () {}))));
      await t.settle();
      expect(find.text('連續學習'), findsOneWidget);
      await t.shot('${tag}_streak');
      await _close(t);
    });

    testWidgets('練習一整輪（$label螢幕）', (t) async {
      await _open(t, size);
      AppSettings.shared.studyRulesSeen = true;
      final context = t.element(find.byType(MainTabs));
      startStudy(context, '今日學習', AppStore.shared.wordList);
      await t.settle();
      await t.shot('${tag}_study_setup');
      // 「不知道」的字會排回後面，所以用手動挑選的拼字題走到底：想不起來 → 翻卡片 → 會
      await t.tapText('手動挑選');
      await t.shot('${tag}_study_custom');
      await t.tapText(QType.spelling.label);
      await t.tapText(QType.flashcard.label);
      await t.tapText('開始練習');
      final seen = <String>{};
      Future<void> once(String name) async {
        if (seen.add(name)) await t.shot('${tag}_study_$name');
      }

      var finished = false;
      for (var i = 0; i < 80 && !finished; i++) {
        bool has(String text) => find.text(text).evaluate().isNotEmpty;
        if (has('這一輪完成了')) {
          await once('summary');
          finished = true;
        } else if (has('連續學習') && has('繼續')) {
          await once('streak');
          await t.tapText('繼續');
        } else if (has('下一題')) {
          await once('answered');
          await t.tapText('下一題');
        } else if (has('想不起來')) {
          await once('spelling');
          await t.tapText('想不起來');
        } else if (has('不知道')) {
          await once('choice');
          await t.tapText('不知道');
        } else if (has('會')) {
          await once('flashcard');
          await t.tapText('會');
        } else {
          await t.settle(1500);
        }
      }
      expect(finished, isTrue, reason: '這一輪沒有走到總結頁');
      await t.tapText('結束');
      expect(find.text('這一輪完成了'), findsNothing);
      await _close(t);
    });

    testWidgets('彈出視窗（$label螢幕）', (t) async {
      await _open(t, size);
      final context = t.element(find.byType(MainTabs));
      showWordConfirm(context, 'maintain');
      await t.settle();
      await t.shot('${tag}_sheet_word');
      await t.back();
      showAddToList(context, (_) {});
      await t.settle();
      await t.shot('${tag}_sheet_list');
      await t.back();
      showTimeWheel(context, 20 * 60 + 30, (_) {});
      await t.settle();
      await t.shot('${tag}_sheet_time');
      await t.tapText('完成');
      showWordDetail(context, AppStore.shared.word('maintain')!);
      await t.settle();
      await t.shot('${tag}_sheet_detail');
      await t.back();
      confirmAction(context, '刪除 3 個單字？', message: '這些字的學習進度會一起刪除；每天的練習紀錄會保留。', label: '刪除', onConfirm: () {});
      await t.settle();
      await t.shot('${tag}_alert');
      await t.back();
      await _close(t);
    });
  }

  testWidgets('深色模式', (t) async {
    await _open(t, const Size(412, 892), dark: true);
    await t.shot('dark_home');
    await t.tapTab(Icons.account_circle_rounded);
    await t.shot('dark_profile');
    await _close(t);
  });
}
