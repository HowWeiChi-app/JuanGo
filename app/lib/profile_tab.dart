// 我的：連續天數、統計、日曆、成就，以及設定。排版照 iOS 版 ProfileTab。

import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'about_page.dart';
import 'account_page.dart';
import 'battle.dart';
import 'cloud.dart';
import 'dictionary.dart';
import 'models.dart';
import 'onboarding.dart';
import 'pro.dart';
import 'services.dart';
import 'settings.dart';
import 'sheets.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';
import 'words_tab.dart';

AppStore get _store => AppStore.shared;
AppSettings get _settings => AppSettings.shared;

/// Android 的字體選項；編號和 iOS 相同（1 是 iOS 才有的圓體）
const fontOptions = [(0, '系統'), (2, '襯線'), (3, '等寬')];
const appearanceOptions = [(0, '跟隨系統'), (1, '淺色'), (2, '深色')];

class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});
  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  DateTime? _selected;

  Widget _streakCard(Palette p, Stats s) => Padding(
    padding: const EdgeInsets.all(16),
    child: Row(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Icon(
            Icons.local_fire_department_rounded,
            size: 40,
            color: p.accent,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('${s.streak}', style: ts(40, w: w7, h: 1.1)),
                  const SizedBox(width: 4),
                  Text('天連續學習', style: ts(F.headline, w: w6)),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                s.studiedToday > 0 ? '今天已經練過了，明天見！' : '今天還沒練習，別讓火熄掉。',
                style: ts(F.sub, c: p.sec),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _statRow(Palette p, String title, int n, IconData icon) => RowTile(
    leading: Icon(icon, size: 22, color: p.accent),
    title: title,
    trailing: Text('$n', style: ts(F.body, w: w6)),
  );

  Widget _calendar(BuildContext context, Palette p, Stats s) {
    final today = startOfDay(DateTime.now());
    final weekStart = addDays(today, -(today.weekday - 1));
    final first = addDays(weekStart, -28);
    final days = [for (var i = 0; i < 35; i++) addDays(first, i)];
    final counts = days.map(s.count).toList();
    final top = max(1, counts.reduce(max));
    final chosen = _selected ?? today;
    final n = s.count(chosen);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('學習日曆', style: ts(F.headline, w: w7)),
              ),
              Text(
                '近 5 週・${counts.where((c) => c > 0).length} 天有練習',
                style: ts(F.cap, w: w6, c: p.sec),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final (i, d) in weekdayNames.indexed) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: Center(
                    child: Text(
                      d,
                      style: ts(F.cap2, w: w7, c: p.sec),
                    ),
                  ),
                ),
              ],
            ],
          ),
          for (var week = 0; week < 5; week++) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                for (var wd = 0; wd < 7; wd++) ...[
                  if (wd > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _dayCell(
                      p,
                      days[week * 7 + wd],
                      counts[week * 7 + wd],
                      top,
                      today,
                      chosen,
                    ),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 12),
          Tap(
            dim: false,
            onTap: n == 0
                ? null
                : () => showHistory(
                    context,
                    _store.logs.reversed
                        .where((l) => sameDay(l.date, chosen))
                        .toList(),
                  ),
            child: Row(
              children: [
                Expanded(child: Text(monthDayWeek(chosen), style: ts(F.sub))),
                Text('練了 $n 個字', style: ts(F.sub, w: w7)),
                if (n > 0)
                  Icon(Icons.chevron_right_rounded, size: 20, color: p.ter),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dayCell(
    Palette p,
    DateTime d,
    int n,
    int top,
    DateTime today,
    DateTime chosen,
  ) {
    final future = d.isAfter(today);
    final strong = n > 0 && n / top > .4;
    final selected = sameDay(d, chosen);
    return Tap(
      dim: false,
      label: '${monthDay(d)}，${n == 0 ? '沒有練習' : '練了 $n 個字'}',
      onTap: future ? null : () => setState(() => _selected = d),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: future
                ? Colors.transparent
                : (n == 0
                      ? p.sec.withValues(alpha: .10)
                      : p.accent.withValues(alpha: .25 + .75 * n / top)),
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(
              color: selected
                  ? p.ink
                  : (future
                        ? p.sec.withValues(alpha: .25)
                        : Colors.transparent),
              width: 1.5,
            ),
          ),
          child: Text(
            '${d.day}',
            style: ts(10, w: w6, c: strong ? p.onAccent : p.sec),
          ),
        ),
      ),
    );
  }

  Widget _badges(Palette p, Stats s) {
    final earned = BadgeKind.all.fold<int>(
      0,
      (n, k) => n + k.earned(k.value(s)),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('成就', style: ts(F.headline, w: w7)),
              ),
              Text(
                '已解鎖 $earned 枚',
                style: ts(F.cap, w: w6, c: p.sec),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final k in BadgeKind.all)
                Expanded(
                  child: BadgeMedal(kind: k, value: k.value(s), size: 56),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: appData,
      builder: (context, _) {
        final s = _store.stats;
        return LargePage(
          title: '我的',
          actions: [
            BarIcon(
              icon: Icons.tune_rounded,
              label: '設定',
              onTap: () => presentSheet(context, (_) => const SettingsPage()),
            ),
          ],
          slivers: [
            Sec(children: [_streakCard(p, s)]),
            Sec(
              header: '統計',
              children: [
                _statRow(p, '今天練習', s.studiedToday, Icons.checklist_rounded),
                _statRow(p, '學過的字', s.learnedTotal, Icons.auto_stories_rounded),
                _statRow(
                  p,
                  '精通',
                  s.masteredTotal,
                  Icons.workspace_premium_rounded,
                ),
                _statRow(p, '待複習', s.dueCount, Icons.autorenew_rounded),
              ],
            ),
            Sec(children: [_calendar(context, p, s)]),
            Sec(children: [_badges(p, s)]),
            Sec(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: MasteryLadder(distribution: s.distribution),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

// MARK: 設定

/// 設定是底部頁面，裡面有自己的頁面堆疊；Android 返回鍵先退回上一層設定
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _nav = GlobalKey<NavigatorState>();
  // 只能建立一次：每次重畫都換新的話，頁面層數會被算錯
  late final _observer = _DepthObserver((depth) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _nested != (depth > 1))
        setState(() => _nested = depth > 1);
    });
  });
  bool _nested = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_nested,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _nav.currentState?.maybePop();
      },
      child: Navigator(
        key: _nav,
        observers: [_observer],
        onGenerateRoute: (_) =>
            PageRouteBuilder(pageBuilder: (_, _, _) => const _SettingsRoot()),
      ),
    );
  }
}

