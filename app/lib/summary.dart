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
  Color tint(Palette p) => switch (this) {
    Grade.good => p.knowGreen,
    Grade.unsure => p.unsureYellow,
    Grade.again => p.againPink,
  };
  Color ring(Palette p) => switch (this) {
    Grade.good => p.green,
    Grade.unsure => p.orange,
    Grade.again => p.accent,
  };
}

class StreakView extends StatelessWidget {
  const StreakView({super.key, required this.stats, required this.onContinue});
  final Stats stats;
  final VoidCallback onContinue;

  /// JuanGo 自己的連續學習記號：一張撕頁桌曆，從上面翻下來
  Widget _calendarPage(Palette p, int streak) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 900),
    curve: Curves.easeOutBack,
    builder: (_, v, child) => Opacity(
      opacity: v.clamp(0, 1),
      child: Transform(
        alignment: Alignment.topCenter,
        transform: Matrix4.identity()
          ..setEntry(3, 2, .0015)
          ..rotateX(-1.4 * (1 - v)),
        child: child,
      ),
    ),
    child: Semantics(
      label: '連續學習 $streak 天',
      excludeSemantics: true,
      child: Container(
        width: 200,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: BorderRadius.circular(26),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .12),
              blurRadius: 36,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          children: [
            Container(
              height: 58,
              color: p.accent,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    top: 10,
                    left: 0,
                    right: 0,
                    child: Row(
                      children: [
                        for (var i = 0; i < 2; i++)
                          Expanded(
                            child: Center(
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: p.onAccent.withValues(alpha: .85),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Positioned(
                    bottom: 10,
                    child: Text(
                      '連續學習',
                      style: ts(F.sub, w: w7, c: p.onAccent),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              child: Column(
                children: [
                  FittedBox(
                    child: Text('$streak', style: ts(96, w: w7, h: 1.1)),
                  ),
                  Text(
                    '天',
                    style: ts(F.title3, w: w6, c: p.sec),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 最近七天：有學習的格子打勾，今天加外框
  Widget _weekStrip(Palette p) {
    final today = startOfDay(DateTime.now());
    final days = [for (var i = 6; i >= 0; i--) addDays(today, -i)];
    return CardBox(
      padding: 14,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final d in days)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Column(
                children: [
                  Text(
                    weekdayNames[d.weekday - 1],
                    style: ts(F.cap2, w: w7, c: p.sec),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    width: 32,
                    height: 40,
                    decoration: BoxDecoration(
                      color: stats.activeDays.contains(d)
                          ? p.accent
                          : p.sec.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(10),
                      border: d == today && !stats.activeDays.contains(d)
                          ? Border.all(color: p.accent, width: 2)
                          : null,
                    ),
                    child: stats.activeDays.contains(d)
                        ? Icon(Icons.check_rounded, size: 20, color: p.onAccent)
                        : null,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 下一枚連續勳章，還差幾天
  Widget _nextMedal(Palette p, int streak) {
    final kind = BadgeKind.all.first;
    final next = kind.next(streak);
    final tier = kind.earned(streak);
    final all = tier >= kind.tiers.length;
    final previous = tier == 0 ? 0 : kind.tiers[tier - 1];
    final progress = all
        ? 1.0
        : ((streak - previous) / (next - previous).clamp(1, 1 << 30)).clamp(
            0.0,
            1.0,
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Row(
        children: [
          Opacity(
            opacity: all ? 1 : .55,
            child: MedalCoin(
              tier: all ? tier : tier + 1,
              icon: Icons.local_fire_department_rounded,
              size: 44,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  all
                      ? '已拿到所有連續勳章'
                      : '再 ${next - streak} 天拿到第 ${tier + 1} 級連續勳章',
                  style: ts(F.sub, w: w6),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Container(
                    height: 5,
                    color: p.sec.withValues(alpha: .15),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress,
                      child: Container(color: p.accent),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final streak = stats.streak;
    return ColoredBox(
      color: p.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Tap(
                  label: '分享',
                  onTap: () => SharePlus.instance.share(
                    ShareParams(text: '我在 JuanGo 已經連續學習 $streak 天了！'),
                  ),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: p.fill,
                    ),
                    child: Icon(
                      Icons.ios_share_rounded,
                      size: 21,
                      color: p.ink,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              _calendarPage(p, streak),
              const SizedBox(height: 24),
              _weekStrip(p),
              const SizedBox(height: 24),
              _nextMedal(p, streak),
              const Spacer(),
              PrimaryButton(label: '繼續', onTap: onContinue),
            ],
          ),
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
    int rank(Grade g) =>
        const {Grade.again: 0, Grade.unsure: 1, Grade.good: 2}[g]!;
    final sorted = results.indexed.toList()
      ..sort((a, b) {
        final c = rank(a.$2.grade).compareTo(rank(b.$2.grade));
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    final missed = results
        .where((r) => r.grade == Grade.again)
        .map((r) => r.word)
        .toList();
    return CardBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('這輪的字', style: ts(F.headline, w: w7)),
              ),
              for (final g in const [Grade.good, Grade.unsure, Grade.again])
                if (_count(g) > 0)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: g.tint(p),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '${g.label} ${_count(g)}',
                      style: ts(F.cap, w: w7),
                    ),
                  ),
            ],
          ),
          const SizedBox(height: 12),
          for (final (i, (_, r)) in sorted.indexed) ...[
            Tap(
              dim: false,
              onTap: () => showWordDetail(context, r.word),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.word.term, style: ts(F.headline, w: w6)),
                        const SizedBox(height: 2),
                        Text(
                          r.word.primaryMeaning,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(F.sub, c: p.sec),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    levelName(r.word.srsLevel),
                    style: ts(F.cap, w: w7, c: p.accent),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: r.grade.ring(p),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.chevron_right_rounded, size: 20, color: p.ter),
                ],
              ),
            ),
            if (i < sorted.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Container(height: .5, color: p.separator),
              ),
          ],
          if (missed.isNotEmpty) ...[
            const SizedBox(height: 14),
            PillButton(
              label: '只練答錯的 ${missed.length} 個字',
              icon: Icons.replay_rounded,
              height: 44,
              onTap: () => onRetry(missed),
            ),
          ],
        ],
      ),
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
        final left = s.goal - stats.newToday;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  media.padding.top + 30,
                  20,
                  20,
                ),
                children: [
                  Text('這一輪完成了', style: ts(F.largeTitle, w: w7)),
                  const SizedBox(height: 18),
                  Text(
                    '共 $roundCount 個字・今天新學 ${stats.newToday} 個・連續 ${stats.streak} 天',
                    style: ts(F.sub, w: w6, c: p.sec),
                  ),
                  const SizedBox(height: 18),
                  CardBox(
                    padding: 20,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 140,
                          height: 140,
                          child: ScoreRing(
                            good: _count(Grade.good),
                            unsure: _count(Grade.unsure),
                            again: _count(Grade.again),
                          ),
                        ),
                        const SizedBox(width: 22),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final g in const [
                              Grade.good,
                              Grade.unsure,
                              Grade.again,
                            ])
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 5,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: g.ring(p),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(g.label, style: ts(F.sub, c: p.sec)),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${_count(g)}',
                                      style: ts(F.sub, w: w7),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (!s.reminderAsked && !s.reminderOn) ...[
                    const SizedBox(height: 18),
                    CardBox(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.notifications_active_rounded,
                                size: 20,
                                color: p.accent,
                              ),
                              const SizedBox(width: 6),
                              Text('每天提醒你回來練習？', style: ts(F.headline, w: w6)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '每天 ${s.reminderText} 通知你，複習才不會中斷。',
                            style: ts(F.sub, c: p.sec),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: PillButton(
                                  label: '先不要',
                                  height: 44,
                                  onTap: () =>
                                      s.update((x) => x.reminderAsked = true),
                                ),
                              ),
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
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (results.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _resultsCard(context, p),
                  ],
                  const SizedBox(height: 18),
                  Text('成就', style: ts(F.title3, w: w7)),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final k in BadgeKind.all)
                        Expanded(
                          child: BadgeMedal(
                            kind: k,
                            value: k.value(stats),
                            size: 52,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              color: p.bg,
              padding: EdgeInsets.fromLTRB(
                20,
                10,
                20,
                10 + media.padding.bottom,
              ),
              child: Row(
                children: [
                  PillButton(
                    label: '結束',
                    height: 54,
                    width: 110,
                    onTap: onDone,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: PrimaryButton(
                      label: left > 0 ? '再練一輪・目標還差 $left 字' : '再練一輪',
                      height: 54,
                      onTap: onAgain,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
