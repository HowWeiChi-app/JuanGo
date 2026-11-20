// 三種題目：翻卡片、選擇題、拼字。選項和判分規則照 iOS 版 Questions.swift。

import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'dictionary.dart';
import 'models.dart';
import 'services.dart';
import 'settings.dart';
import 'sheets.dart';
import 'store.dart';
import 'study_flow.dart';
import 'theme.dart';
import 'widgets.dart';

/// 內容不夠高時撐滿，太高時可以捲動（鍵盤跳出來的時候）
class FillScroll extends StatelessWidget {
  const FillScroll({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: IntrinsicHeight(child: child),
          ),
        ),
      );
}

/// 下方的復原與愛心
class _UndoHeart extends StatefulWidget {
  const _UndoHeart({required this.word, required this.canUndo, required this.onUndo});
  final Word word;
  final bool canUndo;
  final VoidCallback onUndo;
  @override
  State<_UndoHeart> createState() => _UndoHeartState();
}

class _UndoHeartState extends State<_UndoHeart> {
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fav = widget.word.favorite;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Tap(
        label: '復原',
        onTap: widget.canUndo ? widget.onUndo : null,
        child: Row(children: [
          Icon(Icons.undo_rounded, size: 18, color: p.sec),
          const SizedBox(width: 4),
          Text('復原', style: ts(F.sub, w: w6, c: p.sec)),
        ]),
      ),
      const SizedBox(width: 18),
      Tap(
        label: fav ? '取消喜歡' : '喜歡',
        onTap: () => setState(() => AppStore.shared.toggleFavorite(widget.word)),
        child: Icon(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 21, color: fav ? p.accent : p.sec),
      ),
    ]);
  }
}

class _SlowReplay extends StatelessWidget {
  const _SlowReplay(this.term);
  final String term;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Tap(
      onTap: () => Speech.say(term, rate: .28),
      child: SizedBox(
        height: 44,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.slow_motion_video_rounded, size: 18, color: p.accent),
          const SizedBox(width: 5),
          Text('慢速再聽', style: ts(F.sub, w: w6, c: p.accent)),
        ]),
      ),
    );
  }
}

class _ListenButton extends StatelessWidget {
  const _ListenButton(this.term, {this.size = 110});
  final String term;
  final double size;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Tap(
      label: '再聽一次',
      onTap: () => Speech.say(term),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: p.accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(Radii.lg)),
        child: Icon(Icons.volume_up_rounded, size: size * .42, color: p.accent),
      ),
    );
  }
}

// MARK: 翻卡片

class FlashcardQuestion extends StatefulWidget {
  const FlashcardQuestion({
    super.key,
    required this.word,
    required this.canUndo,
    required this.onUndo,
    required this.onDetail,
    required this.onGrade,
  });
  final Word word;
  final bool canUndo;
  final VoidCallback onUndo, onDetail;
  final ValueChanged<Grade> onGrade;
  @override
  State<FlashcardQuestion> createState() => _FlashcardQuestionState();
}

class _FlashcardQuestionState extends State<FlashcardQuestion> with TickerProviderStateMixin {
  late final _flip = AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  late final _drag = AnimationController.unbounded(vsync: this);
  bool _flying = false;

  Word get w => widget.word;

  @override
  void initState() {
    super.initState();
    if (AppSettings.shared.autoSpeak) Speech.say(w.term);
  }

