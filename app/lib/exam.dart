// 大考考古題：學測英文的選擇題。題目和答案在 assets/exams.json，排版照 iOS 版 ExamView。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dictionary.dart';
import 'models.dart';
import 'services.dart';
import 'sheets.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';

class ExamQuestion {
  ExamQuestion.fromJson(Map<String, dynamic> j)
      : n = j['n'] as int,
        stem = j['stem'] as String? ?? '',
        options = List<String>.from(j['options'] as List? ?? const []),
        answer = j['answer'] as int;
  final int n, answer;
  final String stem;
  final List<String> options;
}

class ExamGroup {
  ExamGroup.fromJson(Map<String, dynamic> j)
      : section = j['section'] as String,
        kind = j['kind'] as String,
        passage = j['passage'] as String?,
        shared = (j['shared'] as List?)?.cast<String>(),
        questions = (j['questions'] as List).map((q) => ExamQuestion.fromJson(q as Map<String, dynamic>)).toList();
  final String section;

  /// vocab、cloze、fill、structure、reading
  final String kind;

  /// 段落以空行分開；有編號的空格寫成 ⟨n⟩
  final String? passage;

  /// 文意選填和篇章結構：同一組空格共用一份選項
  final List<String>? shared;
  final List<ExamQuestion> questions;

  List<String> optionsOf(ExamQuestion q) => shared ?? q.options;
}

class Exam {
  Exam.fromJson(Map<String, dynamic> j)
      : year = j['year'] as int,
        title = j['title'] as String,
        groups = (j['groups'] as List).map((g) => ExamGroup.fromJson(g as Map<String, dynamic>)).toList();
  final int year;
  final String title;
  final List<ExamGroup> groups;
  int get questionCount => groups.fold(0, (n, g) => n + g.questions.length);
}

class ExamStore {
  static const sections = ['詞彙題', '綜合測驗', '文意選填', '篇章結構', '閱讀測驗'];
  static const _vocabKinds = {'vocab', 'cloze', 'fill'};
  static const _key = 'examScores';

  static List<Exam> all = const [];
  static Map<String, String> _scores = {};
  static Map<String, List<int>>? _years;

  static Future<void> load() async {
    loadFromJson(await rootBundle.loadString('assets/exams.json'));
    final saved = (await SharedPreferences.getInstance()).getString(_key);
    if (saved != null) _scores = Map<String, String>.from(jsonDecode(saved) as Map);
  }

  static void loadFromJson(String json) {
    all = (jsonDecode(json) as List).map((e) => Exam.fromJson(e as Map<String, dynamic>)).toList();
    _years = null;
  }

  /// 這個字在哪幾年的詞彙、綜合、文意選項出現過。要等字典載入，所以第一次用到才算
  static List<int> years(String term) {
    final map = _years ??= () {
      final m = <String, Set<int>>{};
      for (final e in all) {
        for (final g in e.groups.where((g) => _vocabKinds.contains(g.kind))) {
          for (final o in [...?g.shared, for (final q in g.questions) ...q.options]) {
            if (o.contains(' ')) continue;
            final d = Dict.lookup(o);
            if (d != null) (m[d.w.toLowerCase()] ??= {}).add(e.year);
          }
        }
      }
      return m.map((k, v) => MapEntry(k, v.toList()..sort((a, b) => b - a)));
    }();
    return map[term.toLowerCase()] ?? const [];
  }

  static String? score(int year, String section) => _scores['$year-$section'];

  static Future<void> save(int year, String section, int right, int total) async {
    _scores['$year-$section'] = '$right/$total';
    (await SharedPreferences.getInstance()).setString(_key, jsonEncode(_scores));
  }
}

/// 單字考過的年份標籤，例如「考過 115・114 學測」
class ExamYearsTag extends StatelessWidget {
  const ExamYearsTag({super.key, required this.term});
  final String term;
  @override
  Widget build(BuildContext context) {
    final ys = ExamStore.years(term);
    if (ys.isEmpty) return const SizedBox.shrink();
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: p.hsnuMagentaFill, borderRadius: BorderRadius.circular(Radii.sm)),
      child: Text('考過 ${ys.join('・')} 學測', style: ts(F.cap, w: w7, c: p.hsnuMagenta)),
    );
  }
}

