// JuanGo Android 版的入口：載入資料、切換新手導覽和五個分頁。

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'add_tab.dart';
import 'battle.dart';
import 'dev_update.dart';
import 'cloud.dart';
import 'demo.dart';
import 'dictionary.dart';
import 'exam.dart';
import 'explore_tab.dart';
import 'home_tab.dart';
import 'onboarding.dart';
import 'profile_tab.dart';
import 'services.dart';
import 'settings.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';
import 'words_tab.dart';
import 'word_quota.dart';
import 'word_report.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  await AppSettings.shared.load();
  runApp(const JuanGoApp());
}

class JuanGoApp extends StatefulWidget {
  const JuanGoApp({super.key});
  @override
  State<JuanGoApp> createState() => _JuanGoAppState();
}

class _JuanGoAppState extends State<JuanGoApp> {
  // 字典有 3 MB，等它載入時先顯示主題底色，不讓畫面停在白屏
  // 資料都載入後才接登入連結，同步才不會蓋到還沒讀進來的資料
  late final Future<void> _ready = Future.wait([Dict.load(), AppStore.shared.load(), ExamStore.load(), Cloud.shared.load()])
      .then((_) => Cloud.shared.listenForLinks());

  @override
  void initState() {
    super.initState();
    WordQuota.stops.addListener(_quotaStopped);
  }

  @override
  void dispose() {
    WordQuota.stops.removeListener(_quotaStopped);
    super.dispose();
  }

  void _quotaStopped() {
    final c = appNavigator.currentContext;
    if (c != null) showQuotaFull(c);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.shared,
      builder: (context, _) => MaterialApp(
        navigatorKey: appNavigator,
        title: 'JuanGo',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: AppSettings.shared.themeMode,
        builder: (context, child) {
          final dark = Theme.of(context).brightness == Brightness.dark;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarContrastEnforced: false,
            ),
            // 字放太大會擠壞固定高度的按鈕，所以設個上限
            child: MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: child!),
          );
        },
        home: FutureBuilder(
          future: _ready,
          builder: (context, snap) {
            final p = Palette.of(context);
            if (snap.hasError) {
              return Material(
                color: p.bg,
                child: const Center(child: EmptyState('資料載入失敗', icon: Icons.error_outline_rounded, message: '請關閉 App 後重新開啟。')),
              );
            }
            if (snap.connectionState != ConnectionState.done) return ColoredBox(color: p.bg);
            return const RootView();
          },
        ),
      ),
    );
  }
}

class RootView extends StatefulWidget {
  const RootView({super.key});
  @override
  State<RootView> createState() => _RootViewState();
}

class _RootViewState extends State<RootView> {
  @override
  void initState() {
    super.initState();
    Cloud.shared.addListener(_showNotice);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showNotice());
  }

  @override
  void dispose() {
    Cloud.shared.removeListener(_showNotice);
    super.dispose();
  }

  /// 從信件回到 App 時，告訴使用者登入的結果
  void _showNotice() {
    final message = Cloud.shared.notice;
    if (message == null || !mounted) return;
    Cloud.shared.notice = null;
    showAlert(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final onboarded = AppSettings.shared.onboarded;
    // 開關、滑桿和輸入框都要有 Material 祖先才畫得出來
    return Material(
      color: Palette.of(context).bg,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: onboarded ? const MainTabs(key: ValueKey('tabs')) : const OnboardingView(key: ValueKey('onboarding')),
      ),
    );
  }
}

class MainTabs extends StatefulWidget {
  const MainTabs({super.key});
  @override
  State<MainTabs> createState() => _MainTabsState();
}

class _MainTabsState extends State<MainTabs> with WidgetsBindingObserver {
  static const _icons = [
    (Icons.home_rounded, '主頁'),
    (Icons.auto_awesome_motion_rounded, '探索'),
    (Icons.add_circle_rounded, '新增'),
    (Icons.menu_book_rounded, '字庫'),
    (Icons.account_circle_rounded, '我的'),
  ];