  @override
  void dispose() {
    _flip.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _toggle() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _flip.value = _flip.value > .5 ? 0 : 1;
    } else {
      _flip.value > .5 || _flip.status == AnimationStatus.forward ? _flip.reverse() : _flip.forward();
    }
  }

  void _dragEnd() {
    final x = _drag.value;
    if (x > 120) {
      _fling(Grade.good, 600);
    } else if (x < -120) {
      _fling(Grade.again, -600);
    } else {
      _drag.animateTo(0, duration: const Duration(milliseconds: 260), curve: Curves.easeOutBack);
    }
  }

  Future<void> _fling(Grade g, double to) async {
    _flying = true;
    await _drag.animateTo(to, duration: const Duration(milliseconds: 200), curve: Curves.easeIn);
    if (mounted) widget.onGrade(g);
  }

  Widget _exampleBlock(Palette p, bool back) {
    if (w.example.isNotEmpty) {
      return QuoteBlock(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TappableSentence(
            sentence: w.example,
            highlight: w.term,
            style: ts(F.body, w: w5),
            onTap: (t) => showWordConfirm(context, t),
          ),
          if (back) ...[
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: AppSettings.shared.showTranslation ? Text(w.exampleZh, style: ts(F.sub, c: p.sec)) : const SizedBox.shrink(),
              ),
              Tap(label: '念例句', onTap: () => Speech.say(w.example), child: Icon(Icons.volume_up_rounded, size: 18, color: p.accent)),
            ]),
          ],
        ]),
      );
    }
    if (back && w.definition.isNotEmpty) {
      return Text(w.definition, maxLines: 3, overflow: TextOverflow.ellipsis, style: ts(F.sub, c: p.sec));
    }
    return const SizedBox.shrink();
  }

  Widget _face(Palette p, bool back) => Container(
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
        padding: const EdgeInsets.all(22),
        child: FillScroll(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (w.pos.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: p.accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(Radii.sm)),
                  child: Text(w.pos, style: ts(F.cap, w: w7, c: p.accent)),
                ),
              const Spacer(),
              Text(back ? '解釋' : '點一下翻面', style: ts(F.cap, w: w6, c: p.sec)),
            ]),
            const Spacer(),
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: FitText(w.term, style: ts(back ? 36 : 46, w: w7))),
            const SizedBox(height: 12),
            Tap(
              label: w.ipa.isEmpty ? '念出來' : '念出來，音標 ${w.ipa}',
              onTap: () => Speech.say(w.term),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.volume_up_rounded, size: 18, color: p.accent),
                const SizedBox(width: 6),
                if (w.ipa.isNotEmpty) Flexible(child: Text('/${w.ipa}/', style: ts(F.sub, c: p.sec))),
              ]),
            ),
            if (back) ...[
              Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Container(height: .5, color: p.separator)),
              Text(w.primaryMeaning, style: ts(28, w: w7)),
              if (w.meanings.length > 1) ...[
                const SizedBox(height: 10),
                Text('也有：${w.meanings.skip(1).take(3).join('、')}', style: ts(F.sub, c: p.sec)),
              ],
            ],
            const SizedBox(height: 12),
            // 正面留好例句的高度，翻到不同字時單字的位置才不會跳動
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: back ? 0 : 118),
              child: Align(alignment: Alignment.topLeft, child: _exampleBlock(p, back)),
            ),
            const SizedBox(height: 12),
            const Spacer(),
            if (back)
              Tap(
                onTap: widget.onDetail,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.north_east_rounded, size: 16, color: p.accent),
                  const SizedBox(width: 5),
                  Text('完整單字頁', style: ts(F.sub, w: w7, c: p.accent)),
                ]),
              ),
          ]),
        ),
      );

  Widget _hint(Palette p, double x) {
    if (x.abs() <= 30) return const SizedBox.shrink();
    return Opacity(
      opacity: min(1, x.abs() / 120),
      child: Container(
        margin: const EdgeInsets.only(top: 20),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(color: x > 0 ? p.knowGreen : p.againPink, borderRadius: BorderRadius.circular(24)),
        child: Text(x > 0 ? '會' : '不會', style: ts(F.title2, w: w6)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 12),
      child: Column(children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            onHorizontalDragUpdate: _flying ? null : (d) => _drag.value += d.primaryDelta!,
            onHorizontalDragEnd: _flying ? null : (_) => _dragEnd(),
            child: AnimatedBuilder(
              animation: Listenable.merge([_flip, _drag]),
              builder: (context, _) {
                final t = Curves.easeInOut.transform(_flip.value);
                final back = t > .5;
                final x = _drag.value;
                return Transform.translate(
                  offset: Offset(x, 0),
                  child: Transform.rotate(
                    angle: x / 22 * pi / 180,
                    child: Stack(fit: StackFit.expand, children: [
                      Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, .0012)
                          ..rotateY(t * pi + (back ? pi : 0)),
                        child: _face(p, back),
                      ),
                      Align(alignment: Alignment.topCenter, child: IgnorePointer(child: _hint(p, x))),
                    ]),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(children: [
            Expanded(child: Align(alignment: Alignment.centerLeft, child: _UndoHeart(word: w, canUndo: widget.canUndo, onUndo: widget.onUndo))),
          ]),
        ),
        const SizedBox(height: 16),
        GradeButtons(onGrade: widget.onGrade),
      ]),
    );
  }
}

