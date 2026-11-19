// 一輪練習：設定 → 答題 → 連續天數 → 總結。出題和計分規則照 iOS 版 SessionEngine。

import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'profile_tab.dart';
import 'questions.dart';
import 'services.dart';
import 'settings.dart';
import 'sheets.dart';
import 'store.dart';
import 'summary.dart';
import 'theme.dart';
import 'widgets.dart';

class StudyRequest {
  const StudyRequest(this.title, this.words);
  final String title;
  final List<Word> words;
}

class RoundResult {
  const RoundResult(this.word, this.grade);
  final Word word;
  final Grade grade;
}

Future<void> startStudy(BuildContext c, String title, List<Word> words) =>
    presentFull(c, StudyFlow(request: StudyRequest(title, words)));

class QItem {
  QItem(this.word, this.type);
  final Word word;
  final QType type;
}

class _Snapshot {
  _Snapshot(this.queue, this.pos, this.word, this.log, this.done, this.failed, this.results, this.answered)
      : level = word.srsLevel,
        due = word.dueDate,
        last = word.lastReviewed,
        count = word.reviewCount;
  final List<QItem> queue;
  final int pos, answered, level, count;
  final Word word;
  final DateTime? due, last;
  final ReviewLog? log;
  final Set<String> done, failed;
  final List<RoundResult> results;
}

class SessionEngine extends ChangeNotifier {
  SessionEngine(List<Word> words, {this.types, this.listening = false, this.endless = false, AppStore? store})
      : _pool = words,
        total = words.length,
        _store = store ?? AppStore.shared {
    queue = _draw(words);
  }

  final List<Word> _pool;
  final List<QType>? types;
  final bool listening, endless;
  final int total;
  final AppStore _store;

  late List<QItem> queue;
  int pos = 0, answered = 0;
  Set<String> done = {};
  final newLearned = <String>{};
  Set<String> _failed = {};

  /// 每個字這一輪第一次的答案，照作答順序
  List<RoundResult> results = [];
  final _undo = <_Snapshot>[];

  List<QItem> _draw(List<Word> words) => [
        for (final w in words)
          QItem(
            w,
            QType.fitted(types != null && types!.isNotEmpty ? types![rng.nextInt(types!.length)] : QType.smart(w, listening), w),
          ),
      ];

  /// 無盡模式：題目快用完時把整份字重新洗牌接上，新一輪不從剛看過的字開始
  void _refill() {
    if (!endless || _pool.isEmpty || pos < queue.length - 1) return;
    final next = List.of(_pool)..shuffle(rng);
    if (next.length > 1 && next.first.term == queue.last.word.term) {
      final t = next[0];
      next[0] = next[1];
      next[1] = t;
    }
    queue = [...queue, ..._draw(next)];
  }

  QItem? get current => pos < queue.length ? queue[pos] : null;
  bool get canUndo => _undo.isNotEmpty;
  String get progressText => endless ? '已完成 $answered 個' : '${min(total, done.length + 1)} / $total';

  void grade(Grade g) {
    final it = current;
    if (it == null) return;
    final w = it.word;
    final seen = results.any((r) => r.word.term == w.term);
    // 無盡模式一個字會出現很多次，只有第一次（或之前答錯）才算進複習排程
    final counts = !endless || !seen || _failed.contains(w.term);
    final log = counts ? ReviewLog(term: w.term, result: g.index, wasNew: w.isNew) : null;
    _undo.add(_Snapshot(List.of(queue), pos, w, log, Set.of(done), Set.of(_failed), List.of(results), answered));
    if (counts) {
      if (w.isNew) newLearned.add(w.term);
      SRS.apply(g == Grade.good && _failed.contains(w.term) ? Grade.unsure : g, w);
    }
    if (g == Grade.again) {
      _failed.add(w.term);
    } else if (endless) {
      _failed.remove(w.term);
    }
    if (!seen) results.add(RoundResult(w, g));
    if (log != null) _store.addLog(log);
    _store.save();
    if (g == Grade.again) {
      final type = it.type == QType.spelling || it.type == QType.listenSpell ? QType.flashcard : it.type;
      queue.insert(min(queue.length, pos + 4), QItem(w, type));
    } else {
      done.add(w.term);
      answered += 1;
    }
    _refill();
    pos += 1;
    notifyListeners();
  }