class _DepthObserver extends NavigatorObserver {
  _DepthObserver(this.onChange);
  final ValueChanged<int> onChange;
  int _depth = 0;
  void _set(int d) {
    _depth = d;
    onChange(_depth);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) =>
      _set(_depth + 1);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previous) =>
      _set(_depth - 1);
}

void _closeSettings(BuildContext c) =>
    Navigator.of(c, rootNavigator: true).pop();

class _SubPage extends StatelessWidget {
  const _SubPage(this.title, this.slivers);
  final String title;
  final List<Widget> Function(Palette) slivers;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppSettings.shared,
    builder: (context, _) => NavPage(
      title: title,
      safeTop: false,
      slivers: slivers(Palette.of(context)),
    ),
  );
}

class _SettingsRoot extends StatelessWidget {
  const _SettingsRoot();

  Widget _row(
    BuildContext c,
    Palette p,
    IconData icon,
    String title,
    String sub,
    Widget Function() page,
  ) => RowTile(
    leading: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: p.accent,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Icon(icon, size: 17, color: p.onAccent),
    ),
    leadingWidth: 30,
    titleWidget: Text(title, style: ts(F.headline, w: w6)),
    subtitle: sub,
    chevron: true,
    onTap: () => pushPage(c, page()),
  );

  void _pickReminder(BuildContext c) => showTimeWheel(
    c,
    _settings.reminderMinutes,
    (m) => _settings.update((x) => x.reminderMinutes = m),
  );

  Widget _goalPage() => _SubPage('每日計畫', (p) {
    final s = _settings;
    final manual = !s.examOn;
    return [
      Sec(
        header: '考前倒數',
        footer: '依考試日期和還沒學過的字，自動算出每天要學幾個新字；字不夠時會從大考詞彙補進「我的單字」。考前兩週只複習。',
        children: [
          SwitchRow(
            title: '考前倒數',
            value: s.examOn,
            onChanged: (v) => s.update((x) => x.examOn = v),
          ),
          if (s.examOn) ...[
            Builder(
              builder: (c) => RowTile(
                title: '考試',
                value: s.examName,
                chevron: true,
                onTap: () => showAppMenu(c, [
                  for (final n in ExamPlan.names)
                    MenuEntry(
                      n,
                      checked: n == s.examName,
                      onTap: () => s.update((x) => x.examName = n),
                    ),
                ]),
              ),
            ),
            Builder(
              builder: (c) => RowTile(
                title: '考試日期',
                value: '${s.examDate.year}年${monthDay(s.examDate)}',
                chevron: true,
                onTap: () => showDateWheel(
                  c,
                  '考試日期',
                  s.examDate,
                  (d) => s.update((x) => x.examDate = d),
                ),
              ),
            ),
            Builder(
              builder: (c) => RowTile(
                title: '要學完',
                value: '大考第 1–${s.examTop} 級',
                chevron: true,
                onTap: () => showAppMenu(c, [
                  for (final t in const [2, 4, 6])
                    MenuEntry(
                      '大考第 1–$t 級',
                      checked: t == s.examTop,
                      onTap: () => s.update((x) => x.examTop = t),
                    ),
                ]),
              ),
            ),
          ],
        ],
      ),
      Sec(
        header: '每日新字',
        children: [
          Opacity(
            opacity: manual ? 1 : .45,
            child: RowTile(
              title: '${s.dailyGoal} 個 / 天',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleBtn(
                    icon: Icons.remove_rounded,
                    label: '減少',
                    size: 34,
                    onTap: manual && s.dailyGoal > 1
                        ? () => s.update((x) => x.dailyGoal -= 1)
                        : null,
                  ),
                  const SizedBox(width: 8),
                  CircleBtn(
                    icon: Icons.add_rounded,
                    label: '增加',
                    size: 34,
                    onTap: manual && s.dailyGoal < 100
                        ? () => s.update((x) => x.dailyGoal += 1)
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      Sec(
        header: '單字程度',
        children: [
          for (final lv in examLevels)
            RowTile(
              title: '${levelLabel(lv)}・${LevelTest.blurb(lv)}',
              trailing: s.level == lv
                  ? Icon(Icons.check_rounded, size: 20, color: p.accent)
                  : null,
              onTap: () => s.update((x) => x.level = lv),
            ),
        ],
      ),
    ];
  });

  Widget _practicePage() => _SubPage('答題與發音', (p) {
    final s = _settings;
    return [
      Sec(
        children: [
          SwitchRow(
            title: '顯示例句翻譯',
            value: s.showTranslation,
            onChanged: (v) => s.update((x) => x.showTranslation = v),
          ),
          SwitchRow(
            title: '自動唸單字',
            value: s.autoSpeak,
            onChanged: (v) => s.update((x) => x.muted = !v),
          ),
          SwitchRow(
            title: '震動回饋',
            value: s.haptics,
            onChanged: (v) => s.update((x) => x.haptics = v),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('發音速度', style: ts(F.body)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.slow_motion_video_rounded,
                      size: 18,
                      color: p.sec,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: s.speechRate.clamp(.3, .6),
                        min: .3,
                        max: .6,
                        onChanged: (v) => s.update((x) => x.speechRate = v),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(Icons.speed_rounded, size: 18, color: p.sec),
                  ],
                ),
              ],
            ),
          ),
          RowTile(
            title: '試聽',
            titleColor: p.accent,
            onTap: () => Speech.say('resilient'),
          ),
          RowTile(
            title: '重新顯示學習規則與探索教學',
            titleColor: p.accent,
            onTap: () => s.update((x) {
              x.studyRulesSeen = false;
              x.exploreTipsDone = false;
            }),
          ),
        ],
      ),
    ];
  });

  Widget _reminderPage() => _SubPage('每日提醒', (p) {
    final s = _settings;
    return [
      Sec(
        children: [
          SwitchRow(
            title: '每日提醒',
            value: s.reminderOn,
            onChanged: (v) => s.update((x) => x.reminderOn = v),
          ),
          if (s.reminderOn)
            Builder(
              builder: (c) => RowTile(
                title: '提醒時間',
                value: s.reminderText,
                chevron: true,
                onTap: () => _pickReminder(c),
              ),
            ),
        ],
      ),
    ];
  });

  Widget _togglePage(String title, List<Widget> Function(AppSettings) rows) =>
      _SubPage(title, (_) => [Sec(children: rows(_settings))]);

  Future<void> _export(BuildContext c) async {
    try {
      await shareJson(_store.fullBackup());
    } catch (e) {
      if (c.mounted) showAlert(c, '匯出失敗：$e');
    }
  }

  Future<void> _restore(BuildContext c) async {
    try {
      final file = await pickTextFile(extensions: const ['json']);
      if (file == null || !c.mounted) return;
      await confirmImport(
        c,
        AppStore.parseFile(file.$2),
        (r) => showAlert(c, '還原完成：$r'),
      );
    } on FormatException catch (e) {
      if (c.mounted) showAlert(c, e.message);
    } catch (_) {
      if (c.mounted) showAlert(c, '這個檔案讀不出來');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appData, Cloud.shared]),
      builder: (context, _) {
        final p = Palette.of(context);
        final s = _settings;
        final account = Cloud.shared.session;
        final fontName = fontOptions
            .firstWhere(
              (f) => f.$1 == s.fontStyle,
              orElse: () => fontOptions.first,
            )
            .$2;
        return NavPage(
          title: '設定',
          safeTop: false,
          leading: const SizedBox.shrink(),
          actions: [BarText('完成', onTap: () => _closeSettings(context))],
          slivers: [
            Sec(
              children: [
                _row(
                  context,
                  p,
                  Icons.auto_awesome_rounded,
                  '捲字 Pro',
                  ProStore.shared.plan == null
                      ? '免費版'
                      : '${ProStore.shared.plan!.label}${ProStore.shared.devUnlocked ? '・開發版' : ''}',
                  () => const ProSettingsPage(),
                ),
              ],
            ),
            Sec(
              header: '學習',
              children: [
                _row(
                  context,
                  p,
                  Icons.track_changes_rounded,
                  '每日計畫',
                  '每日新字與單字程度',
                  _goalPage,
                ),
                _row(
                  context,
                  p,
                  Icons.school_rounded,
                  '答題與發音',
                  '例句翻譯、發音與震動',
                  _practicePage,
                ),
                _row(
                  context,
                  p,
                  Icons.notifications_rounded,
                  '每日提醒',
                  s.reminderOn ? '每天 ${s.reminderText}' : '關閉',
                  _reminderPage,
                ),
              ],
            ),
            Sec(
              header: '單字',
              children: [
                _row(
                  context,
                  p,
                  Icons.text_fields_rounded,
                  '單字顯示',
                  '中文意思、音標與自動發音',
                  () {
                    return _togglePage(
                      '單字顯示',
                      (s) => [
                        SwitchRow(
                          title: '清單顯示中文意思',
                          value: s.listShowMeaning,
                          onChanged: (v) =>
                              s.update((x) => x.listShowMeaning = v),
                        ),
                        SwitchRow(
                          title: '單字卡顯示音標',
                          value: s.exploreShowIPA,
                          onChanged: (v) =>
                              s.update((x) => x.exploreShowIPA = v),
                        ),
                        SwitchRow(
                          title: '查看單字時自動發音',
                          value: s.detailAutoSpeak,
                          onChanged: (v) =>
                              s.update((x) => x.detailAutoSpeak = v),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
            Sec(
              header: '外觀',
              children: [
                MenuBtn(
                  label: '外觀',
                  entries: () => [
                    for (final (v, name) in appearanceOptions)
                      MenuEntry(
                        name,
                        checked: s.appearance == v,
                        onTap: () => s.update((x) => x.appearance = v),
                      ),
                  ],
                  child: RowTile(
                    title: '外觀',
                    value: appearanceOptions[s.appearance.clamp(0, 2)].$2,
                    trailing: Icon(
                      Icons.unfold_more_rounded,
                      size: 17,
                      color: p.sec,
                    ),
                  ),
                ),
                MenuBtn(
                  label: '字體',
                  entries: () => [
                    for (final (v, name) in fontOptions)
                      MenuEntry(
                        name,
                        checked: fontName == name,
                        onTap: () => s.update((x) => x.fontStyle = v),
                      ),
                  ],
                  child: RowTile(
                    title: '字體',
                    value: fontName,
                    trailing: Icon(
                      Icons.unfold_more_rounded,
                      size: 17,
                      color: p.sec,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ThemeGrid(
                    selection: s.themeID,
                    onSelect: (id) => s.update((x) => x.themeID = id),
                  ),
                ),
              ],
            ),
            Sec(
              header: '帳號',
              children: [
                _row(
                  context,
                  p,
                  Icons.account_circle_rounded,
                  '帳號登入',
                  account == null ? '登入後可雲端備份和單字對戰' : '已登入 ${account.email}',
                  () => const AccountPage(),
                ),
              ],
            ),
            if (account != null)
              Sec(
                header: '單字對戰',
                children: [
                  _row(
                    context,
                    p,
                    Icons.back_hand_rounded,
                    '排行榜與封鎖',
                    '不顯示在排行榜、已封鎖的玩家',
                    () => const BattleSettingsPage(),
                  ),
                ],
              ),
            Sec(
              header: '備份',
              footer: '匯出的檔案包含單字、進度、清單和設定。',
              children: [
                RowTile(
                  title: '匯出備份',
                  titleColor: p.accent,
                  onTap: () => _export(context),
                ),
                RowTile(
                  title: '從備份還原',
                  titleColor: p.accent,
                  onTap: () => _restore(context),
                ),
              ],
            ),
            Sec(
              header: '資料',
              children: [
                RowTile(
                  title: '重設所有學習進度',
                  titleColor: p.accent,
                  onTap: () => confirmAction(
                    context,
                    '重設所有學習進度？',
                    message: '單字會保留，但熟練度和學習紀錄會歸零。',
                    label: '重設',
                    onConfirm: _store.resetProgress,
                  ),
                ),
                RowTile(
                  title: '清除所有單字與紀錄',
                  titleColor: p.destructive,
                  onTap: () => confirmAction(
                    context,
                    '清除所有單字與紀錄？',
                    message: '這個動作無法復原。',
                    label: '全部清除',
                    onConfirm: _store.wipe,
                  ),
                ),
                RowTile(
                  title: '重新進行新手導覽',
                  titleColor: p.accent,
                  onTap: () {
                    _closeSettings(context);
                    s.update((x) => x.onboarded = false);
                  },
                ),
              ],
            ),
            Sec(
              footer: '大考詞彙和學測考古題永遠免費。資料來源、授權和隱私說明請見「關於與授權」。',
              children: [
                RowTile(title: '字典', value: '${Dict.all.length} 個內建單字'),
                const RowTile(title: '版本', value: '0.2.0'),
                RowTile(
                  title: '關於與授權',
                  chevron: true,
                  onTap: () => pushPage(context, const AboutPage()),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