class _Item {
  const _Item(this.group, this.q);
  final int group;
  final ExamQuestion q;
}

class ExamView extends StatefulWidget {
  const ExamView({super.key, required this.exam});
  final Exam exam;
  @override
  State<ExamView> createState() => _ExamViewState();
}

class _ExamViewState extends State<ExamView> {
  List<_Item> _run = const [];
  String _section = '';
  int _index = 0;

  /// 題號 → 選的選項；-1 是「不知道」
  final _picks = <int, int>{};
  bool _finished = false, _added = false;
  Timer? _auto;

  Exam get exam => widget.exam;
  _Item? get _current => _index < _run.length ? _run[_index] : null;
  bool _right(_Item i) => _picks[i.q.n] == i.q.answer;
  int _rightIn(Iterable<_Item> items) => items.where(_right).length;
  Iterable<_Item> _part(String s) => _run.where((i) => exam.groups[i.group].section == s);

  @override
  void dispose() {
    _auto?.cancel();
    super.dispose();
  }

  void _start(String? s) => setState(() {
        _section = s ?? '整份';
        _run = [
          for (final (i, g) in exam.groups.indexed)
            if (s == null || g.section == s)
              for (final q in g.questions) _Item(i, q),
        ];
        _index = 0;
        _picks.clear();
        _finished = _added = false;
      });

  void _toMenu() {
    _auto?.cancel();
    setState(() => _run = const []);
  }

  void _choose(int i, _Item item) {
    if (_picks.containsKey(item.q.n)) return;
    setState(() => _picks[item.q.n] = i);
    if (i == item.q.answer) {
      Feedback2.success();
      // 答對自己往下；答錯要停著，讓人看清楚正確答案
      _auto = Timer(const Duration(milliseconds: 800), _advance);
    } else {
      Feedback2.error();
    }
  }

  void _advance() {
    _auto?.cancel();
    if (_index + 1 < _run.length) {
      setState(() => _index += 1);
    } else {
      _finish();
    }
  }

  void _finish() {
    ExamStore.save(exam.year, _section, _rightIn(_run), _run.length);
    if (_section == '整份') {
      for (final s in ExamStore.sections) {
        final part = _part(s).toList();
        if (part.isNotEmpty) ExamStore.save(exam.year, s, _rightIn(part), part.length);
      }
    }
    setState(() => _finished = true);
  }

  /// 答錯的詞彙、綜合、文意題，正確答案是字典裡的字
  List<DictEntry> get _missed {
    final seen = <String>{};
    final out = <DictEntry>[];
    for (final item in _run) {
      final g = exam.groups[item.group];
      if (!ExamStore._vocabKinds.contains(g.kind) || _right(item)) continue;
      final opts = g.optionsOf(item.q);
      if (item.q.answer >= opts.length) continue;
      final e = Dict.lookup(opts[item.q.answer]);
      if (e != null && seen.add(e.w)) out.add(e);
    }
    return out;
  }

  // MARK: 畫面

