// 一輪結束後的畫面：連續天數和總結。排版照 iOS 版 Summary.swift。

import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'models.dart';
import 'settings.dart';
import 'sheets.dart';
import 'study_flow.dart';
import 'theme.dart';
import 'widgets.dart';

extension GradeStyle on Grade {
  Color tint(Palette p) => switch (this) { Grade.good => p.knowGreen, Grade.unsure => p.unsureYellow, Grade.again => p.againPink };
  Color ring(Palette p) => switch (this) { Grade.good => p.green, Grade.unsure => p.orange, Grade.again => p.accent };
}

class StreakView extends StatelessWidget {
  const StreakView({super.key, required this.stats, required this.onContinue});
  final Stats stats;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final streak = stats.streak;
    final next = BadgeKind.all.first.next(streak);
    final today = startOfDay(DateTime.now());
    final days = [for (var i = 6; i >= 0; i--) addDays(today, -i)];
    const white = Colors.white;
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Align(
              alignment: Alignment.centerRight,
              child: Tap(
                label: '分享',
                onTap: () => SharePlus.instance.share(ShareParams(text: '我在 JuanGo 已經連續學習 $streak 天了！')),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: white.withValues(alpha: .14)),
                  child: const Icon(Icons.ios_share_rounded, size: 21, color: white),
                ),
              ),
            ),
            const Spacer(),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: .5, end: 1),
              duration: const Duration(milliseconds: 800),
              curve: Curves.elasticOut,
              builder: (_, s, child) => Transform.scale(scale: s, child: child),
              child: SizedBox(
                width: 220,
                height: 220,
                child: Stack(alignment: Alignment.center, children: [
                  const Icon(Icons.water_drop_rounded, size: 220, color: Color(0xFFB8B8B8)),
                  Transform.translate(offset: const Offset(0, 30), child: Icon(Icons.local_fire_department_rounded, size: 92, color: p.accent)),
                ]),
              ),
            ),
            const SizedBox(height: 22),
            Text('$streak', style: ts(80, w: w6, c: white, h: 1)),
            const SizedBox(height: 10),
            Text('天連續學習', style: ts(F.title3, w: w7, c: white)),
            const SizedBox(height: 22),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (final d in days)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(children: [
                    SizedBox(
                      width: 30,
                      height: 30,
                      child: stats.activeDays.contains(d)
                          ? Icon(Icons.local_fire_department_rounded, size: 26, color: p.accent)
                          : DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: white.withValues(alpha: .12))),
                    ),
                    const SizedBox(height: 6),
                    Text(weekdayNames[d.weekday - 1], style: ts(F.cap2, w: w7, c: white.withValues(alpha: .6))),
                  ]),
                ),
            ]),
            const SizedBox(height: 22),
            Text(streak >= next ? '已解鎖所有連續勳章' : '再 ${next - streak} 天解鎖下一枚連續勳章', style: ts(F.sub, c: white.withValues(alpha: .7))),
            const Spacer(),
            PillButton(label: '繼續', fill: white, fg: Colors.black, width: 160, onTap: onContinue),
          ]),
        ),
      ),
    );
  }
}

class SummaryView extends StatelessWidget {
  const SummaryView({
    super.key,
    required this.stats,
    required this.roundCount,
    required this.results,
    required this.onAgain,
    required this.onDone,
    required this.onRetry,
  });
  final Stats stats;
  final int roundCount;
  final List<RoundResult> results;
  final VoidCallback onAgain, onDone;
  final ValueChanged<List<Word>> onRetry;

  int _count(Grade g) => results.where((r) => r.grade == g).length;

