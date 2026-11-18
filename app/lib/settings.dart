// App 設定：預設值和 iOS 版相同，改了就寫進 SharedPreferences。

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo.dart';
import 'services.dart';
import 'theme.dart';

class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final shared = AppSettings._();

  SharedPreferences? _p;

  bool onboarded = false, reminderOn = false, reminderAsked = false, muted = false;
  bool showTranslation = true, haptics = true, exploreTipsDone = false, studyRulesSeen = false;
  bool listShowMeaning = true, detailAutoSpeak = false, exploreShowIPA = true;
  String language = 'zh-Hant', level = '3', themeID = 'phoenix';
  int dailyGoal = 10, reminderMinutes = 20 * 60, appearance = 0, fontStyle = 0, practiceLimit = 20;
  double speechRate = 0.45;

  Future<void> load() async {
    final p = _p = await SharedPreferences.getInstance();
    onboarded = p.getBool('onboarded') ?? false;
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
  }

  /// 「自動唸單字」：設定頁和探索頁的喇叭是同一個開關
  bool get autoSpeak => !muted;

  AppTheme get theme => AppTheme.all.firstWhere((t) => t.id == themeID, orElse: () => AppTheme.all.first);

  ThemeMode get themeMode => const [ThemeMode.system, ThemeMode.light, ThemeMode.dark][appearance.clamp(0, 2)];

  /// Android 沒有內建圓體，所以字體選項是 系統、襯線、等寬。編號和 iOS 相同，備份才能互通
  String? get fontFamily => switch (fontStyle) { 2 => 'serif', 3 => 'monospace', _ => null };

  String get reminderText => '${reminderMinutes ~/ 60}:${(reminderMinutes % 60).toString().padLeft(2, '0')}';

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
      });
}