  Widget _header(Palette p) {
    final top = _run.isEmpty || _finished;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(children: [
        CircleBtn(
          icon: top ? Icons.close_rounded : Icons.chevron_left_rounded,
          label: top ? '關閉' : '回到題型',
          onTap: top ? () => Navigator.of(context).pop() : _toMenu,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(exam.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.headline, w: w6)),
            if (!top) Text('$_section・第 ${_index + 1 > _run.length ? _run.length : _index + 1} / ${_run.length} 題', style: ts(F.cap, c: p.sec)),
          ]),
        ),
      ]),
    );
  }

  Widget _menu(Palette p, double bottom) => CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
          sliver: SliverToBoxAdapter(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PrimaryButton(label: '整份作答・${exam.questionCount} 題', icon: Icons.description_rounded, onTap: () => _start(null)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('選擇題部分，題目與答案取自大考中心公布的試題。選項是圖片的題目、混合題與非選擇題不收錄。', style: ts(F.foot, c: p.sec)),
              ),
            ]),
          ),
        ),
        Sec(header: '依題型練習', children: [
          for (final s in ExamStore.sections)
            if (exam.groups.where((g) => g.section == s).fold<int>(0, (n, g) => n + g.questions.length) case final n when n > 0)
              RowTile(
                title: s,
                subtitle: '$n 題${ExamStore.score(exam.year, s) == null ? '' : '・上次答對 ${ExamStore.score(exam.year, s)}'}',
                chevron: true,
                onTap: () => _start(s),
              ),
        ]),
        SliverToBoxAdapter(child: SizedBox(height: bottom + 24)),
      ]);

  Widget _question(Palette p, double bottom) {
    final item = _current!;
    final g = exam.groups[item.group];
    return LayoutBuilder(
      builder: (context, box) => Column(children: [
        if (g.passage != null) ...[
          SizedBox(
            height: box.maxHeight * (g.kind == 'reading' ? .5 : .42),
            child: _Passage(group: g, current: item.q.n, picks: _picks, onWord: (w) => showWordConfirm(context, w)),
          ),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: ListView(
            key: ValueKey(_index),
            padding: EdgeInsets.fromLTRB(20, 0, 20, bottom + 24),
            children: [
              Text('第 ${item.q.n} 題・${g.section}', style: ts(F.cap, w: w7, c: p.hsnuNavy)),
              const SizedBox(height: 12),
              if (const {'cloze', 'fill', 'structure'}.contains(g.kind))
                Text('選出最適合填入空格 (${item.q.n}) 的選項', style: ts(F.headline, w: w6))
              else
                PassageText(text: item.q.stem, style: ts(F.title3, w: w6), onWord: (w) => showWordConfirm(context, w)),
              const SizedBox(height: 12),
              ..._options(p, item, g),
              if (_picks[item.q.n] case final picked? when picked != item.q.answer) ...[
                const SizedBox(height: 18),
                PrimaryButton(label: _index + 1 < _run.length ? '下一題' : '看結果', onTap: _advance),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  List<Widget> _options(Palette p, _Item item, ExamGroup g) {
    final opts = g.optionsOf(item.q);
    final picked = _picks[item.q.n];
    // 文意選填用過的選項變淡，和紙本一樣每個只用一次
    final used = {
      for (final q in g.questions)
        if (q.n != item.q.n && _picks.containsKey(q.n)) q.answer,
    };
    final rows = [
      for (final (i, o) in opts.indexed)
        AnswerOption(
          letter: String.fromCharCode(65 + i),
          text: o,
          state: picked == null
              ? (used.contains(i) ? AnswerState.used : AnswerState.idle)
              : i == item.q.answer
                  ? AnswerState.right
                  : picked == i
                      ? AnswerState.wrong
                      : AnswerState.idle,
          onTap: picked == null ? () => _choose(i, item) : null,
        ),
    ];
    return [
      if (g.kind == 'fill')
        StackGrid(columns: 2, spacing: 10, children: rows)
      else
        for (final (i, r) in rows.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 10), child: r),
      if (picked == null)
        Tap(
          onTap: () => _choose(-1, item),
          child: SizedBox(height: 44, child: Center(child: Text('不知道', style: ts(F.sub, w: w6, c: p.sec)))),
        ),
    ];
  }

  Widget _results(Palette p, double bottom) {
    final right = _rightIn(_run);
    final missed = _missed;
    return ListView(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottom + 30),
      children: [
        Center(child: Text(_section == '整份' ? '整份作答' : _section, style: ts(F.headline, w: w6, c: p.sec))),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('$right', style: ts(64, w: w6, c: p.hsnuNavy, h: 1.15)),
            const SizedBox(width: 4),
            Text('/ ${_run.length} 題', style: ts(F.title3, w: w6, c: p.sec)),
          ],
        ),
        const SizedBox(height: 18),
        ExcludeSemantics(
          child: Row(children: [
            for (final (i, item) in _run.indexed) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(
                child: Container(
                  height: 14,
                  decoration: BoxDecoration(color: _right(item) ? p.hsnuSky : p.hsnuMagenta, borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 18),
        for (final s in ExamStore.sections)
          if (_part(s).isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Expanded(child: Text(s, style: ts(F.body))),
                Text('${_rightIn(_part(s))} / ${_part(s).length}', style: ts(F.body, c: p.sec)),
              ]),
            ),
            Container(height: .5, color: p.separator),
          ],
        if (missed.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('答錯的單字', style: ts(F.sub, w: w7)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in missed)
              Tap(
                dim: false,
                onTap: () => showWordConfirm(context, e.w),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: p.hsnuMagentaFill, borderRadius: BorderRadius.circular(100)),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: e.w, style: ts(F.sub, w: w6)),
                    TextSpan(text: '  ${e.zh.isEmpty ? '' : e.zh.first}', style: ts(F.cap, c: p.sec)),
                  ])),
                ),
              ),
          ]),
          const SizedBox(height: 12),
          PillButton(
            label: _added ? '已加入我的單字' : '全部加入我的單字',
            onTap: _added
                ? null
                : () {
                    for (final e in missed) {
                      AppStore.shared.add(e);
                    }
                    setState(() => _added = true);
                  },
          ),
        ],
        const SizedBox(height: 18),
        Row(children: [
          Expanded(child: PillButton(label: '其他題型', onTap: _toMenu)),
          const SizedBox(width: 10),
          Expanded(child: PrimaryButton(label: '完成', onTap: () => Navigator.of(context).pop())),
        ]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final media = MediaQuery.of(context);
    final bottom = media.padding.bottom;
    return PopScope(
      canPop: _run.isEmpty || _finished,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _toMenu();
      },
      child: Padding(
        padding: EdgeInsets.only(top: media.padding.top),
        child: Column(children: [
          _header(p),
          Expanded(
            child: _run.isEmpty
                ? _menu(p, bottom)
                : _finished
                    ? _results(p, bottom)
                    : _question(p, bottom),
          ),
        ]),
      ),
    );
  }
}

