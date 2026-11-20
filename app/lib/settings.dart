// App 設定：預設值和 iOS 版相同，改了就寫進 SharedPreferences。

import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo.dart';
import 'dictionary.dart';
import 'models.dart';
import 'services.dart';
import 'theme.dart';

/// 考前倒數：把還沒學的大考單字平均分到剩下的日子，最後兩週只複習。
class ExamPlan {
  static const reviewDays = 14;
  static const names = ['學測', '分科測驗', '會考', '英檢', '多益'];

  ExamPlan._(
    this.name,
    this.top,
    this.daysLeft,
    this.remaining,
    this.perDay,
    this.capped,
  );
  final String name;
  final int top, daysLeft;

  /// 還沒學過（新字或還沒加入）的目標字
  final int remaining;

  /// 每天的新字：最後兩週或目標字都學過時是 0
  final int perDay;

  /// 每天要超過 100 個才學得完，已經用上限
  final bool capped;
  bool get reviewOnly => daysLeft <= reviewDays;

  /// 沒開倒數或考試日已過時回傳 null
  static ExamPlan? of(AppSettings s, Iterable<Word> words, int newToday) {
    if (!s.examOn) return null;
    final days =
        startOfDay(s.examDate).difference(startOfDay(DateTime.now())).inHours ~/
        24;
    if (days < 0) return null;
    final t = targets(s.examTop);
    final learned = words
        .where((w) => !w.isNew && t.contains(w.term.toLowerCase()))
        .length;
    final remaining = max(0, t.length - learned);
    // 今天學的新字加回去，數字才不會越學越少
    final studyDays = days - reviewDays;
    final needed = studyDays > 0
        ? ((remaining + newToday) / studyDays).ceil()
        : 0;
    return ExamPlan._(
      s.examName,
      s.examTop,
      days,
      remaining,
      min(100, needed),
      needed > 100,
    );
  }

  static (int, Set<String>)? _cache;
  static Set<String> targets(int top) {
    final c = _cache;
    if (c != null && c.$1 == top) return c.$2;
    final t = {
      for (var lv = 1; lv <= max(1, top); lv++)
        for (final e in Dict.entriesOfLevel('$lv')) e.w.toLowerCase(),
    };
    _cache = (top, t);
    return t;
  }

  /// 還沒加入的目標字：先簡單的級數，同一級裡打亂
  List<DictEntry> pool(Set<String> have) => [
    for (var lv = 1; lv <= max(1, top); lv++)
      ...(Dict.entriesOfLevel('$lv')
          .where((e) => !have.contains(e.w.toLowerCase()))
          .toList()
        ..shuffle()),
  ];

  /// 還沒選日期前先用明年 1 月 20 日，大約是學測的時間
  static DateTime defaultDate() {
    final now = DateTime.now();
    final d = DateTime(now.year, 1, 20);
    return d.isAfter(now) ? d : DateTime(now.year + 1, 1, 20);
  }
}

