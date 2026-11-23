
import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'pro.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';

/// 免費版 1000 字上限。iOS 的 WordQuota.swift 用同一套規則，兩邊都用 tools/word_quota_cases.json 測試。
class WordQuota {
  static const limit = 1000;

  /// 到這麼多字才顯示「已用 x / 1000」
  static const showFrom = 900;
  static const fullMessage = '免費版最多 1000 個單字，升級 Pro 就沒有上限';

  /// 這個字佔不佔 1000 個名額：在我的單字、喜歡或自訂清單裡，而且不是大考詞彙（第 1–6 級），也不是考古題答錯加入的字
  static bool counts({
    required String cefr,
    required bool fromExam,
    required bool inMyWords,
    required bool favorite,
    required bool inList,
  }) =>
      (inMyWords || favorite || inList) &&
      !fromExam &&
      !examLevels.contains(cefr);

  /// 一批要加入的字，依序哪些可以加。wanted[i] 是第 i 個字會不會多佔一個名額；
  /// 不佔名額的字一律可以加，其他的加到名額用完為止
  static List<bool> fit(
    List<bool> wanted, {
    required int used,
    required bool unlimited,
  }) {
    if (unlimited) return [for (final _ in wanted) true];
    var room = limit - used;
    final out = <bool>[];
    for (final takes in wanted) {
      if (!takes) {
        out.add(true);
      } else {
        out.add(room > 0);
        room -= 1;
      }
    }
    return out;
  }

  /// 「已用 x / 1000」，還不用顯示時是 null
  static String? usage(int used, {required bool unlimited}) =>
      unlimited || used < showFrom ? null : '已用 $used / $limit';

  // —— 超過上限（例如 Pro 到期）：唯讀保留，不刪任何字 ——
  // 原有單字照常瀏覽和複習，只暫停新增會佔名額的字，直到自己刪到 1000 個以內或重新訂閱 Pro。

  /// 超過上限幾個
  static int over(int used) => used > limit ? used - limit : 0;

  static const overMessage =
      '單字都會保留，可以照常瀏覽和複習；只是暫停新增，刪到 1000 個以內或訂閱 Pro 就能再加。';

  // —— App 裡的用法 ——

  static bool countsWord(Word w) => counts(
    cefr: w.cefr,
    fromExam: w.fromExam,
    inMyWords: w.inMyWords,
    favorite: w.favorite,
    inList: w.lists.isNotEmpty,
  );

  static bool get unlimited => ProStore.shared.has(ProFeature.words);

  static int used([Iterable<Word>? words]) =>
      (words ?? AppStore.shared.words).where(countsWord).length;

  static bool get hasRoom => unlimited || used() < limit;

  static bool _wouldCount(String cefr, bool fromExam) => counts(
    cefr: cefr,
    fromExam: fromExam,
    inMyWords: true,
    favorite: false,
    inList: false,
  );

  /// 把這個字存進我的單字（myWords）或清單，會不會多佔一個名額
  static bool takesPlace(
    DictEntry e,
    Word? existing, {
    required bool myWords,
    required bool toList,
  }) {
    if (!myWords && !toList) return false;
    if (existing != null)
      return !countsWord(existing) &&
          _wouldCount(existing.cefr, existing.fromExam);
    return _wouldCount(e.lv, false);
  }

  /// 這批字裡還能加入的，依原本順序
  static List<DictEntry> admitted(
    List<DictEntry> entries, {
    bool myWords = true,
    bool toList = false,
  }) {
    if (unlimited) return entries;
    final seen = <String>{};
    final wanted = [
      for (final e in entries)
        seen.add(e.w.toLowerCase()) &&
            takesPlace(
              e,
              AppStore.shared.word(e.w),
              myWords: myWords,
              toList: toList,
            ),
    ];
    final ok = fit(wanted, used: used(), unlimited: false);
    return [
      for (final (i, e) in entries.indexed)
        if (ok[i]) e,
    ];
  }

  /// 已經存在的字要放進我的單字、喜歡或清單：沒有名額時回傳 false，並跳出上限提示
  static bool admit(Word w) {
    if (countsWord(w) || !_wouldCount(w.cefr, w.fromExam) || hasRoom)
      return true;
    stopped();
    return false;
  }

  /// 加字被上限擋下時加一，App 最外層聽到就跳出提示
  static final stops = ValueNotifier<int>(0);
  static bool _quiet = false;

  static void stopped() {
    if (!_quiet) stops.value += 1;
  }

  /// 使用者已經同意「只加入前 N 個」，加的時候不要再跳一次提示
  static void quietly(void Function() body) {
    _quiet = true;
    try {
      body();
    } finally {
      _quiet = false;
    }
  }
}

/// App 最外層的 Navigator，加字被擋下時從這裡跳出提示（不管現在開著哪個頁面或面板）
final appNavigator = GlobalKey<NavigatorState>();

