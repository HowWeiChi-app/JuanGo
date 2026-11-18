// 主頁：今天的進度、開始學習、清單、考古題和字庫。排版照 iOS 版 StudyTab。

import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'dictionary.dart';
import 'exam.dart';
import 'models.dart';
import 'settings.dart';
import 'sheets.dart';
import 'store.dart';
import 'study_flow.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.onFindWords});
  final VoidCallback onFindWords;

  AppStore get _store => AppStore.shared;
  AppSettings get _settings => AppSettings.shared;

  /// 最近兩週裡，最後一次答「不會」的字
  List<Word> _recentlyMissed() {
    final since = DateTime.now().subtract(const Duration(days: 14));
    final latest = <String, int>{};
    for (final l in _store.logs.reversed) {
      if (l.date.isBefore(since)) break;
      latest.putIfAbsent(l.term, () => l.result);
    }
    final missed = {for (final e in latest.entries) if (e.value == Grade.again.index) e.key};
    return missed.isEmpty ? const [] : _store.words.where((w) => missed.contains(w.term)).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appData,
      builder: (context, _) {
        final p = Palette.of(context);
        final stats = _store.stats;
        final newLeft = max(0, _settings.dailyGoal - stats.newToday);
        final studyable = _store.studyable.toList();
        final due = studyable.where((w) => w.isDue).toList();
        final fresh = studyable.where((w) => w.isNew).toList()..sort((a, b) => a.addedAt.compareTo(b.addedAt));
        final newWords = fresh.take(newLeft).toList();
        final today = [...due, ...newWords];
        final missed = _recentlyMissed();

        return LargePage(title: '主頁', slivers: [
          Sec(header: monthDayWeekFull(DateTime.now()), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Column(children: [
                _todayRing(context, p, stats, due.length),
                const SizedBox(height: 16),
                _startButton(context, p, today, studyable, newLeft),
              ]),
            ),
          ]),
          Sec(children: [
            _actionRow(
              p,
              '自由練習',
              '沒學會的字隨機考',
              Icon(Icons.all_inclusive_rounded, size: 24, color: p.accent),
              studyable.isEmpty ? null : () => startStudy(context, '自由練習', studyable.where((w) => !w.isMastered).toList()..shuffle()),
            ),
            _actionRow(p, '學習紀錄', '每天練了哪些字', Icon(Icons.calendar_month_rounded, size: 23, color: p.accent),
                () => showHistory(context, _store.logs.reversed.toList())),
          ]),
          Sec(header: '我的清單', children: [
            _listRow(context, p, '我的單字', Icons.menu_book_rounded, _store.words.where((w) => w.inMyWords).toList()),
            _listRow(context, p, '喜歡', Icons.favorite_rounded, _store.words.where((w) => w.favorite).toList()),
            for (final l in _store.lists) _listRow(context, p, l.name, Icons.folder_rounded, _store.wordsIn(l)),
            if (missed.isNotEmpty) _listRow(context, p, '最近答錯', Icons.error_rounded, missed),
          ]),
          if (ExamStore.all.isNotEmpty)
            Sec(header: '大考考古題', footer: '題目與答案取自大考中心公布的學測英文試題。', children: [
              for (final e in ExamStore.all)
                _actionRow(
                  p,
                  e.title,
                  '${e.questionCount} 題・詞彙 綜合 文意 篇章 閱讀',
                  Text('${e.year}', style: ts(F.sub, w: w7, c: p.hsnuNavy)),
                  () => presentFull(context, ExamView(exam: e)),
                ),
            ]),
          Sec(children: [
            Padding(padding: const EdgeInsets.all(16), child: MasteryLadder(distribution: Stats(const [], studyable).distribution)),
          ]),
          Sec(header: '大考詞彙', children: [for (final d in Deck.examDecks) _deckRow(context, p, d)]),
          Sec(
            header: '國中小・檢定考試',
            footer: '會把還沒學過的字加入「我的單字」。',
            children: [for (final d in Deck.testDecks) _deckRow(context, p, d)],
          ),
        ]);
      },
    );
  }

  Widget _todayRing(BuildContext context, Palette p, Stats stats, int dueCount) {
    final goal = _settings.dailyGoal;
    final progress = min(1.0, stats.newToday / max(1, goal));
    return Row(children: [
      Semantics(
        label: '今天新字 ${stats.newToday} 個，目標 $goal 個',
        child: ExcludeSemantics(
          child: SizedBox(
            width: 112,
            height: 112,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: progress),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (_, v, child) => CustomPaint(
                painter: Ring(track: p.accent.withValues(alpha: .12), parts: [(v, p.accent)], width: 12, round: true),
                child: child,
              ),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${stats.newToday}', style: ts(34, w: w7, h: 1.1)),
                  Text('/ $goal 新字', style: ts(F.cap, w: w6, c: p.sec)),
                ]),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 22),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _statLine(p, Icons.autorenew_rounded, '待複習', '$dueCount 個'),
          const SizedBox(height: 12),
          MenuBtn(
            label: '每日目標',
            entries: () => [
              for (final n in const [5, 10, 15, 20, 30, 50])
                MenuEntry('$n 個', checked: n == goal, onTap: () => _settings.update((s) => s.dailyGoal = n)),
            ],
            child: _statLine(p, Icons.track_changes_rounded, '每日目標', '$goal 個 ▾'),
          ),
          const SizedBox(height: 12),
          _statLine(p, Icons.local_fire_department_rounded, '連續', '${stats.streak} 天'),
        ]),
      ),
    ]);
  }

  Widget _statLine(Palette p, IconData icon, String label, String value) => Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 20, child: Icon(icon, size: 18, color: p.accent)),
        const SizedBox(width: 8),
        Text(label, style: ts(F.sub, c: p.sec)),
        const SizedBox(width: 8),
        Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, w: w6, c: p.ink))),
      ]);

  Widget _startButton(BuildContext context, Palette p, List<Word> today, List<Word> studyable, int newLeft) {
    final empty = today.isEmpty;
    String? hint;
    if (studyable.isEmpty) {
      hint = '先到「新增」或「探索」加入幾個單字吧。';
    } else if (empty) {
      final end = addDays(startOfDay(DateTime.now()), 2);
      final n = studyable.where((w) => !w.isNew && (w.dueDate ?? DateTime(1970)).isBefore(end)).length;
      if (n > 0) hint = '明天有 $n 個字要複習';
    }
    return Column(children: [
      PrimaryButton(
        label: empty ? (newLeft > 0 ? '去探索找新字' : '今天都完成了') : '開始今日學習',
        icon: empty ? (newLeft > 0 ? Icons.auto_awesome_rounded : Icons.check_rounded) : Icons.play_arrow_rounded,
        onTap: empty ? (newLeft > 0 ? onFindWords : null) : () => startStudy(context, '今日學習', today),
      ),
      if (hint != null) ...[const SizedBox(height: 8), Text(hint, style: ts(F.cap, c: p.sec))],
    ]);
  }

  Widget _actionRow(Palette p, String title, String sub, Widget icon, VoidCallback? onTap) => Opacity(
        opacity: onTap == null ? .4 : 1,
        child: RowTile(leading: icon, leadingWidth: 32, title: title, subtitle: sub, chevron: true, onTap: onTap),
      );

  Widget _listRow(BuildContext context, Palette p, String name, IconData icon, List<Word> words) {
    final due = words.where((w) => w.isDue).length;
    return Opacity(
      opacity: words.isEmpty ? .55 : 1,
      child: RowTile(
        leading: Icon(icon, size: 22, color: p.accent),
        leadingWidth: 32,
        title: name,
        subtitle: due > 0 ? '$due 個待複習' : null,
        value: '${words.length} 個',
        trailing: Icon(Icons.play_circle_fill_rounded, size: 24, color: words.isEmpty ? p.sec.withValues(alpha: .4) : p.accent),
        onTap: words.isEmpty ? null : () => startStudy(context, name, List.of(words)..shuffle()),
      ),
    );
  }

  Widget _deckRow(BuildContext context, Palette p, Deck d) {
    final entries = Dict.entriesOfDeck(d);
    return RowTile(
      leading: Text(d.label.substring(0, 1), style: ts(F.headline, w: w6, c: p.accent)),
      leadingWidth: 32,
      title: d.label,
      subtitle: '${entries.length} 個單字・${d.subtitle}',
      chevron: true,
      onTap: () {
        final have = _store.words.map((w) => w.term.toLowerCase()).toSet();
        final picked = entries.where((e) => !have.contains(e.w.toLowerCase())).toList()..shuffle();
        final words = [for (final e in picked.take(_settings.dailyGoal)) _store.add(e)];
        startStudy(context, d.label, words);
      },
    );
  }
}