class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final shared = AppSettings._();

  SharedPreferences? _p;

  bool onboarded = false,
      reminderOn = false,
      reminderAsked = false,
      muted = false;
  bool showTranslation = true,
      haptics = true,
      exploreTipsDone = false,
      studyRulesSeen = false;
  bool listShowMeaning = true, detailAutoSpeak = false, exploreShowIPA = true;

  /// 18 題程度測驗有做完才是 true；線上對戰要先做完
  bool levelTested = false;

  /// 伺服器要這個人重新做程度測驗（排位賽）；新的程度送出後清掉
  bool levelRetest = false;
  String language = 'zh-Hant', level = '3', themeID = 'phoenix';
  int dailyGoal = 10,
      reminderMinutes = 20 * 60,
      appearance = 0,
      fontStyle = 0,
      practiceLimit = 20;
  double speechRate = 0.45;

  // 考前倒數：開著的時候，每天的新字數由考試日期算出來（ExamPlan），不看 dailyGoal
  bool examOn = false;
  String examName = '學測';
  DateTime examDate = ExamPlan.defaultDate();
  int examTop = 6; // 要學完的大考最高級數（2、4 或 6）

  /// 倒數算出的今日目標，由主頁設定；沒開倒數時是 null
  int? examGoal;

  /// 今天要學的新字數
  int get goal => examGoal ?? dailyGoal;

  Future<void> load() async {
    final p = _p = await SharedPreferences.getInstance();
    onboarded = p.getBool('onboarded') ?? false;
    levelTested = p.getBool('levelTested') ?? false;
    levelRetest = p.getBool('levelRetest') ?? false;
    reminderOn = p.getBool('reminderOn') ?? false;
    reminderAsked = p.getBool('reminderAsked') ?? false;
    muted = p.getBool('muted') ?? false;
    showTranslation = p.getBool('showTranslation') ?? true;
    haptics = p.getBool('haptics') ?? true;
    exploreTipsDone = p.getBool('exploreTipsDone') ?? false;
    studyRulesSeen = p.getBool('studyRulesSeen') ?? false;
    listShowMeaning = p.getBool('listShowMeaning') ?? true;
    detailAutoSpeak = p.getBool('detailAutoSpeak') ?? false;
    exploreShowIPA = p.getBool('exploreShowIPA') ?? true;
    language = p.getString('language') ?? 'zh-Hant';
    level = p.getString('level') ?? '3';
    themeID = p.getString('themeID') ?? 'phoenix';
    dailyGoal = p.getInt('dailyGoal') ?? 10;
    reminderMinutes = p.getInt('reminderMinutes') ?? 20 * 60;
    appearance = p.getInt('appearance') ?? 0;
    fontStyle = p.getInt('fontStyle') ?? 0;
    practiceLimit = p.getInt('practiceLimit') ?? 20;
    speechRate = p.getDouble('speechRate') ?? 0.45;
    examOn = p.getBool('examOn') ?? false;
    examName = p.getString('examName') ?? '學測';
    final stamp = p.getDouble('examDate') ?? 0;
    examDate = stamp > 0
        ? DateTime.fromMillisecondsSinceEpoch((stamp * 1000).round())
        : ExamPlan.defaultDate();
    examTop = p.getInt('examTop') ?? 6;
    if (demoOn) {
      onboarded = true;
      exploreTipsDone = true;
      muted = true;
      appearance = 1;
    }
  }

  /// 改設定的共用寫法：s.update((s) => s.level = '4')
  void update(void Function(AppSettings s) change) {
    final reminderBefore = '$reminderOn|$reminderMinutes';
    change(this);
    _save();
    notifyListeners();
    if (reminderBefore != '$reminderOn|$reminderMinutes') Reminders.sync();
  }

  void _save() {
    final p = _p;
    if (p == null) return;
    p.setBool('onboarded', onboarded);
    p.setBool('levelTested', levelTested);
    p.setBool('levelRetest', levelRetest);
    p.setBool('reminderOn', reminderOn);
    p.setBool('reminderAsked', reminderAsked);
    p.setBool('muted', muted);
    p.setBool('showTranslation', showTranslation);
    p.setBool('haptics', haptics);
    p.setBool('exploreTipsDone', exploreTipsDone);
    p.setBool('studyRulesSeen', studyRulesSeen);
    p.setBool('listShowMeaning', listShowMeaning);
    p.setBool('detailAutoSpeak', detailAutoSpeak);
    p.setBool('exploreShowIPA', exploreShowIPA);
    p.setString('language', language);
    p.setString('level', level);
    p.setString('themeID', themeID);
    p.setInt('dailyGoal', dailyGoal);
    p.setInt('reminderMinutes', reminderMinutes);
    p.setInt('appearance', appearance);
    p.setInt('fontStyle', fontStyle);
    p.setInt('practiceLimit', practiceLimit);
    p.setDouble('speechRate', speechRate);
    p.setBool('examOn', examOn);
    p.setString('examName', examName);
    p.setDouble('examDate', examDate.millisecondsSinceEpoch / 1000);
    p.setInt('examTop', examTop);
  }

  /// 「自動唸單字」：設定頁和探索頁的喇叭是同一個開關
  bool get autoSpeak => !muted;

  AppTheme get theme => AppTheme.all.firstWhere(
    (t) => t.id == themeID,
    orElse: () => AppTheme.all.first,
  );

  ThemeMode get themeMode => const [
    ThemeMode.system,
    ThemeMode.light,
    ThemeMode.dark,
  ][appearance.clamp(0, 2)];

  /// Android 沒有內建圓體，所以字體選項是 系統、襯線、等寬。編號和 iOS 相同，備份才能互通
  String? get fontFamily => switch (fontStyle) {
    2 => 'serif',
    3 => 'monospace',
    _ => null,
  };

  String get reminderText =>
      '${reminderMinutes ~/ 60}:${(reminderMinutes % 60).toString().padLeft(2, '0')}';

  // 備份檔裡的設定（欄位和 iOS 版相同）
  Map<String, Object> get backupValues => {
    'level': level,
    'dailyGoal': dailyGoal,
    'reminderOn': reminderOn,
    'reminderMinutes': reminderMinutes,
    'appearance': appearance,
    'fontStyle': fontStyle,
    'themeID': themeID,
    'muted': muted,
    'showTranslation': showTranslation,
    'haptics': haptics,
    'speechRate': speechRate,
    'listShowMeaning': listShowMeaning,
    'detailAutoSpeak': detailAutoSpeak,
    'exploreShowIPA': exploreShowIPA,
    'examOn': examOn,
    'examName': examName,
    'examDate': examDate.millisecondsSinceEpoch / 1000,
    'examTop': examTop,
  };

  void applyBackup(Map<String, dynamic> m) => update((s) {
    T? v<T>(String k) => m[k] is T ? m[k] as T : null;
    s.level = v<String>('level') ?? s.level;
    s.dailyGoal = v<int>('dailyGoal') ?? s.dailyGoal;
    s.reminderMinutes = v<int>('reminderMinutes') ?? s.reminderMinutes;
    s.reminderOn = v<bool>('reminderOn') ?? s.reminderOn;
    s.appearance = v<int>('appearance') ?? s.appearance;
    s.fontStyle = v<int>('fontStyle') ?? s.fontStyle;
    s.themeID = v<String>('themeID') ?? s.themeID;
    s.muted = v<bool>('muted') ?? s.muted;
    s.showTranslation = v<bool>('showTranslation') ?? s.showTranslation;
    s.haptics = v<bool>('haptics') ?? s.haptics;
    s.speechRate = v<num>('speechRate')?.toDouble() ?? s.speechRate;
    s.listShowMeaning = v<bool>('listShowMeaning') ?? s.listShowMeaning;
    s.detailAutoSpeak = v<bool>('detailAutoSpeak') ?? s.detailAutoSpeak;
    s.exploreShowIPA = v<bool>('exploreShowIPA') ?? s.exploreShowIPA;
    s.examOn = v<bool>('examOn') ?? s.examOn;
    s.examName = v<String>('examName') ?? s.examName;
    final stamp = v<num>('examDate');
    if (stamp != null && stamp > 0)
      s.examDate = DateTime.fromMillisecondsSinceEpoch((stamp * 1000).round());
    s.examTop = v<int>('examTop') ?? s.examTop;
  });
}