  Widget _resultsCard(BuildContext context, Palette p) {
    int rank(Grade g) => const {Grade.again: 0, Grade.unsure: 1, Grade.good: 2}[g]!;
    final sorted = results.indexed.toList()
      ..sort((a, b) {
        final c = rank(a.$2.grade).compareTo(rank(b.$2.grade));
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    final missed = results.where((r) => r.grade == Grade.again).map((r) => r.word).toList();
    return CardBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('這輪的字', style: ts(F.headline, w: w7))),
          for (final g in const [Grade.good, Grade.unsure, Grade.again])
            if (_count(g) > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: g.tint(p), borderRadius: BorderRadius.circular(14)),
                child: Text('${g.label} ${_count(g)}', style: ts(F.cap, w: w7)),
              ),
        ]),
        const SizedBox(height: 12),
        for (final (i, (_, r)) in sorted.indexed) ...[
          Tap(
            dim: false,
            onTap: () => showWordDetail(context, r.word),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.word.term, style: ts(F.headline, w: w6)),
                  const SizedBox(height: 2),
                  Text(r.word.primaryMeaning, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, c: p.sec)),
                ]),
              ),
              Text(levelName(r.word.srsLevel), style: ts(F.cap, w: w7, c: p.accent)),
              const SizedBox(width: 8),
              Container(width: 12, height: 12, decoration: BoxDecoration(color: r.grade.ring(p), borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, size: 20, color: p.ter),
            ]),
          ),
          if (i < sorted.length - 1)
            Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Container(height: .5, color: p.separator)),
        ],
        if (missed.isNotEmpty) ...[
          const SizedBox(height: 14),
          PillButton(label: '只練答錯的 ${missed.length} 個字', icon: Icons.replay_rounded, height: 44, onTap: () => onRetry(missed)),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final media = MediaQuery.of(context);
    return ListenableBuilder(
      listenable: AppSettings.shared,
      builder: (context, _) {
        final s = AppSettings.shared;
        final left = s.dailyGoal - stats.newToday;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(20, media.padding.top + 30, 20, 20),
              children: [
                Text('這一輪完成了', style: ts(F.largeTitle, w: w7)),
                const SizedBox(height: 18),
                Text('共 $roundCount 個字・今天新學 ${stats.newToday} 個・連續 ${stats.streak} 天', style: ts(F.sub, w: w6, c: p.sec)),
                const SizedBox(height: 18),
                CardBox(
                  padding: 20,
                  child: Row(children: [
                    SizedBox(width: 140, height: 140, child: ScoreRing(good: _count(Grade.good), unsure: _count(Grade.unsure), again: _count(Grade.again))),
                    const SizedBox(width: 22),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final g in const [Grade.good, Grade.unsure, Grade.again])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 12, height: 12, decoration: BoxDecoration(color: g.ring(p), borderRadius: BorderRadius.circular(3))),
                            const SizedBox(width: 8),
                            Text(g.label, style: ts(F.sub, c: p.sec)),
                            const SizedBox(width: 8),
                            Text('${_count(g)}', style: ts(F.sub, w: w7)),
                          ]),
                        ),
                    ]),
                  ]),
                ),
                if (!s.reminderAsked && !s.reminderOn) ...[
                  const SizedBox(height: 18),
                  CardBox(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Icon(Icons.notifications_active_rounded, size: 20, color: p.accent),
                        const SizedBox(width: 6),
                        Text('每天提醒你回來練習？', style: ts(F.headline, w: w6)),
                      ]),
                      const SizedBox(height: 10),
                      Text('每天 ${s.reminderText} 通知你，複習才不會中斷。', style: ts(F.sub, c: p.sec)),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(child: PillButton(label: '先不要', height: 44, onTap: () => s.update((x) => x.reminderAsked = true))),
                        const SizedBox(width: 8),
                        Expanded(
                          child: PrimaryButton(
                            label: '開啟提醒',
                            height: 44,
                            onTap: () => s.update((x) {
                              x.reminderAsked = true;
                              x.reminderOn = true;
                            }),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                ],
                if (results.isNotEmpty) ...[const SizedBox(height: 18), _resultsCard(context, p)],
                const SizedBox(height: 18),
                Text('成就', style: ts(F.title3, w: w7)),
                const SizedBox(height: 18),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final k in BadgeKind.all) Expanded(child: BadgeMedal(kind: k, value: k.value(stats), size: 52)),
                ]),
              ],
            ),
          ),
          Container(
            color: p.bg,
            padding: EdgeInsets.fromLTRB(20, 10, 20, 10 + media.padding.bottom),
            child: Row(children: [
              PillButton(label: '結束', height: 54, width: 110, onTap: onDone),
              const SizedBox(width: 12),
              Expanded(child: PrimaryButton(label: left > 0 ? '再練一輪・目標還差 $left 字' : '再練一輪', height: 54, onTap: onAgain)),
            ]),
          ),
        ]);
      },
    );
  }
}
