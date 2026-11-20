import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
      (inMyWords || favorite || inList) && !fromExam && !examLevels.contains(cefr);

  /// 一批要加入的字，依序哪些可以加。wanted[i] 是第 i 個字會不會多佔一個名額；
  /// 不佔名額的字一律可以加，其他的加到名額用完為止
  static List<bool> fit(List<bool> wanted, {required int used, required bool unlimited}) {
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

  // —— 超過上限：先警告，期限到了刪掉最早加入的字 ——

  /// 第一次倒數 30 天；90 天內第二次只有 7 天
  static const grace = 30, repeatGrace = 7, repeatWindow = 90;

  /// 第一天超過就開始倒數；回到上限以內或有 Pro 就取消
  static Countdown countdown(Countdown c, {required int used, required bool unlimited, required int today}) {
    if (unlimited || used <= limit) return Countdown(lastStart: c.lastStart);
    if (c.overSince != null) return c;
    final again = c.lastStart != null && today - c.lastStart! < repeatWindow;
    return Countdown(overSince: today, deleteOn: today + (again ? repeatGrace : grace), lastStart: today);
  }

  /// 現在要跳提醒的話，回傳剩幾天（7 或 1）
  static int? reminder(Countdown c, {required int today}) {
    final end = c.deleteOn;
    if (end == null || today >= end) return null;
    final left = end - today;
    if (left <= 1) return c.shown1 ? null : 1;
    if (left <= 7) return c.shown7 ? null : 7;
    return null;
  }

  static bool due(Countdown c, {required int today}) => c.deleteOn != null && today >= c.deleteOn!;

  /// 要刪幾個字：刪到剛好 1000 個
  static int over(int used) => used > limit ? used - limit : 0;

  // —— App 裡的用法 ——

  static bool countsWord(Word w) => counts(
      cefr: w.cefr, fromExam: w.fromExam, inMyWords: w.inMyWords, favorite: w.favorite, inList: w.lists.isNotEmpty);

  static bool get unlimited => ProStore.shared.isPro;

  static int used([Iterable<Word>? words]) => (words ?? AppStore.shared.words).where(countsWord).length;

  static bool get hasRoom => unlimited || used() < limit;

  static bool _wouldCount(String cefr, bool fromExam) =>
      counts(cefr: cefr, fromExam: fromExam, inMyWords: true, favorite: false, inList: false);

  /// 把這個字存進我的單字（myWords）或清單，會不會多佔一個名額
  static bool takesPlace(DictEntry e, Word? existing, {required bool myWords, required bool toList}) {
    if (!myWords && !toList) return false;
    if (existing != null) return !countsWord(existing) && _wouldCount(existing.cefr, existing.fromExam);
    return _wouldCount(e.lv, false);
  }

  /// 這批字裡還能加入的，依原本順序
  static List<DictEntry> admitted(List<DictEntry> entries, {bool myWords = true, bool toList = false}) {
    if (unlimited) return entries;
    final seen = <String>{};
    final wanted = [
      for (final e in entries)
        seen.add(e.w.toLowerCase()) &&
            takesPlace(e, AppStore.shared.word(e.w), myWords: myWords, toList: toList),
    ];
    final ok = fit(wanted, used: used(), unlimited: false);
    return [for (final (i, e) in entries.indexed) if (ok[i]) e];
  }

  /// 已經存在的字要放進我的單字、喜歡或清單：沒有名額時回傳 false，並跳出上限提示
  static bool admit(Word w) {
    if (countsWord(w) || !_wouldCount(w.cefr, w.fromExam) || hasRoom) return true;
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
Future<void> showQuotaFull(BuildContext c) => showAlert(c, '單字已達上限', message: WordQuota.fullMessage, actions: [
      const AlertAction('好'),
      AlertAction('升級 Pro', bold: true, onTap: () {
        final ctx = appNavigator.currentContext;
        if (ctx != null) presentFull(ctx, const ProPaywall());
      }),
    ]);

/// 一次加一批字之前先檢查：全部放得下就直接加；一個都放不下就跳上限提示；
/// 只放得下一部分就先問「只能加入前 N 個」，使用者同意才加
void addWithinQuota(BuildContext c, List<DictEntry> entries, void Function() add, {bool toList = false}) {
  final fits = WordQuota.admitted(entries, toList: toList).length;
  if (fits == entries.length) return add();
  if (fits == 0) return WordQuota.stopped();
  confirmAction(c, '只能加入前 $fits 個',
      message: WordQuota.fullMessage,
      label: '加入 $fits 個',
      destructive: false,
      onConfirm: () => WordQuota.quietly(add));
}

/// 倒數到哪裡了。日期用「1970-01-01 起的第幾天」（手機的時區）
class Countdown {
  const Countdown({this.overSince, this.deleteOn, this.lastStart, this.shown7 = false, this.shown1 = false});
  final int? overSince, deleteOn, lastStart;
  final bool shown7, shown1;

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

  Countdown shown(int left) => Countdown(
      overSince: overSince, deleteOn: deleteOn, lastStart: lastStart, shown7: true, shown1: shown1 || left == 1);

  @override
  bool operator ==(Object other) => other is Countdown && other.toJson().toString() == toJson().toString();
  @override
  int get hashCode => toJson().toString().hashCode;
  @override
  String toString() => toJson().toString();
}

/// 在這台裝置上跑超過上限的倒數：開始、取消、剩 7 天和 1 天的提醒，到期刪掉最早加入的字
class QuotaCountdown {
  static AppStore get _store => AppStore.shared;

  /// 手機時區的第幾天（1970-01-01 是第 0 天）
  static int day([DateTime? d]) {
    final t = d ?? DateTime.now();
    return DateTime.utc(t.year, t.month, t.day).millisecondsSinceEpoch ~/ 86400000;
  }

  static DateTime dateOf(int day) {
    final u = DateTime.fromMillisecondsSinceEpoch(day * 86400000, isUtc: true);
    return DateTime(u.year, u.month, u.day);
  }

  static DateTime? get deleteDate => _store.countdown.deleteOn == null ? null : dateOf(_store.countdown.deleteOn!);

  /// 最早加入、算進上限的字，超過幾個就取幾個
  static List<Word> doomed() {
    final used = WordQuota.used();
    if (WordQuota.unlimited || used <= WordQuota.limit) return const [];
    final ws = _store.words.where(WordQuota.countsWord).toList()..sort((a, b) => a.addedAt.compareTo(b.addedAt));
    return ws.take(WordQuota.over(used)).toList();
  }

  /// 更新倒數。popUps 時（打開 App、回到 App）會到期刪除或回傳要跳的提醒
  static ({int? reminder, int? deleted}) refresh({bool popUps = false}) {
    final today = day();
    var c = WordQuota.countdown(_store.countdown, used: WordQuota.used(), unlimited: WordQuota.unlimited, today: today);
    int? reminder, deleted;
    if (popUps) {
      if (WordQuota.due(c, today: today)) {
        final gone = WordQuota.unlimited ? const <Word>[] : doomed(); // 刪之前再確認一次 Pro
        if (gone.isNotEmpty) {
          _store.removeForQuota(gone);
          deleted = gone.length;
        }
        c = WordQuota.countdown(c, used: WordQuota.used(), unlimited: WordQuota.unlimited, today: today);
      } else {
        reminder = WordQuota.reminder(c, today: today);
        if (reminder != null) c = c.shown(reminder);
      }
    }
    if (c != _store.countdown) {
      _store.countdown = c;
      _store.save();
    }
    return (reminder: reminder, deleted: deleted);
  }

  /// 「只匯出要被刪的字」CSV
  static Future<void> shareCsv() async {
    String cell(String s) => s.contains(RegExp(r'[,"\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    String date(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final lines = [
      'word,meaning,part_of_speech,added_at,level',
      for (final w in doomed()) [w.term, w.meaningLine, w.pos, date(w.addedAt), '${w.srsLevel}'].map(cell).join(','),
    ];
    final file = File('${(await getTemporaryDirectory()).path}/捲字_將被刪除的單字.csv');
    await file.writeAsString('\uFEFF${lines.join('\n')}\n'); // 加 BOM，Excel 才讀得懂中文
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'text/csv')]));
  }

  /// 打開 App 或回到 App 時呼叫：跳提醒或說明刪了幾個字
  static void check(BuildContext c) {
    final r = refresh(popUps: true);
    if (!c.mounted) return;
    if (r.deleted != null) {
      showAlert(c, '已刪除 ${r.deleted} 個單字',
          message: '依照免費版 ${WordQuota.limit} 字上限，刪除了最早加入的字和它們的複習紀錄。之後想再練可以重新加入（有 Pro 就沒有上限）。');
    } else if (r.reminder != null) {
      final left = r.reminder!;
      showAlert(c, left == 1 ? '明天會刪除超過上限的單字' : '還剩 $left 天會刪除超過上限的單字',
          message: '${monthDay(deleteDate!)}會刪除最早加入的 ${WordQuota.over(WordQuota.used())} 個字。'
              '訂閱 Pro、自己刪到 ${WordQuota.limit} 個以下，或先匯出要被刪的字。',
          actions: [
            const AlertAction('稍後'),
            AlertAction('查看', bold: true, onTap: () => presentFull(c, const QuotaOverPage())),
          ]);
    }
  }
}