  void undo() {
    if (_undo.isEmpty) return;
    final s = _undo.removeLast();
    queue = s.queue;
    pos = s.pos;
    done = s.done;
    _failed = s.failed;
    results = s.results;
    answered = s.answered;
    s.word
      ..srsLevel = s.level
      ..dueDate = s.due
      ..lastReviewed = s.last
      ..reviewCount = s.count;
    if (s.level == 0) newLearned.remove(s.word.term);
    if (s.log != null) _store.removeLog(s.log!);
    _store.save();
    notifyListeners();
  }
}

enum _Phase { setup, running, streak, summary }

class StudyFlow extends StatefulWidget {
  const StudyFlow({super.key, required this.request});
  final StudyRequest request;
  @override
  State<StudyFlow> createState() => _StudyFlowState();
}

class _StudyFlowState extends State<StudyFlow> {
  var _phase = _Phase.setup;
  SessionEngine? _engine;
  bool _studiedBefore = false;
  int _lastRound = 0;
  List<RoundResult> _lastResults = const [];
  Stats? _endStats;
  late StudyRequest _order = _shuffled(widget.request.title, widget.request.words);

  StudyRequest _shuffled(String title, List<Word> words) => StudyRequest(title, List.of(words)..shuffle(rng));

  void _close() => Navigator.of(context).pop();

  void _start(List<Word> words, List<QType>? types, bool listening, bool endless) {
    _studiedBefore = AppStore.shared.stats.studiedToday > 0;
    final e = SessionEngine(words, types: types, listening: listening, endless: endless);
    e.addListener(() {
      if (e.current == null && _phase == _Phase.running) _finish(e);
    });
    setState(() {
      _engine = e;
      _phase = _Phase.running;
    });
  }

  void _finish(SessionEngine e) {
    final store = AppStore.shared;
    _endStats = Stats(store.logs, store.wordList);
    _lastRound = e.done.length;
    _lastResults = e.results;
    if (_lastRound == 0) {
      _close();
      return;
    }
    setState(() => _phase = _studiedBefore ? _Phase.summary : _Phase.streak);
  }

  @override
  void dispose() {
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = _endStats ?? AppStore.shared.stats;
    final Widget page = switch (_phase) {
      _Phase.setup => SessionSetupView(key: ValueKey(_order), request: _order, onClose: _close, onStart: _start),
      _Phase.running => SessionView(key: ValueKey(_engine), engine: _engine!, title: widget.request.title, onClose: () => _finish(_engine!)),
      _Phase.streak => StreakView(key: const ValueKey('streak'), stats: stats, onContinue: () => setState(() => _phase = _Phase.summary)),
      _Phase.summary => SummaryView(
          key: const ValueKey('summary'),
          stats: stats,
          roundCount: _lastRound,
          results: _lastResults,
          onDone: _close,
          onAgain: () => setState(() {
            _order = _shuffled(widget.request.title, widget.request.words);
            _phase = _Phase.setup;
          }),
          onRetry: (w) => setState(() {
            _order = _shuffled('答錯的字', w);
            _phase = _Phase.setup;
          }),
        ),
    };
    return AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: page);
  }
}

class SessionSetupView extends StatefulWidget {
  const SessionSetupView({super.key, required this.request, required this.onClose, required this.onStart});
  final StudyRequest request;
  final VoidCallback onClose;
  final void Function(List<Word>, List<QType>?, bool listening, bool endless) onStart;
  @override
  State<SessionSetupView> createState() => _SessionSetupViewState();
}

class _SessionSetupViewState extends State<SessionSetupView> {
  bool _smart = true, _listening = false;
  final _types = <QType>{QType.flashcard};

  /// 題數：0 全部、-1 無盡模式、其他是抽幾個（該複習的先抽）
  int _limit = 0;
  List<Word> _drawn = const [];
  Map<QType, int> _breakdown = const {};

  List<Word> get _all => widget.request.words;
  bool get _endless => _limit == -1;
  List<Word> get _words => _limit > 0 ? _drawn : _all;
  List<int> get _drawOptions => const [5, 10, 20, 30, 50].where((n) => n < _all.length).toList();

  @override
  void initState() {
    super.initState();
    final saved = AppSettings.shared.practiceLimit;
    if (saved == -1) {
      _limit = -1;
    } else if (saved > 0) {
      _limit = _drawOptions.where((n) => n <= saved).fold(0, max);
    }
    _redraw();
  }