  int _tab = demoOn ? 1 : 0;
  // 沒點開過的分頁先不建立，探索頁才不會一開 App 就念單字
  final _visited = <int>{demoOn ? 1 : 0};
  final _navs = List.generate(5, (_) => GlobalKey<NavigatorState>());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Reminders.sync();
    Cloud.shared.syncQuietly();
    WordReport.flush();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkQuota());
    // 開發版：有新版就提醒下載
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(DevUpdate.check(() => appNavigator.currentContext ?? context)));
    // 自動對戰（開發版）：一打開就進單字對戰
    unawaited(BattleAutoplay.read().then((_) {
      final c = appNavigator.currentContext;
      if (c == null || !c.mounted) return;
      final step = BattleAutoplay.demoStep;
      // ignore: invalid_use_of_visible_for_testing_member
      if (step != null) return unawaited(presentFull(c, BattlePage(model: BattleModel()..demo(step))));
      if (BattleAutoplay.delay != null) unawaited(presentFull(c, const BattlePage()));
    }));
  }

  /// 超過免費版上限時跳提醒，或到期刪字
  void _checkQuota() {
    final c = appNavigator.currentContext;
    if (c != null) QuotaCountdown.check(c);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      AppStore.shared.flush();
      Reminders.sync();
      Cloud.shared.backgroundPush();
    } else if (state == AppLifecycleState.resumed) {
      _checkQuota();
      WordReport.flush();
      Cloud.shared.syncQuietly();
    }
  }

  void _select(int i) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (i == _tab) {
      // 再點一次目前的分頁：回到這個分頁的第一層
      _navs[i].currentState?.popUntil((r) => r.isFirst);
      return;
    }
    Feedback2.light();
    setState(() {
      _tab = i;
      _visited.add(i);
    });
  }

  Widget _page(int i) => switch (i) {
        0 => HomeTab(onFindWords: () => _select(1)),
        1 => const ExploreTab(),
        2 => const AddTab(),
        3 => const WordsTab(),
        _ => const ProfileTab(),
      };

  /// Android 的返回鍵：先退分頁裡的頁面，再回主頁，最後才離開 App
  void _back() {
    final nav = _navs[_tab].currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    } else if (_tab != 0) {
      _select(0);
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final barBottom = media.padding.bottom + 10;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Material(
        color: p.bg,
        child: Stack(children: [
          Padding(
            padding: EdgeInsets.only(bottom: keyboard),
            child: MediaQuery.removeViewInsets(
              context: context,
              removeBottom: true,
              child: BottomInset(
                value: keyboard > 0 ? 16 : barBottom + 56 + 18,
                child: Stack(children: [
                  for (final i in _visited.toList()..sort())
                    AnimatedOpacity(
                      key: ValueKey(i),
                      duration: const Duration(milliseconds: 250),
                      opacity: i == _tab ? 1 : 0,
                      child: IgnorePointer(
                        ignoring: i != _tab,
                        child: TickerMode(
                          enabled: i == _tab,
                          child: Navigator(
                            key: _navs[i],
                            onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => _page(i)),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
          if (keyboard == 0)
            Positioned(
              left: 28,
              right: 28,
              bottom: barBottom,
              child: _TabBar(icons: _icons, index: _tab, onSelect: _select),
            ),
        ]),
      ),
    );
  }
}

/// 浮在內容上的膠囊分頁列，只有圖示
class _TabBar extends StatelessWidget {
  const _TabBar({required this.icons, required this.index, required this.onSelect});
  final List<(IconData, String)> icons;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      height: 56,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 18, offset: Offset(0, 5))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.all(4),
            color: p.card.withValues(alpha: .86),
            child: LayoutBuilder(builder: (context, c) {
              final w = c.maxWidth / icons.length;
              return Stack(children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: w * index,
                  top: 0,
                  bottom: 0,
                  width: w,
                  child: Container(
                    decoration: BoxDecoration(color: p.accent.withValues(alpha: .13), borderRadius: BorderRadius.circular(24)),
                  ),
                ),
                Row(children: [
                  for (final (i, (icon, label)) in icons.indexed)
                    Expanded(
                      child: Semantics(
                        selected: i == index,
                        child: Tap(
                          dim: false,
                          label: label,
                          onTap: () => onSelect(i),
                          child: Center(child: Icon(icon, size: 26, color: i == index ? p.accent : p.sec)),
                        ),
                      ),
                    ),
                ]),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}