/// 超過上限時，主頁和「我的單字」頂端的警告，不能關掉
class QuotaBanner extends StatelessWidget {
  const QuotaBanner({super.key});

  static bool get showing => !WordQuota.unlimited && WordQuota.used() > WordQuota.limit;

  @override
  Widget build(BuildContext context) {
    final date = QuotaCountdown.deleteDate;
    final over = WordQuota.over(WordQuota.used());
    if (!showing || date == null) return const SizedBox.shrink();
    final p = Palette.of(context);
    return Tap(
      onTap: () => presentFull(context, const QuotaOverPage()),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: p.hsnuMagentaFill, borderRadius: BorderRadius.circular(Radii.section)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_rounded, color: p.hsnuMagenta, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('單字超過上限 $over 個', style: ts(F.sub, w: w7, c: p.ink)),
              const SizedBox(height: 3),
              Text('${monthDay(date)}會刪除最早加入的 $over 個字，訂閱 Pro 或自己刪到 ${WordQuota.limit} 個以下就不會刪。',
                  style: ts(F.foot, c: p.sec)),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: p.ter),
        ]),
      ),
    );
  }
}

/// 會被刪掉哪些字，和三個選擇：訂閱 Pro、自己刪字、先匯出
class QuotaOverPage extends StatefulWidget {
  const QuotaOverPage({super.key});
  @override
  State<QuotaOverPage> createState() => _QuotaOverPageState();
}