  void _redraw() {
    final w = _all;
    final ordered = [
      ...w.where((x) => x.isDue),
      ...w.where((x) => !x.isDue && !x.isMastered),
      ...w.where((x) => !x.isDue && x.isMastered),
    ];
    _drawn = _limit > 0 ? ordered.take(_limit).toList() : const [];
    final counts = <QType, int>{};
    for (final x in _words) {
      final t = QType.fitted(QType.smart(x, false), x);
      counts[t] = (counts[t] ?? 0) + 1;
    }
    _breakdown = counts;
  }

  void _setLimit(int n) {
    AppSettings.shared.update((s) => s.practiceLimit = n);
    setState(() {
      _limit = n;
      _redraw();
    });
  }

  String get _drawLabel => switch (_limit) { 0 => '全部 ${_all.length} 個', -1 => '無盡模式', _ => '$_limit 個' };

  Widget _endlessCard(Palette p) => CardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.all_inclusive_rounded, size: 34, color: p.accent),
            const SizedBox(width: 10),
            Text('無盡模式', style: ts(34, w: w6)),
          ]),
          const SizedBox(height: 8),
          Text('從 ${_all.length} 個字裡隨機抽考，一輪考完會重新洗牌再抽，隨時按左上角結束。', style: ts(F.sub, c: p.sec)),
        ]),
      );

  Widget _smartPanel(Palette p) {
    final words = _words;
    final review = words.where((w) => !w.isNew).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_endless)
        _endlessCard(p)
      else
        CardBox(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${words.length} 個字', style: ts(34, w: w6)),
            const SizedBox(height: 6),
            Text('複習 $review・新字 ${words.length - review}・約 ${max(1, words.length ~/ 2)} 分鐘', style: ts(F.body, c: p.sec)),
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Container(height: .5, color: p.separator)),
            for (final t in QType.values)
              if (_breakdown[t] != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(children: [
                    ConstrainedBox(constraints: const BoxConstraints(minWidth: 72), child: Text(t.label, style: ts(F.sub, w: w7))),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (_, c) => Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            height: 6,
                            width: c.maxWidth * _breakdown[t]! / max(1, words.length),
                            decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(3)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${_breakdown[t]}', style: ts(F.sub, w: w7)),
                  ]),
                ),
          ]),
        ),
      const SizedBox(height: 12),
      CardBox(
        padding: 12,
        child: Row(children: [
          Icon(Icons.headphones_rounded, size: 21, color: p.accent),
          const SizedBox(width: 10),
          Expanded(child: Text('包含聽力題', style: ts(F.headline, w: w6))),
          Switch(value: _listening, onChanged: (v) => setState(() => _listening = v)),
        ]),
      ),
      const SizedBox(height: 12),
      Text('自動安排會依熟練階梯出題：初見的字翻卡片，越往上越考中翻英、克漏字和拼字。只練一部分時，該複習的字會先排進來。', style: ts(F.cap, c: p.sec)),
    ]);
  }

  Widget _customPanel(Palette p) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_endless) ...[_endlessCard(p), const SizedBox(height: 10)],
        for (final g in QType.groups) ...[
          Text(g, style: ts(F.cap, w: w7, c: p.sec)),
          const SizedBox(height: 10),
          StackGrid(children: [
            for (final t in QType.values.where((t) => t.group == g))
              ChoiceTile(
                selected: _types.contains(t),
                onTap: () => setState(() => _types.contains(t) ? _types.remove(t) : _types.add(t)),
                child: SizedBox(
                  height: 44,
                  child: Row(children: [
                    Expanded(child: FitText(t.label, style: ts(F.headline, w: w6))),
                    if (_types.contains(t)) const Icon(Icons.check_circle_rounded, size: 20),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 12),
        ],
      ]);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.request.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, w: w6, c: p.sec)),
                const SizedBox(height: 2),
                Text('本輪設定', style: ts(F.largeTitle, w: w7)),
              ]),
            ),
            CircleBtn(icon: Icons.close_rounded, label: '關閉', onTap: widget.onClose),
          ]),
          const SizedBox(height: 16),
          Segmented<bool>(
            items: const [(true, '自動安排'), (false, '手動挑選')],
            value: _smart,
            onChanged: (v) => setState(() => _smart = v),
          ),
          const SizedBox(height: 16),
          Expanded(child: SingleChildScrollView(child: _smart ? _smartPanel(p) : _customPanel(p))),
          const SizedBox(height: 12),
          MenuBtn(
            label: '題數',
            entries: () => [
              MenuEntry('全部 ${_all.length} 個', checked: _limit == 0, onTap: () => _setLimit(0)),
              for (final n in _drawOptions) MenuEntry('$n 個', checked: _limit == n, onTap: () => _setLimit(n)),
              MenuEntry('無盡模式', checked: _limit == -1, onTap: () => _setLimit(-1)),
            ],
            child: CardBox(
              padding: 14,
              child: Row(children: [
                Icon(_endless ? Icons.all_inclusive_rounded : Icons.format_list_numbered_rounded, size: 20, color: p.accent),
                const SizedBox(width: 10),
                Text('題數', style: ts(F.sub, c: p.sec)),
                const Spacer(),
                Text(_drawLabel, style: ts(F.sub, w: w7)),
                const SizedBox(width: 6),
                Icon(Icons.unfold_more_rounded, size: 16, color: p.sec),
              ]),
            ),
          ),
          const SizedBox(height: 10),
          PrimaryButton(
            label: '開始練習',
            icon: Icons.play_arrow_rounded,
            height: 54,
            onTap: _all.isEmpty || (!_smart && _types.isEmpty)
                ? null
                : () => widget.onStart(_endless ? _all : _words, _smart ? null : _types.toList(), _listening, _endless),
          ),
        ]),
      ),
    );
  }
}