// MARK: 選擇題

class ChoiceQuestion extends StatefulWidget {
  const ChoiceQuestion({
    super.key,
    required this.word,
    required this.type,
    required this.canUndo,
    required this.onUndo,
    required this.onGrade,
  });
  final Word word;
  final QType type;
  final bool canUndo;
  final VoidCallback onUndo;
  final ValueChanged<Grade> onGrade;
  @override
  State<ChoiceQuestion> createState() => _ChoiceQuestionState();
}

typedef _Cand = ({String term, String zh, String pos});

class _ChoiceQuestionState extends State<ChoiceQuestion> {
  late final List<String> _options;

  /// 答錯的選項另一面是什麼（中文選項對應的英文），答錯也能多學一個字
  final _otherSide = <String, String>{};
  String? _picked;

  Word get w => widget.word;
  QType get type => widget.type;
  bool get _answersInZh => type == QType.enToZh || type == QType.listenZh;

  List<String>? get _splitParts {
    if (type != QType.cloze) return null;
    final p = WordMatch.blankParts(w.term);
    return p.length >= 2 ? p : null;
  }

  String get _correct => _answersInZh ? w.primaryMeaning : (_splitParts?.join(' / ') ?? w.term);

  @override
  void initState() {
    super.initState();
    _options = _makeOptions();
    if (type == QType.listenZh || type == QType.listenEn || (AppSettings.shared.autoSpeak && type == QType.enToZh)) {
      Speech.say(w.term);
    }
  }

  T _pick<T>(List<T> l) => l[rng.nextInt(l.length)];

  List<String> _splitOptions(List<String> parts) {
    final correct = _correct;
    final phrases = {
      ...AppStore.shared.words.map((x) => x.term),
      ...Dict.phrases.map((e) => e.w),
    }.where((t) => t != w.term && t.contains(' ') && Dict.lookup(t) != null).toList()
      ..shuffle(rng);
    final picks = <String>[];
    for (final t in phrases) {
      final ps = WordMatch.blankParts(t);
      final v = ps.join(' / ');
      if (ps.length == parts.length && v != correct && !picks.contains(v)) picks.add(v);
      if (picks.length == 3) break;
    }
    String lookalike(String part) => part.split(' ').where((s) => s.isNotEmpty).map((x) {
          final pos = Dict.lookup(x)?.pos ?? '';
          final pool = (Dict.byPos[pos] ?? const <DictEntry>[])
              .where((e) => !e.w.contains(' ') && e.w != x && (e.w.length - x.length).abs() <= 2)
              .toList();
          // 第 1–3 級的常見字才像真的考題，罕見字一看就知道是錯的
          final common = pool.where((e) => const ['1', '2', '3'].contains(e.lv)).toList();
          final from = common.isEmpty ? pool : common;
          return from.isEmpty ? x : _pick(from).w;
        }).join(' ');
    var tries = 0;
    while (picks.length < 3 && tries < 40) {
      tries += 1;
      final fake = parts.map(lookalike).toList();
      final v = fake.join(' / ');
      var allDiffer = true;
      for (var i = 0; i < parts.length; i++) {
        if (fake[i] == parts[i]) allDiffer = false;
      }
      if (allDiffer && v != correct && !picks.contains(v)) picks.add(v);
    }
    return [...picks, correct]..shuffle(rng);
  }

