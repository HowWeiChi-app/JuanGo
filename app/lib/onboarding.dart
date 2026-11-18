// 新手導覽和單字程度測驗。排版與出題規則照 iOS 版 Onboarding.swift。

import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'dictionary.dart';
import 'exam.dart';
import 'models.dart';
import 'profile_tab.dart';
import 'services.dart';
import 'settings.dart';
import 'sheets.dart';
import 'theme.dart';
import 'widgets.dart';

AppSettings get _settings => AppSettings.shared;

class OnboardingView extends StatefulWidget {
  const OnboardingView({super.key});
  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  int _page = 0;
  LevelTest _test = LevelTest();

  /// 剛點的選項（-1 是不知道），下一題出現前先顯示對錯
  int? _shown;
  Timer? _next;

  @override
  void dispose() {
    _next?.cancel();
    super.dispose();
  }

  void _go(int page) => setState(() => _page = page);

  void _restartTest() => setState(() {
        _test = LevelTest();
        _page = 1;
      });

  void _back() {
    if (_page == 1 && _test.picks.isNotEmpty && _shown == null) {
      setState(_test.undo);
      return;
    }
    _go(_page == 3 && _test.picks.isEmpty ? 0 : _page - 1);
  }

  void _finishTest() {
    if (_test.picks.isNotEmpty) {
      _settings.update((s) => s.level = _test.estimate);
      _go(2);
    } else {
      _go(3);
    }
  }

  void _choose(int i, LevelItem item) {
    if (_shown != null) return;
    setState(() => _shown = i);
    final right = i == item.correct;
    right ? Feedback2.success() : Feedback2.error();
    if (item.kind == LevelKind.meaning || right) Speech.say(item.entry.w);
    // 答錯要多留一點時間看正確答案
    _next = Timer(Duration(milliseconds: right ? 600 : 1300), () {
      if (!mounted) return;
      setState(() {
        _test.record(i < 0 ? null : i);
        _shown = null;
      });
      if (_test.isDone) _finishTest();
    });
  }

  // MARK: 各頁