/// 文章區：題目換到下一段時，自動捲到那一段
class _Passage extends StatefulWidget {
  const _Passage({required this.group, required this.current, required this.picks, required this.onWord});
  final ExamGroup group;
  final int current;
  final Map<int, int> picks;
  final ValueChanged<String> onWord;
  @override
  State<_Passage> createState() => _PassageState();
}

class _PassageState extends State<_Passage> {
  late List<String> _paras;
  late List<GlobalKey> _keys;

  void _prepare() {
    _paras = widget.group.passage!.split('\n\n');
    _keys = [for (final _ in _paras) GlobalKey()];
  }

  void _scroll(Duration d) {
    final i = _paras.indexWhere((p) => p.contains('⟨${widget.current}⟩'));
    final ctx = i < 0 ? null : _keys[i].currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: d, curve: Curves.easeOutCubic);
  }

  @override
  void initState() {
    super.initState();
    _prepare();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scroll(Duration.zero);
    });
  }

  @override
  void didUpdateWidget(_Passage old) {
    super.didUpdateWidget(old);
    if (old.group != widget.group) _prepare();
    if (old.current != widget.current) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scroll(const Duration(milliseconds: 300));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final g = widget.group;
    final filled = <int, (String, bool)>{};
    for (final q in g.questions) {
      final pick = widget.picks[q.n];
      if (pick == null) continue;
      final opts = g.optionsOf(q);
      filled[q.n] = (q.answer < opts.length ? opts[q.answer] : '', pick == q.answer);
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
      child: Stack(children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final (i, para) in _paras.indexed)
                Padding(
                  key: _keys[i],
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
                  child: PassageText(
                    text: para,
                    current: g.kind == 'reading' ? null : widget.current,
                    filled: filled,
                    onWord: widget.onWord,
                  ),
                ),
            ]),
          ),
        ),
        Positioned(left: 0, top: 14, bottom: 14, child: Container(width: 3, color: p.hsnuNavy)),
      ]),
    );
  }
}