  List<String> _makeOptions() {
    final parts = _splitParts;
    if (parts != null) return _splitOptions(parts);
    _Cand cand(DictEntry e) => (term: e.w, zh: e.zh.isEmpty ? '' : e.zh.first, pos: e.pos);
    final own = <_Cand>[
      for (final x in AppStore.shared.words)
        if (Dict.lookup(x.term) != null) (term: x.term, zh: x.primaryMeaning, pos: x.pos),
    ];
    // 像大考的選項：同詞性、程度差不多，常常字首或字尾一樣
    final same = Dict.examLike(w.term, w.pos, rng);
    final pool = <_Cand>[
      ...same.map(cand),
      ...(List.of(own)..shuffle(rng)),
      if (Dict.all.isNotEmpty) ...List.generate(40, (_) => cand(_pick(Dict.all))),
    ];
    final mine = w.meanings.toSet();
    final correct = _correct;
    // 不放同樣算對的選項：這個字的其他意思，或英美拼法的另一種寫法
    final others = pool
        .where((c) =>
            c.term != w.term &&
            c.zh.isNotEmpty &&
            c.zh != w.primaryMeaning &&
            !mine.contains(c.zh) &&
            !spellingVariants(c.term.toLowerCase(), w.term.toLowerCase()))
        .toList();
    final samePos = others.where((c) => c.pos == w.pos).toList(); // 保留 examLike 的順序，最像的在前
    final isPhrase = w.term.contains(' ');
    final phrases = !_answersInZh && isPhrase
        ? ([...others, ...Dict.phrases.map(cand)].where((c) => c.term.contains(' ') && c.term != w.term).toList()..shuffle(rng))
        : <_Cand>[];
    final picks = <String>[];
    for (final c in [...phrases, ...samePos, ...(List.of(others)..shuffle(rng))]) {
      if (!_answersInZh && !isPhrase && c.term.contains(' ')) continue;
      // 英文選項如果也有被問的意思，就等於第二個正確答案
      if (!_answersInZh && (Dict.lookup(c.term)?.zh.any(mine.contains) ?? false)) continue;
      final v = _answersInZh ? c.zh : c.term;
      if (!picks.contains(v) && v != correct) {
        picks.add(v);
        _otherSide[v] = _answersInZh ? c.term : c.zh;
      }
      if (picks.length == 3) break;
    }
    return [...picks, correct]..shuffle(rng);
  }