  Widget _languagePage() {
    const langs = [('zh-Hant', '繁體中文'), ('en', 'English'), ('ja', '日本語'), ('ko', '한국어')];
    final p = Palette.of(context);
    return Column(children: [
      Text('選擇解釋語言', style: ts(F.title, w: w7)),
      const SizedBox(height: 22),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: StackGrid(columns: 2, spacing: 14, children: [
          for (final (code, name) in langs)
            PillButton(
              label: name,
              icon: _settings.language == code ? Icons.check_rounded : null,
              fill: _settings.language == code ? p.accent : null,
              fg: _settings.language == code ? p.onAccent : null,
              onTap: () {
                if (code == 'zh-Hant') {
                  _settings.update((s) => s.language = code);
                } else {
                  showAlert(context, '目前只支援繁體中文解釋', message: '其他語言的解釋會在之後的版本加入。');
                }
              },
            ),
        ]),
      ),
    ]);
  }

  Widget _prompt(Palette p, LevelItem item) {
    if (item.kind == LevelKind.meaning) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 120),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('選出正確的中文意思', style: ts(F.cap, w: w6, c: p.sec)),
          const SizedBox(height: 6),
          FitText(item.entry.w, style: ts(40, w: w6), alignment: Alignment.center),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (item.entry.ipa.isNotEmpty) Flexible(child: Text('/${item.entry.ipa}/', style: ts(F.foot, c: p.sec))),
            const SizedBox(width: 8),
            SpeakButton(item.entry.w, size: 16),
          ]),
        ]),
      );
    }
    return Container(
      constraints: const BoxConstraints(minHeight: 120),
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: p.hsnuNavy.withValues(alpha: .05), borderRadius: BorderRadius.circular(Radii.md)),
      child: Stack(children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('選出最適合填入空格的字', style: ts(F.cap, w: w6, c: p.sec)),
            const SizedBox(height: 8),
            Text(item.sentence, style: ts(F.title3, w: w6)),
          ]),
        ),
        Positioned(left: 0, top: 8, bottom: 8, child: Container(width: 3, color: p.hsnuNavy)),
      ]),
    );
  }

  Widget _testPage() {
    final p = Palette.of(context);
    final item = _test.current;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text('第 ${min(_test.index + 1, LevelTest.length)} 題', style: ts(F.headline, w: w6, c: p.hsnuNavy)),
          const SizedBox(width: 6),
          Text('/ ${LevelTest.length}', style: ts(F.sub, c: p.sec)),
          const Spacer(),
          Text('單字程度測驗', style: ts(F.cap, w: w7, c: p.sec)),
        ]),
        const SizedBox(height: 8),
        AnswerStrip(test: _test, live: true),
        const SizedBox(height: 18),
        if (item != null)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(position: Tween(begin: const Offset(.08, 0), end: Offset.zero).animate(a), child: child),
            ),
            layoutBuilder: (current, previous) => current ?? const SizedBox.shrink(),
            child: Column(
              key: ValueKey(_test.index),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _prompt(p, item),
                const SizedBox(height: 14),
                for (final (i, o) in item.options.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: AnswerOption(
                      letter: String.fromCharCode(65 + i),
                      text: o,
                      minHeight: 56,
                      state: _shown != null && i == item.correct
                          ? AnswerState.right
                          : _shown == i
                              ? AnswerState.wrong
                              : AnswerState.idle,
                      onTap: _shown == null ? () => _choose(i, item) : null,
                    ),
                  ),
                Tap(
                  onTap: _shown == null ? () => _choose(-1, item) : null,
                  child: SizedBox(height: 44, child: Center(child: Text('不知道', style: ts(F.sub, w: w6, c: p.sec)))),
                ),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _resultPage() {
    final p = Palette.of(context);
    return Column(children: [
      Text('你的推定程度', style: ts(F.title2, w: w7)),
      const SizedBox(height: 8),
      Text(levelLabel(_test.estimate), style: ts(64, w: w6, c: p.hsnuNavy, h: 1.15)),
      const SizedBox(height: 8),
      Text(LevelTest.blurb(_test.estimate), style: ts(F.headline, w: w6)),
      const SizedBox(height: 14),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(children: [
          AnswerStrip(test: _test, live: false),
          const SizedBox(height: 8),
          Text('答對 ${_test.correctCount} / ${_test.picks.length} 題・最高答到第${_test.hardestRight}級', style: ts(F.sub, c: p.sec)),
        ]),
      ),
      const SizedBox(height: 12),
      Text('會從接近你程度的單字開始。', style: ts(F.sub, c: p.sec)),
      Tap(
        onTap: _restartTest,
        child: SizedBox(height: 44, child: Center(child: Text('重新測驗', style: ts(F.sub, w: w6, c: p.accent)))),
      ),
    ]);
  }

  void _customGoal() => presentSheet(
        context,
        height: 320,
        (_) => ListenableBuilder(
          listenable: AppSettings.shared,
          builder: (c, _) {
            final s = _settings;
            return Padding(
              padding: const EdgeInsets.all(28),
              child: Column(children: [
                Text('自訂每日新字', style: ts(F.title2, w: w7)),
                const SizedBox(height: 20),
                Text('${s.dailyGoal} 個 / 天', style: ts(44, w: w6)),
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  CircleBtn(icon: Icons.remove_rounded, label: '減少', size: 44, onTap: s.dailyGoal > 1 ? () => s.update((x) => x.dailyGoal -= 1) : null),
                  const SizedBox(width: 18),
                  CircleBtn(icon: Icons.add_rounded, label: '增加', size: 44, onTap: s.dailyGoal < 100 ? () => s.update((x) => x.dailyGoal += 1) : null),
                ]),
                const Spacer(),
                PrimaryButton(label: '完成', width: double.infinity, onTap: () => Navigator.of(c).pop()),
              ]),
            );
          },
        ),
      );

  Widget _goalPage() {
    final p = Palette.of(context);
    final s = _settings;
    const goals = [(5, '輕鬆', ''), (10, '標準', '約 10 分鐘'), (20, '衝刺', '')];
    return Column(children: [
      Text('設定學習目標', style: ts(F.title, w: w7)),
      const SizedBox(height: 18),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          for (final (i, (n, name, sub)) in goals.indexed) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: ChoiceTile(
                selected: s.dailyGoal == n,
                onTap: () => s.update((x) => x.dailyGoal = n),
                child: SizedBox(
                  height: 96,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(name, style: ts(F.headline, w: w6)),
                    const SizedBox(height: 4),
                    Text.rich(TextSpan(children: [
                      TextSpan(text: '$n', style: ts(30, w: w6, h: 1.1)),
                      TextSpan(text: ' 個 / 天', style: ts(F.cap2)),
                    ]), maxLines: 1),
                    const SizedBox(height: 2),
                    Text(sub, maxLines: 1, style: ts(F.cap2)),
                  ]),
                ),
              ),
            ),
          ],
        ]),
      ),
      Tap(
        onTap: _customGoal,
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(const [5, 10, 20].contains(s.dailyGoal) ? '自訂數量' : '自訂數量：${s.dailyGoal} 個 / 天', style: ts(F.sub, w: w6, c: p.sec)),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: CardBox(
          padding: 4,
          child: Column(children: [
            SwitchRow(title: '學習與複習提醒', icon: Icons.notifications_rounded, value: s.reminderOn, onChanged: (v) => s.update((x) => x.reminderOn = v)),
            if (s.reminderOn)
              RowTile(
                title: '提醒時間',
                value: s.reminderText,
                onTap: () => showTimeWheel(context, s.reminderMinutes, (m) => s.update((x) => x.reminderMinutes = m)),
              ),
          ]),
        ),
      ),
    ]);
  }

  Widget _themePage() {
    final s = _settings;
    final p = Palette.of(context);
    String family(int style) => switch (style) { 2 => 'serif', 3 => 'monospace', _ => 'sans-serif' };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: Text('選擇主題', style: ts(F.title, w: w7))),
        const SizedBox(height: 14),
        Segmented<int>(items: appearanceOptions, value: s.appearance, onChanged: (v) => s.update((x) => x.appearance = v)),
        const SizedBox(height: 14),
        Text('字體', style: ts(F.headline, w: w6)),
        const SizedBox(height: 14),
        Row(children: [
          for (final (i, (v, name)) in fontOptions.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: ChoiceTile(
                selected: s.fontStyle == v,
                onTap: () => s.update((x) => x.fontStyle = v),
                child: SizedBox(
                  height: 50,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('Aa', style: ts(F.title3, w: w7).copyWith(fontFamily: family(v))),
                    Text(name, style: ts(F.cap).copyWith(fontFamily: family(v))),
                  ]),
                ),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text('主題色', style: ts(F.headline, w: w6))),
          Text(s.theme.name, style: ts(F.body, c: p.sec)),
        ]),
        const SizedBox(height: 14),
        ThemeGrid(selection: s.themeID, onSelect: (id) => s.update((x) => x.themeID = id)),
      ]),
    );
  }

  Widget _bottomBar() {
    final p = Palette.of(context);
    Widget primary(String label, VoidCallback onTap) => Expanded(child: PrimaryButton(label: label, onTap: onTap));
    return Row(children: [
      if (_page > 0) ...[
        PillButton(icon: Icons.chevron_left_rounded, width: 64, semantic: '上一步', onTap: _back),
        const SizedBox(width: 10),
      ],
      ...switch (_page) {
        0 => [
            PillButton(label: '跳過', width: 88, onTap: () => _go(3)),
            const SizedBox(width: 10),
            primary('${LevelTest.length} 題程度測驗・約 3 分鐘', _restartTest),
          ],
        1 => [
            Expanded(
              child: PillButton(
                label: '撤銷',
                fg: p.sec,
                onTap: _test.picks.isEmpty || _shown != null ? null : () => setState(_test.undo),
              ),
            ),
            const SizedBox(width: 10),
            PillButton(label: '略過', width: 88, onTap: _finishTest),
          ],
        2 => [primary('設定學習目標', () => _go(3))],
        3 => [primary('繼續', () => _go(4))],
        _ => [primary('完成並開始使用', () => _settings.update((s) => s.onboarded = true))],
      },
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final h = media.size.height;
    // 小螢幕把插圖縮小，下面的內容才放得下
    final heroHeight = _page == 1 ? 0.0 : min(_page == 4 ? 200.0 : 300.0, h * (_page == 4 ? .22 : .34));
    final heroScale = heroHeight / 300 * (_page == 4 ? 1.05 : 1);
    return PopScope(
      canPop: _page == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: ListenableBuilder(
        listenable: AppSettings.shared,
        builder: (context, _) => Padding(
          padding: EdgeInsets.only(top: media.padding.top + 8, bottom: media.padding.bottom),
          child: Column(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              height: heroHeight,
              child: ClipRect(
                child: OverflowBox(
                  maxHeight: 300,
                  minHeight: 300,
                  child: AnimatedScale(
                    scale: heroScale,
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    child: JuanHero(page: _page),
                  ),
                ),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(position: Tween(begin: const Offset(.12, 0), end: Offset.zero).animate(a), child: child),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_page),
                  child: _page == 1
                      ? _testPage()
                      : SingleChildScrollView(
                          padding: const EdgeInsets.only(top: 8, bottom: 12),
                          child: switch (_page) {
                            0 => _languagePage(),
                            2 => _resultPage(),
                            3 => _goalPage(),
                            _ => _themePage(),
                          },
                        ),
                ),
              ),
            ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: _bottomBar()),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: PageDots(count: 5, index: _page),
            ),
          ]),
        ),
      ),
    );
  }
}