class _QuotaOverPageState extends State<QuotaOverPage> {
  var _all = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final doomed = QuotaCountdown.doomed();
    final used = WordQuota.used();
    final date = QuotaCountdown.deleteDate;
    final shown = _all ? doomed : doomed.take(20).toList();
    return NavPage(title: '單字超過上限', safeTop: false, slivers: [
      Sec(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('免費版的「我的單字」最多 ${WordQuota.limit} 個（大考詞彙和考古題加入的字不算）。你現在有 $used 個，超過 ${doomed.length} 個。',
                style: ts(F.sub, c: p.ink)),
            if (date != null) ...[
              const SizedBox(height: 8),
              Text('如果 ${monthDay(date)} 前沒有處理，會刪掉最早加入的 ${doomed.length} 個字和它們的複習紀錄。自訂清單會留著，只是少了這些字。',
                  style: ts(F.sub, c: p.sec)),
            ],
          ]),
        ),
      ]),
      Sec(
        header: '你可以',
        footer: '也可以到「字庫 › 我的單字」自己刪掉一些字，刪到 ${WordQuota.limit} 個以下就取消。完整備份在「我的 › 備份」。',
        children: [
          RowTile(
            leading: Icon(Icons.workspace_premium_rounded, color: p.accent),
            title: '訂閱 Pro，字全部保留',
            titleColor: p.accent,
            onTap: () async {
              await presentFull(context, const ProPaywall());
              if (mounted) setState(() {});
            },
          ),
          RowTile(
            leading: Icon(Icons.ios_share_rounded, color: p.accent),
            title: '匯出要被刪的字（CSV）',
            titleColor: p.accent,
            onTap: QuotaCountdown.shareCsv,
          ),
        ],
      ),
      Sec(header: '會被刪的字（最早加入的在前）', children: [
        for (final w in shown)
          RowTile(
            titleWidget: Row(children: [
              Text(w.term, style: ts(F.headline, w: w6)),
              const SizedBox(width: 8),
              Expanded(child: Text(w.primaryMeaning, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.body, c: p.sec))),
            ]),
            trailing: Text(monthDay(w.addedAt), style: ts(F.cap, c: p.sec)),
          ),
        if (doomed.length > 20 && !_all)
          RowTile(title: '看完整清單（${doomed.length} 個）', titleColor: p.accent, onTap: () => setState(() => _all = true)),
      ]),
    ]);
  }
}