  void _choose(String o) {
    if (_picked != null) return;
    setState(() => _picked = o);
    if (o == _correct) {
      Feedback2.success();
      Speech.say(w.term);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) widget.onGrade(Grade.good);
      });
    } else {
      Feedback2.error();
    }
  }

  Widget _prompt(Palette p) {
    switch (type) {
      case QType.enToZh:
        return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          FitText(w.term, alignment: Alignment.center, style: ts(44, w: w7)),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (w.ipa.isNotEmpty) Flexible(child: Text('/${w.ipa}/', style: ts(F.foot, w: w6, c: p.sec))),
            const SizedBox(width: 10),
            SpeakButton(w.term, size: 16),
          ]),
        ]);
      case QType.zhToEn:
        return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(w.meaningLine, textAlign: TextAlign.center, style: ts(32, w: w7)),
          if (w.pos.isNotEmpty) ...[const SizedBox(height: 10), Text(w.pos, style: ts(F.foot, w: w6, c: p.sec))],
        ]);
      case QType.cloze:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('選出填入空格的字', style: ts(F.cap, w: w6, c: p.sec)),
          const SizedBox(height: 10),
          TappableSentence(
            sentence: w.clozeSentence ?? w.example,
            style: ts(F.title3, w: w6),
            onTap: (t) => showWordConfirm(context, t),
          ),
        ]);
      default:
        return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          _ListenButton(w.term),
          _SlowReplay(w.term),
          Text(type == QType.listenZh ? '聽發音，選出中文意思' : '聽發音，選出正確的英文', style: ts(F.cap, c: p.sec)),
        ]);
    }
  }

  Widget _option(Palette p, int k, String o) {
    final picked = _picked;
    final correct = _correct;
    final fill = picked == null
        ? p.card
        : o == correct
            ? p.hsnuSkyFill
            : o == picked
                ? p.hsnuMagentaFill
                : p.card;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Tap(
        dim: false,
        label: o,
        onTap: picked == null ? () => _choose(o) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(Radii.lg)),
          child: Row(children: [
            // 深藍色的答案卡圓圈
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: p.hsnuNavy.withValues(alpha: picked == null ? .55 : .2), width: 1.5),
              ),
              child: Text(String.fromCharCode(65 + k), style: ts(F.sub, w: w7, mono: true, c: picked == null ? p.hsnuNavy : p.ink)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(o, maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(F.headline, w: w6)),
                if (picked == o && o != correct && _otherSide[o] != null)
                  Text(_otherSide[o]!, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, w: w6, c: p.sec)),
              ]),
            ),
            if (picked != null && o == correct)
              Icon(Icons.check_circle_rounded, size: 23, color: p.hsnuSky, semanticLabel: '正確答案')
            else if (picked == o)
              Icon(Icons.cancel_rounded, size: 23, color: p.hsnuMagenta),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final picked = _picked;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: FillScroll(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ConstrainedBox(constraints: const BoxConstraints(minHeight: 170), child: _prompt(p)),
          for (final (k, o) in _options.indexed) _option(p, k, o),
          const SizedBox(height: 10),
          const Spacer(),
          SizedBox(
            height: 46,
            child: Row(children: [
              _UndoHeart(word: w, canUndo: widget.canUndo, onUndo: widget.onUndo),
              const Spacer(),
              if (picked == null)
                // 不知道就直接看答案：猜對會被當成「會」，字就要好幾天後才出現
                PillButton(
                  label: '不知道',
                  height: 46,
                  width: 110,
                  onTap: () {
                    setState(() => _picked = '');
                    Speech.say(w.term);
                  },
                )
              else if (picked != _correct)
                PillButton(label: '下一題', height: 46, width: 120, fill: p.accent, fg: p.onAccent, onTap: () => widget.onGrade(Grade.again)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// MARK: 拼字

const britishToAmerican = {
  'favour': 'favor', 'behaviour': 'behavior', 'harbour': 'harbor', 'rumour': 'rumor', 'flavour': 'flavor',
  'endeavour': 'endeavor', 'armour': 'armor', 'glamour': 'glamor', 'odour': 'odor', 'tumour': 'tumor',
  'clamour': 'clamor', 'centre': 'center', 'theatre': 'theater', 'fibre': 'fiber', 'meagre': 'meager',
  'calibre': 'caliber', 'catalogue': 'catalog', 'dialogue': 'dialog', 'monologue': 'monolog', 'prologue': 'prolog',
  'paralyse': 'paralyze', 'memorise': 'memorize', 'defence': 'defense', 'offence': 'offense', 'licence': 'license',
  'tyre': 'tire', 'mould': 'mold', 'plough': 'plow', 'aluminium': 'aluminum', 'moustache': 'mustache',
  'storey': 'story', 'draught': 'draft', 'sceptical': 'skeptical', 'manoeuvre': 'maneuver',
  'acknowledgement': 'acknowledgment', 'fulfil': 'fulfill', 'axe': 'ax', 'gaol': 'jail', 'doughnut': 'donut',
};

/// 這些美式拼法另有別的意思（tire 疲倦、story 故事），所以不接受反過來的英式拼法
const _oneWay = {'tire', 'story', 'draft', 'jail'};

bool spellingVariants(String a, String b) => britishToAmerican[a] == b || britishToAmerican[b] == a;

bool sameWord(String typed, String answer) {
  if (britishToAmerican[answer] == typed) return true;
  return britishToAmerican[typed] == answer && !_oneWay.contains(answer);
}

/// 答案裡哪些位置對得上打的字（最長共同子序列），少打一個字母只標那一個
Set<int> matchedLetters(String answer, String typed) {
  final a = answer.toLowerCase().replaceAll('’', "'").split('');
  final b = typed.toLowerCase().split('');
  if (a.isEmpty || b.isEmpty || typed.isEmpty) return {};
  final l = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      l[i][j] = a[i] == b[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1]);
    }
  }
  final out = <int>{};
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      out.add(i);
      i += 1;
      j += 1;
    } else if (l[i + 1][j] >= l[i][j + 1]) {
      i += 1;
    } else {
      j += 1;
    }
  }
  return out;
}

/// 編輯距離，相鄰兩個字母對調算一次（recieve → receive）
int editDistance(String s, String t) {
  final a = s.split(''), b = t.split('');
  if (s.isEmpty || t.isEmpty) return max(s.length, t.length);
  final d = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = 0; i <= a.length; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce(min);
      if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1);
    }
  }
  return d[a.length][b.length];
}

class SpellingQuestion extends StatefulWidget {
  const SpellingQuestion({
    super.key,
    required this.word,
    required this.listen,
    required this.canUndo,
    required this.onUndo,
    required this.onGrade,
  });
  final Word word;
  final bool listen, canUndo;
  final VoidCallback onUndo;
  final ValueChanged<Grade> onGrade;
  @override
  State<SpellingQuestion> createState() => _SpellingQuestionState();
}