class SessionView extends StatefulWidget {
  const SessionView({super.key, required this.engine, required this.title, required this.onClose});
  final SessionEngine engine;
  final String title;
  final VoidCallback onClose;
  @override
  State<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<SessionView> {
  SessionEngine get _e => widget.engine;

  @override
  void initState() {
    super.initState();
    if (!AppSettings.shared.studyRulesSeen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showRules(context);
        AppSettings.shared.update((s) => s.studyRulesSeen = true);
      });
    }
  }

  void _confirmExit() => showAlert(
        context,
        '先休息一下？',
        message: _e.endless ? '已完成 ${_e.answered} 題，答過的字都已記錄。' : '已完成的進度會保留，沒考到的字下次再練。',
        actions: [const AlertAction('繼續練', bold: true), AlertAction('離開', onTap: widget.onClose)],
      );

  void _grade(Grade g) {
    if (_e.current?.type == QType.flashcard) Feedback2.light();
    _e.grade(g);
  }

  Widget _track(Palette p) {
    if (_e.endless) {
      return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.all_inclusive_rounded, size: 18, color: p.accent),
        const SizedBox(width: 8),
        Text(_e.progressText, style: ts(F.sub, w: w6, c: p.sec)),
      ]);
    }
    final off = p.sec.withValues(alpha: .18);
    final total = max(1, _e.total);
    // 字少的時候一個字一格；幾百個字的清單改成一條進度條，才不會擠出畫面
    final Widget bar = _e.total <= 30
        ? Row(children: [
            for (var i = 0; i < total; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  decoration: BoxDecoration(color: i < _e.done.length ? p.accent : off, borderRadius: BorderRadius.circular(3)),
                ),
              ),
            ],
          ])
        : ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(value: _e.done.length / total, backgroundColor: off, color: p.accent, minHeight: 6),
          );
    return SizedBox(
      height: 6,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(child: bar),
        Positioned(right: 0, top: 9, child: Text(_e.progressText, style: ts(F.cap2, w: w7, c: p.sec))),
      ]),
    );
  }

  Widget _question(QItem item) {
    final key = ValueKey(item);
    return switch (item.type) {
      QType.flashcard => FlashcardQuestion(
          key: key,
          word: item.word,
          canUndo: _e.canUndo,
          onUndo: _e.undo,
          onDetail: () => showWordDetail(context, item.word),
          onGrade: _grade,
        ),
      QType.spelling || QType.listenSpell => SpellingQuestion(
          key: key,
          word: item.word,
          listen: item.type == QType.listenSpell,
          canUndo: _e.canUndo,
          onUndo: _e.undo,
          onGrade: _grade,
        ),
      _ => ChoiceQuestion(key: key, word: item.word, type: item.type, canUndo: _e.canUndo, onUndo: _e.undo, onGrade: _grade),
    };
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final media = MediaQuery.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: ListenableBuilder(
        listenable: _e,
        builder: (context, _) {
          final item = _e.current;
          final w = item?.word;
          return Padding(
            padding: EdgeInsets.fromLTRB(18, media.padding.top + 8, 18, media.viewInsets.bottom > 0 ? media.viewInsets.bottom : media.padding.bottom),
            child: Column(children: [
              Row(children: [
                CircleBtn(icon: Icons.close_rounded, label: '結束練習', onTap: _confirmExit),
                const SizedBox(width: 14),
                Expanded(child: _track(p)),
                const SizedBox(width: 14),
                MenuBtn(
                  label: '更多',
                  entries: () => [
                    MenuEntry('學習規則', icon: Icons.help_outline_rounded, onTap: () => showRules(context)),
                    MenuEntry('設定', icon: Icons.tune_rounded, onTap: () => presentSheet(context, (_) => const SettingsPage())),
                  ],
                  child: const AbsorbPointer(child: CircleBtn(icon: Icons.more_horiz_rounded)),
                ),
              ]),
              const SizedBox(height: 14),
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Expanded(child: Text(item?.type.label ?? widget.title, style: ts(F.title3, w: w7))),
                if (w != null) ...[
                  for (var i = 1; i <= 5; i++)
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(left: 4),
                      decoration: BoxDecoration(shape: BoxShape.circle, color: i <= w.srsLevel ? p.accent : p.sec.withValues(alpha: .22)),
                    ),
                  const SizedBox(width: 6),
                  Text(levelName(w.srsLevel), style: ts(F.cap, w: w7, c: p.sec)),
                ],
              ]),
              const SizedBox(height: 4),
              Expanded(
                child: item == null
                    ? const SizedBox.shrink()
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        switchInCurve: Curves.easeOutCubic,
                        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                        transitionBuilder: (child, a) {
                          final incoming = child.key == ValueKey(item);
                          return FadeTransition(
                            opacity: a,
                            child: incoming
                                ? SlideTransition(position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(a), child: child)
                                : IgnorePointer(child: child),
                          );
                        },
                        child: _question(item),
                      ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

Future<void> showRules(BuildContext c) => presentSheet(c, (_) => const _RulesSheet());

class _RulesSheet extends StatelessWidget {
  const _RulesSheet();

  Widget _rule(Palette p, IconData icon, String title, String sub) => RowTile(
        leading: Icon(icon, size: 22, color: p.accent),
        titleWidget: Text(title, style: ts(F.headline, w: w6)),
        subtitle: sub,
        subtitleLines: 2,
      );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return NavPage(title: '學習規則', safeTop: false, close: true, slivers: [
      Sec(header: '使用提示', children: [
        _rule(p, Icons.check_circle_outline_rounded, '右滑：會', '安排到下次到期再出現。'),
        _rule(p, Icons.highlight_off_rounded, '左滑：不會', '約 20 分鐘後再出現，本輪也會再考一次。'),
        _rule(p, Icons.help_outline_rounded, '不確定', '明天再複習一次。'),
        _rule(p, Icons.touch_app_outlined, '點一下：看解釋', '卡片會翻到解釋面。'),
        _rule(p, Icons.favorite_border_rounded, '愛心：加入喜歡', '喜歡的單字會進入「喜歡」清單。'),
        _rule(p, Icons.undo_rounded, '復原', '收回上一個答案。'),
      ]),
      Sec(header: '選擇題與拼字', children: [
        _rule(p, Icons.help_outline_rounded, '不知道', '直接看答案，算作不會；比用猜的更準。'),
        _rule(p, Icons.lightbulb_outline_rounded, '提示', '拼字時補上下一個字母。用了提示答對算不確定。'),
        _rule(p, Icons.slow_motion_video_rounded, '慢速再聽', '聽力題用較慢的速度再念一次。'),
        _rule(p, Icons.error_outline_rounded, '差一點', '拼錯一個字母算不確定，不算不會。'),
        _rule(p, Icons.keyboard_outlined, '再打一次', '拼錯後照著正確拼法打一遍，成績仍照第一次。'),
      ]),
    ]);
  }
}

/// 不會 / 不確定 / 會
class GradeButtons extends StatelessWidget {
  const GradeButtons({super.key, required this.onGrade});
  final ValueChanged<Grade> onGrade;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget tile(String t, IconData icon, Color fill, Color ink, Grade g) => Expanded(
          child: PillButton(
            semantic: t,
            fill: fill,
            fg: ink,
            height: 66,
            onTap: () => onGrade(g),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 22, weight: 700),
              const SizedBox(height: 4),
              Text(t, style: ts(F.sub, w: w7)),
            ]),
          ),
        );
    return Row(children: [
      tile('不會', Icons.close_rounded, p.againPink, p.againInk, Grade.again),
      const SizedBox(width: 10),
      tile('不確定', Icons.question_mark_rounded, p.unsureYellow, p.unsureInk, Grade.unsure),
      const SizedBox(width: 10),
      tile('會', Icons.check_rounded, p.knowGreen, p.knowInk, Grade.good),
    ]);
  }
}