class PageDots extends StatelessWidget {
  const PageDots({super.key, required this.count, required this.index});
  final int count, index;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(children: [
      for (var i = 0; i < count; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            height: 4,
            decoration: BoxDecoration(color: i <= index ? p.accent : p.sec.withValues(alpha: .3), borderRadius: BorderRadius.circular(2)),
          ),
        ),
      ],
    ]);
  }
}

/// 導覽頁上方的字典內頁：單字、音標、書籤，幾秒換一個字
class JuanHero extends StatefulWidget {
  const JuanHero({super.key, required this.page});
  final int page;
  @override
  State<JuanHero> createState() => _JuanHeroState();
}

class _JuanHeroState extends State<JuanHero> {
  static const _samples = ['situate', 'resilient', 'perspective', 'maintain', 'pivotal'];
  int _tick = 0;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2600), (_) => setState(() => _tick += 1));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final word = _samples[_tick % _samples.length];
    final e = Dict.lookup(word);
    return Center(
      child: AnimatedRotation(
        turns: (widget.page.isEven ? -2 : 2) / 360,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        child: SizedBox(
          width: 250,
          height: 214,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(
              top: 4,
              child: Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: p.card,
                  borderRadius: BorderRadius.circular(Radii.lg),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .22), blurRadius: 30, offset: const Offset(3, 5))],
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  layoutBuilder: (current, previous) => Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                  child: Column(
                    key: ValueKey(word),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 40),
                        child: FitText(word, style: ts(32, w: w7)),
                      ),
                      if (e != null) ...[
                        const SizedBox(height: 8),
                        Text('${e.pos}  /${e.ipa}/', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.cap, c: p.sec)),
                        const SizedBox(height: 8),
                        Text(e.zh.isEmpty ? '' : e.zh.first, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.title3, w: w7, c: p.accent)),
                      ],
                      const SizedBox(height: 10),
                      for (final w in const [180.0, 150.0, 110.0])
                        Container(
                          width: w,
                          height: 6,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(color: p.sec.withValues(alpha: .15), borderRadius: BorderRadius.circular(3)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(top: 0, right: 18, child: Icon(Icons.bookmark_rounded, size: 38, color: p.accent)),
          ]),
        ),
      ),
    );
  }
}