class _SpellingQuestionState extends State<SpellingQuestion> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool? _checked;
  bool _gaveUp = false, _nearMiss = false;
  Grade? _retype;
  int _hints = 0;

  Word get w => widget.word;
  static final _letter = RegExp(r'\p{L}', unicode: true);

  @override
  void initState() {
    super.initState();
    if (widget.listen) Speech.say(w.term);
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    // 鍵盤自己跳出來，馬上就能打字
    Future.delayed(const Duration(milliseconds: 350), _startTyping);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startTyping() {
    if (!mounted || _checked != null) return;
    if (_focus.hasFocus) {
      SystemChannels.textInput.invokeMethod('TextInput.show');
    } else {
      _focus.requestFocus();
    }
  }

  void _setText(String s) => _text.value = TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));

  void _check() {
    if (_checked != null || _text.text.isEmpty) return;
    String plain(String s) => s.toLowerCase().replaceAll('’', "'").split(' ').where((x) => x.isNotEmpty).join(' ');
    final typed = plain(_text.text), answer = plain(w.term);
    final ok = typed == answer || sameWord(typed, answer);
    setState(() {
      _nearMiss = !ok && answer.length >= 4 && editDistance(typed, answer) == 1;
      _checked = ok;
    });
    _focus.unfocus();
    ok ? Feedback2.success() : (_nearMiss ? Feedback2.light() : Feedback2.error());
    Speech.say(w.term);
    final letters = _letter.allMatches(w.term).length;
    final grade = _retype ?? (_hints == 0 ? Grade.good : (_hints * 2 > letters ? Grade.again : Grade.unsure));
    if (ok) {
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) widget.onGrade(grade);
      });
    }
  }

  void _hint() {
    final t = w.term.split(''), typed = _text.text.split('');
    var k = 0;
    while (k < _text.text.length && k < t.length && typed[k].toLowerCase() == t[k].toLowerCase()) {
      k += 1;
    }
    if (k >= t.length) return;
    k += 1;
    while (k < t.length && !_letter.hasMatch(t[k])) {
      k += 1;
    }
    setState(() {
      _setText(t.take(k).join());
      _hints += 1;
    });
    _startTyping();
    if (k == t.length) _check();
  }

  Widget _box(Palette p, int k, List<String> t, double side, bool wrong) {
    final typed = _text.text;
    final given = k == 0 || k == t.length - 1 || "-'’.".contains(t[k]);
    final ch = _checked != null ? t[k] : (k < typed.length ? typed[k] : (given ? t[k] : ''));
    final active = k == typed.length && _checked == null && _focus.hasFocus;
    return Container(
      width: side,
      height: side * 1.2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: p.fill,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: active ? p.accent : Colors.transparent, width: 2),
      ),
      child: Text(
        ch,
        style: TextStyle(
          fontFamily: 'monospace',
          fontWeight: w7,
          fontSize: side * .55,
          height: 1,
          color: wrong ? p.accent : (k < typed.length || _checked != null ? p.ink : p.sec),
        ),
      ),
    );
  }

  /// 一個字母一格。片語換行時整個字一起換，不把每格縮到看不見
  Widget _letterBoxes(Palette p, double width) {
    final t = w.term.split('');
    final matched = _checked != null ? matchedLetters(w.term, _text.text) : const <int>{};
    final words = <(int, int)>[];
    var from = 0;
    for (var k = 0; k <= t.length; k++) {
      if (k == t.length || t[k] == ' ') {
        if (k > from) words.add((from, k));
        from = k + 1;
      }
    }
    final longest = words.isEmpty ? 1 : words.map((r) => r.$2 - r.$1).reduce(max);
    final side = max(22.0, min(40.0, width / longest - 4));
    final gap = side * .5;
    final rows = <List<(int, int)>>[];
    var used = 0.0;
    for (final r in words) {
      final need = (r.$2 - r.$1) * (side + 4);
      if (rows.isNotEmpty && used + gap + need <= width) {
        rows.last.add(r);
        used += gap + need;
      } else {
        rows.add([r]);
        used = need;
      }
    }
    return Column(children: [
      for (final row in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final (i, r) in row.indexed) ...[
              if (i > 0) SizedBox(width: gap),
              for (var k = r.$1; k < r.$2; k++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _box(p, k, t, side, _checked == false && !matched.contains(k)),
                ),
            ],
          ]),
        ),
    ]);
  }

  Widget _status(Palette p) {
    final checked = _checked!;
    final typed = _text.text.toLowerCase(), term = w.term.toLowerCase();
    final text = checked
        ? (_hints > 0 ? '拼對了（用了 $_hints 次提示）' : (sameWord(typed, term) ? '拼對了！另一種拼法是 ${w.term}' : '拼對了！'))
        : (_nearMiss ? '差一點！答案是 ${w.term}' : '答案是 ${w.term}');
    final color = checked ? p.knowInk : (_nearMiss ? p.unsureInk : p.accent);
    final icon = checked ? Icons.check_circle_rounded : (_nearMiss ? Icons.error_rounded : Icons.cancel_rounded);
    return Row(children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: ts(F.headline, w: w6, c: color))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final checked = _checked;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: LayoutBuilder(
        builder: (context, c) => FillScroll(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 150),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (widget.listen) ...[
                  _ListenButton(w.term, size: 100),
                  _SlowReplay(w.term),
                ] else ...[
                  Text(w.meaningLine, textAlign: TextAlign.center, style: ts(F.title, w: w7)),
                  if (w.pos.isNotEmpty) ...[const SizedBox(height: 10), Text(w.pos, style: ts(F.sub, w: w6, c: p.sec))],
                ],
              ]),
            ),
            const SizedBox(height: 16),
            // 字母直接打進格子：真正接收鍵盤的輸入框藏在格子後面
            Semantics(
              button: true,
              label: '拼出單字，已輸入 ${_text.text.length} 個字母，共 ${w.term.length} 個',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _startTyping,
                child: Stack(children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 2,
                    height: 2,
                    child: ExcludeSemantics(
                      child: Opacity(
                        opacity: 0,
                        child: IgnorePointer(
                          child: TextField(
                            controller: _text,
                            focusNode: _focus,
                            enabled: checked == null,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            // 密碼型鍵盤不顯示建議字，否則答案會直接出現在鍵盤上
                            keyboardType: TextInputType.visiblePassword,
                            textInputAction: TextInputAction.done,
                            inputFormatters: [LengthLimitingTextInputFormatter(w.term.length)],
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) => _check(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ExcludeSemantics(child: _letterBoxes(p, c.maxWidth)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            if (checked != null)
              _status(p)
            else ...[
              if (_retype != null) ...[
                Text('照著拼一次：${w.term}', style: ts(F.headline, w: w6, c: p.sec)),
                const SizedBox(height: 12),
              ],
              Row(children: [
                Expanded(
                  child: PillButton(
                    label: '想不起來',
                    icon: Icons.question_mark_rounded,
                    fg: p.accent,
                    onTap: () {
                      setState(() {
                        _gaveUp = true;
                        _checked = false;
                      });
                      _focus.unfocus();
                      Speech.say(w.term);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: PrimaryButton(label: '檢查', icon: Icons.check_rounded, onTap: _text.text.isEmpty ? null : _check)),
              ]),
            ],
            const SizedBox(height: 16),
            const Spacer(),
            SizedBox(
              height: 46,
              child: Row(children: [
                _UndoHeart(word: w, canUndo: widget.canUndo, onUndo: widget.onUndo),
                if (checked == null) ...[
                  const SizedBox(width: 18),
                  Tap(
                    label: '提示，填入下一個字母',
                    onTap: _hint,
                    child: Row(children: [
                      Icon(Icons.lightbulb_outline_rounded, size: 19, color: p.sec),
                      const SizedBox(width: 3),
                      Text('提示', style: ts(F.sub, w: w6, c: p.sec)),
                    ]),
                  ),
                ],
                const Spacer(),
                if (checked == false) ...[
                  if (_retype == null) ...[
                    PillButton(
                      label: '再打一次',
                      height: 46,
                      width: 104,
                      onTap: () {
                        setState(() {
                          _retype = _nearMiss ? Grade.unsure : Grade.again;
                          _setText('');
                          _checked = null;
                          _hints = 0;
                        });
                        WidgetsBinding.instance.addPostFrameCallback((_) => _startTyping());
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                  PillButton(
                    label: '下一題',
                    height: 46,
                    width: 96,
                    fill: p.accent,
                    fg: p.onAccent,
                    onTap: () => widget.onGrade(_retype ?? (_nearMiss ? Grade.unsure : Grade.again)),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  /// 目前只用來區分放棄和拼錯；留著讓測試能確認狀態
  @visibleForTesting
  bool get gaveUp => _gaveUp;
}