/// 試題文字：每個字都能點來查，⟨n⟩ 畫成有編號的空格，答完填入答案
class PassageText extends StatefulWidget {
  const PassageText({super.key, required this.text, this.current, this.filled = const {}, this.style, required this.onWord});
  final String text;
  final int? current;
  final Map<int, (String, bool)> filled;
  final TextStyle? style;
  final ValueChanged<String> onWord;
  @override
  State<PassageText> createState() => _PassageTextState();
}

class _PassageTextState extends State<PassageText> {
  static final _blank = RegExp(r'⟨(\d+)⟩');
  final _taps = <TapGestureRecognizer>[];

  void _clear() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    _clear();
    final spans = <InlineSpan>[];
    for (final (i, s) in widget.text.split(' ').where((t) => t.isNotEmpty).indexed) {
      if (i > 0) spans.add(const TextSpan(text: ' '));
      final m = _blank.firstMatch(s);
      if (m != null) {
        final n = int.parse(m[1]!);
        final fill = widget.filled[n];
        spans
          ..add(TextSpan(text: s.substring(0, m.start)))
          ..add(TextSpan(
            text: fill != null ? '($n) ${fill.$1}' : ' ($n) ______ ',
            style: TextStyle(
              fontWeight: w7,
              color: fill == null ? p.hsnuNavy : (fill.$2 ? p.hsnuSky : p.hsnuMagenta),
              backgroundColor: fill == null && n == widget.current ? p.hsnuSkyFill : null,
            ),
          ))
          ..add(TextSpan(text: s.substring(m.end)));
        continue;
      }
      final word = stripPunct(s);
      if (word.isEmpty || !word.contains(RegExp('[A-Za-z]'))) {
        spans.add(TextSpan(text: s));
      } else {
        final tap = TapGestureRecognizer()..onTap = () => widget.onWord(word);
        _taps.add(tap);
        spans.add(TextSpan(text: s, recognizer: tap));
      }
    }
    return Text.rich(
      TextSpan(children: spans),
      style: widget.style ?? ts(F.body, h: 1.5),
      semanticsLabel: widget.text.replaceAllMapped(_blank, (m) => '第${m[1]}題空格'),
    );
  }
}

enum AnswerState { idle, used, right, wrong }

/// 答案卡選項：字母方格像鉛筆塗卡，答對塗天藍、答錯塗紫紅
class AnswerOption extends StatelessWidget {
  const AnswerOption({super.key, required this.letter, required this.text, required this.state, this.onTap, this.minHeight = 54});
  final String letter, text;
  final AnswerState state;
  final VoidCallback? onTap;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final right = state == AnswerState.right, wrong = state == AnswerState.wrong;
    final marked = right || wrong;
    return Tap(
      dim: false,
      onTap: onTap,
      child: Opacity(
        opacity: state == AnswerState.used ? .45 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          constraints: BoxConstraints(minHeight: minHeight),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: right ? p.hsnuSkyFill : (wrong ? p.hsnuMagentaFill : p.card),
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 30,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: right ? p.hsnuSky : (wrong ? p.hsnuMagenta : Colors.transparent),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: marked ? Colors.transparent : p.hsnuNavy.withValues(alpha: .5), width: 1.5),
              ),
              child: Text(letter, style: ts(F.sub, w: w7, mono: true, c: marked ? Colors.white : p.hsnuNavy)),
            ),
            const SizedBox(width: 12),
            // 單字選項太長就縮小，不要從字中間斷行
            Expanded(
              child: text.contains(' ') ? Text(text, style: ts(F.headline, w: w6)) : FitText(text, style: ts(F.headline, w: w6)),
            ),
            if (right) Icon(Icons.check_rounded, size: 20, color: p.hsnuSky, semanticLabel: '正確答案'),
            if (wrong) Icon(Icons.close_rounded, size: 20, color: p.hsnuMagenta, semanticLabel: '答錯'),
          ]),
        ),
      ),
    );
  }
}