/// 測驗進度：一排答案卡方格，天藍答對、紫紅答錯或不知道，目前這題有外框
class AnswerStrip extends StatelessWidget {
  const AnswerStrip({super.key, required this.test, required this.live});
  final LevelTest test;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = live ? LevelTest.length : max(1, test.picks.length);
    return Semantics(
      label: '答對 ${test.correctCount} 題，共答 ${test.picks.length} 題',
      excludeSemantics: true,
      child: Row(children: [
        for (var i = 0; i < n; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: 16,
              decoration: BoxDecoration(
                color: i < test.picks.length ? (test.isCorrect(i) ? p.hsnuSky : p.hsnuMagenta) : p.sec.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(3),
                border: live && i == test.picks.length ? Border.all(color: p.hsnuNavy, width: 1.5) : null,
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

// MARK: 程度測驗

enum LevelKind { meaning, cloze }

class LevelItem {
  const LevelItem(this.entry, this.kind, this.sentence, this.options, this.correct);
  final DictEntry entry;
  final LevelKind kind;
  final String sentence;
  final List<String> options;
  final int correct;
  int get level => int.tryParse(entry.lv) ?? 1;
}

/// 適應性測驗：每答一題就調整能力估計（調整幅度越來越小），下一題出在估計值略上方，
/// 所以 18 題大多落在「快要不會」的邊界。干擾選項和正解同級同詞性；
/// 第 2 級以上約一半是學測式的句子填空，選項是英文。
class LevelTest {
  LevelTest() {
    final first = _item(3, const {});
    if (first != null) items.add(first);
  }

  static const length = 18;

  final items = <LevelItem>[];

  /// 每題選的選項；null 是不知道
  final picks = <int?>[];
  final _thetas = <double>[3];
  double get _theta => _thetas.last;

  int get index => picks.length;
  LevelItem? get current => index < length && index < items.length ? items[index] : null;
  bool get isDone => picks.length >= length || current == null;
  bool isCorrect(int i) => i < picks.length && picks[i] == items[i].correct;
  int get correctCount => [for (var i = 0; i < picks.length; i++) i].where(isCorrect).length;
  int get hardestRight => [
        for (var i = 0; i < picks.length; i++)
          if (isCorrect(i)) items[i].level,
      ].fold(0, max);

  void record(int? pick) {
    final item = current;
    if (item == null) return;
    picks.add(pick);
    final right = pick == item.correct;
    // 估計值等於題目等級時，答對機率約三分之二
    final p = 1 / (1 + exp(-(1.6 * (_theta - item.level) + .7)));
    final step = max(.45, 2.0 * pow(.82, picks.length - 1));
    _thetas.add((_theta + (right ? step * (1 - p) : -step * p)).clamp(.6, 6.6));
    if (picks.length >= length) return;
    final target = (_theta + .4).round().clamp(1, 6);
    final next = _item(target, items.map((i) => i.entry.w).toSet());
    if (next != null) items.add(next);
  }

  void undo() {
    if (picks.isEmpty) return;
    picks.removeLast();
    _thetas.removeLast();
    items.removeRange(min(picks.length + 1, items.length), items.length);
  }

  String get estimate => '${_theta.round().clamp(1, 6)}';

  static LevelItem? _item(int level, Set<String> avoid) {
    final pool = Dict.entriesOfLevel('$level')
        .where((e) => e.zh.isNotEmpty && e.w.length > 3 && !e.w.contains(' ') && !avoid.contains(e.w))
        .toList()
      ..shuffle(rng);
    for (final e in pool.take(30)) {
      if (level >= 2 && rng.nextBool()) {
        final s = _blanked(e);
        final o = s == null ? null : _options(e, level, true);
        if (s != null && o != null) return LevelItem(e, LevelKind.cloze, s, o.$1, o.$2);
      }
      final o = _options(e, level, false);
      if (o != null) return LevelItem(e, LevelKind.meaning, '', o.$1, o.$2);
    }
    return null;
  }

  /// 例句裡有這個字的原形時才挖空（decided 不算 decide）
  static String? _blanked(DictEntry e) {
    if (e.ex.isEmpty) return null;
    final m = WordMatch.pattern(e.w)?.firstMatch(e.ex);
    if (m == null || m[0]!.toLowerCase() != e.w.toLowerCase()) return null;
    return e.ex.replaceRange(m.start, m.end, '______');
  }

  /// 三個同級同詞性的干擾選項（不夠才找相鄰等級），意思不能和正解重疊
  static (List<String>, int)? _options(DictEntry e, int level, bool cloze) {
    String label(DictEntry d) => cloze ? d.w : d.zh.take(2).join('；');
    final tags = e.posTags.toSet(), meanings = e.zh.toSet(), mine = label(e);
    final picks = <String>[];
    for (final lv in [level, level - 1, level + 1]) {
      if (lv < 1 || lv > 6 || picks.length >= 3) continue;
      final pool = Dict.entriesOfLevel('$lv').where((o) {
        if (o.w == e.w || o.zh.isEmpty || o.w.contains(' ')) return false;
        if (!o.posTags.any(tags.contains) || o.zh.any(meanings.contains)) return false;
        if (!cloze) return true;
        return o.posTags.toSet().containsAll(tags) && tags.length == o.posTags.toSet().length && (o.w.length - e.w.length).abs() <= 3;
      }).toList()
        ..shuffle(rng);
      for (final o in pool) {
        if (picks.length >= 3) break;
        final l = label(o);
        if (l != mine && !picks.contains(l)) picks.add(l);
      }
    }
    if (picks.length != 3) return null;
    final c = rng.nextInt(4);
    picks.insert(c, mine);
    return (picks, c);
  }

  static String blurb(String lv) => switch (lv) {
        '1' => '國中基礎字，從最常用的開始',
        '2' => '累積日常生活情境的單字',
        '3' => '高一程度・校園與生活常用字',
        '4' => '高二程度・挑戰抽象詞彙',
        '5' => '高三程度・學測進階字',
        _ => '學測頂標・最難的第六級',
      };
}
