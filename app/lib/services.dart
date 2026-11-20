// 和手機系統打交道的部分：念單字、每日提醒、震動。
// 全部包 try/catch：語音引擎或通知不能用時，App 其他功能照常。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'models.dart';
import 'settings.dart';
import 'store.dart';

class Speech {
  static final _tts = FlutterTts();
  static bool _ready = false;

  /// 字典縮寫念成完整的字："harm to sth" → "harm to something"
  static String spoken(String text) {
    var t = text;
    // 片語裡的 / 是「或」；句子裡的（km/h）不動
    if (t.split(' ').length <= 6 && !RegExp(r'\d').hasMatch(t)) {
      t = t.replaceAll(RegExp(r'(?<=\w)\s*/\s*(?=\w)'), ' or ');
    }
    t = t.replaceAll(RegExp(r'\s*(~|…|\.{3})\s*'), ' ');
    const words = [
      ("sb's", "somebody's"),
      ("sth's", "something's"),
      ('sb', 'somebody'),
      ('sth', 'something'),
      ('smb', 'somebody'),
      ('smth', 'something'),
      ('etc', 'et cetera'),
      ('e.g', 'for example'),
      ('i.e', 'that is'),
    ];
    for (final (short, long) in words) {
      t = t.replaceAll(
        RegExp('\\b${reEscape(short)}\\b\\.?', caseSensitive: false),
        long,
      );
    }
    return t;
  }

  static Future<void> say(String text, {double? rate}) async {
    if (text.isEmpty) return;
    try {
      if (!_ready) {
        await _tts.setLanguage('en-US');
        _ready = true;
      }
      await _tts.stop();
      await _tts.setSpeechRate(rate ?? AppSettings.shared.speechRate);
      await _tts.speak(spoken(text));
    } catch (e) {
      debugPrint('語音無法使用：$e');
    }
  }
}

class Feedback2 {
  static void light() {
    if (AppSettings.shared.haptics) HapticFeedback.lightImpact();
  }

  static void success() {
    if (AppSettings.shared.haptics) HapticFeedback.mediumImpact();
  }

  static void error() {
    if (AppSettings.shared.haptics) HapticFeedback.heavyImpact();
  }
}

class Reminders {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> _init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_notification'),
      ),
    );
    _ready = true;
  }

  /// 排未來兩週，每天一則。今天練過就不排今天，所以每次進背景都重排一次
  static Future<void> sync() async {
    try {
      await _init();
      for (var i = 0; i < 14; i++) {
        await _plugin.cancel(i);
      }
      final s = AppSettings.shared;
      if (!s.reminderOn) return;
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (await android?.requestNotificationsPermission() == false) return;

      final store = AppStore.shared;
      final today = startOfDay(DateTime.now());
      final studiedToday =
          store.logs.isNotEmpty && !store.logs.last.date.isBefore(today);
      final dueDates = store.studyable
          .map((w) => w.dueDate)
          .whereType<DateTime>()
          .toList();
      for (var d = 0; d < 14; d++) {
        final day = addDays(today, d);
        final at = DateTime(
          day.year,
          day.month,
          day.day,
          s.reminderMinutes ~/ 60,
          s.reminderMinutes % 60,
        );
        if (d == 0 && (studiedToday || !at.isAfter(DateTime.now()))) continue;
        final end = addDays(day, 1);
        final due = dueDates.where((x) => x.isBefore(end)).length;
        await _plugin.zonedSchedule(
          d,
          '該複習單字囉',
          due > 0
              ? '今天有 $due 個字到期，花幾分鐘複習完，別讓剛學的字又忘光。'
              : '花幾分鐘把今天到期的字複習完，別讓剛學的字又忘光。',
          // 算好的是絕對時間，所以用 UTC 表示就好，不必知道手機的時區名稱
          tz.TZDateTime.from(at.toUtc(), tz.UTC),
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'daily',
              '每日提醒',
              icon: '@mipmap/ic_notification',
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    } catch (e) {
      debugPrint('提醒無法排程：$e');
    }
  }
}