/// 「單字已達上限」提示，可以直接打開付費牆
Future<void> showQuotaFull(BuildContext c) => showAlert(
  c,
  '單字已達上限',
  message: WordQuota.fullMessage,
  actions: [
    const AlertAction('好'),
    AlertAction(
      '升級 Pro',
      bold: true,
      onTap: () {
        final ctx = appNavigator.currentContext;
        if (ctx != null) presentFull(ctx, const ProPaywall());
      },
    ),
  ],
);

/// 一次加一批字之前先檢查：全部放得下就直接加；一個都放不下就跳上限提示；
/// 只放得下一部分就先問「只能加入前 N 個」，使用者同意才加
void addWithinQuota(
  BuildContext c,
  List<DictEntry> entries,
  void Function() add, {
  bool toList = false,
}) {
  final fits = WordQuota.admitted(entries, toList: toList).length;
  if (fits == entries.length) return add();
  if (fits == 0) return WordQuota.stopped();
  confirmAction(
    c,
    '只能加入前 $fits 個',
    message: WordQuota.fullMessage,
    label: '加入 $fits 個',
    destructive: false,
    onConfirm: () => WordQuota.quietly(add),
  );
}

/// 舊版「超過上限 30 天後刪字」的倒數紀錄。現在不刪字了，只為了讀得懂舊的設定檔和備份；
/// 打開 App 時會清掉
class Countdown {
  const Countdown({
    this.overSince,
    this.deleteOn,
    this.lastStart,
    this.shown7 = false,
    this.shown1 = false,
  });
  final int? overSince, deleteOn, lastStart;
  final bool shown7, shown1;

  bool get isEmpty =>
      overSince == null && deleteOn == null && lastStart == null;

  factory Countdown.fromJson(Map<String, dynamic> j) => Countdown(
    overSince: j['overSince'] as int?,
    deleteOn: j['deleteOn'] as int?,
    lastStart: j['lastStart'] as int?,
    shown7: j['shown7'] as bool? ?? false,
    shown1: j['shown1'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    if (overSince != null) 'overSince': overSince,
    if (deleteOn != null) 'deleteOn': deleteOn,
    if (lastStart != null) 'lastStart': lastStart,
    if (shown7) 'shown7': true,
    if (shown1) 'shown1': true,
  };

  @override
  bool operator ==(Object other) =>
      other is Countdown && other.toJson().toString() == toJson().toString();
  @override
  int get hashCode => toJson().toString().hashCode;
  @override
  String toString() => toJson().toString();
}

/// 打開 App、回到 App 時呼叫。不會刪字，只清掉舊版留下的刪字倒數
class QuotaCountdown {
  static void check(BuildContext c) {
    final s = AppStore.shared;
    if (!s.countdown.isEmpty) {
      s.countdown = const Countdown();
      s.save();
    }
  }
}

/// 超過上限時，主頁和「我的單字」頂端的說明
class QuotaBanner extends StatelessWidget {
  const QuotaBanner({super.key});

  static bool get showing =>
      !WordQuota.unlimited && WordQuota.used() > WordQuota.limit;

  @override
  Widget build(BuildContext context) {
    if (!showing) return const SizedBox.shrink();
    final over = WordQuota.over(WordQuota.used());
    final p = Palette.of(context);
    return Tap(
      onTap: () => presentFull(context, const QuotaOverPage()),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.hsnuMagentaFill,
          borderRadius: BorderRadius.circular(Radii.section),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_rounded, color: p.hsnuMagenta, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '單字超過上限 $over 個，暫停新增',
                    style: ts(F.sub, w: w7, c: p.ink),
                  ),
                  const SizedBox(height: 3),
                  Text(WordQuota.overMessage, style: ts(F.foot, c: p.sec)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.ter),
          ],
        ),
      ),
    );
  }
}

/// 超過上限的說明和兩個選擇：訂閱 Pro、自己刪字
class QuotaOverPage extends StatefulWidget {
  const QuotaOverPage({super.key});
  @override
  State<QuotaOverPage> createState() => _QuotaOverPageState();
}

class _QuotaOverPageState extends State<QuotaOverPage> {
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final used = WordQuota.used();
    return NavPage(
      title: '單字超過上限',
      safeTop: false,
      slivers: [
        Sec(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '免費版的「我的單字」最多 ${WordQuota.limit} 個（大考詞彙和考古題加入的字不算）。你現在有 $used 個，超過 ${WordQuota.over(used)} 個。\n\n${WordQuota.overMessage}',
                style: ts(F.sub, c: p.ink),
              ),
            ),
          ],
        ),
        Sec(
          header: '你可以',
          footer:
              '也可以到「字庫 › 我的單字」自己刪掉一些字，刪到 ${WordQuota.limit} 個以內就能再新增。',
          children: [
            RowTile(
              leading: Icon(Icons.workspace_premium_rounded, color: p.accent),
              title: '訂閱 Pro，不限個數',
              titleColor: p.accent,
              onTap: () async {
                await presentFull(context, const ProPaywall());
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ],
    );
  }
}
