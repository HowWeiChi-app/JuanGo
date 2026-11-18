// 測試共用：載入真實字典和考古題，並把語音、通知等原生功能接到空的回應。

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juango/dictionary.dart';
import 'package:juango/exam.dart';
import 'package:juango/models.dart';
import 'package:juango/settings.dart';
import 'package:juango/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> setUpData() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in ['flutter_tts', 'dexterous.com/flutter/local_notifications', 'dev.fluttercommunity.plus/share']) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }
  if (Dict.all.isEmpty) Dict.loadFromJson(File('assets/words.json').readAsStringSync());
  if (ExamStore.all.isEmpty) ExamStore.loadFromJson(File('assets/exams.json').readAsStringSync());
}

Future<void> resetState({bool onboarded = false}) async {
  SharedPreferences.setMockInitialValues({'onboarded': onboarded});
  await AppSettings.shared.load();
  AppSettings.shared.onboarded = onboarded;
  AppStore.resetForTest();
}

/// 一份看起來有在用的字庫：不同熟練度、有收藏、有清單、今天有練習
void seedWords() {
  final s = AppStore.shared;
  const terms = ['resilience', 'perspective', 'maintain', 'pivotal', 'situate', 'abandon', 'benefit', 'curious', 'decline', 'efficient'];
  for (final (i, t) in terms.indexed) {
    final w = s.add(Dict.lookup(t)!);
    for (var k = 0; k < i % 6; k++) {
      SRS.apply(Grade.good, w);
    }
    if (i < 6) s.addLog(ReviewLog(term: t, result: Grade.good.index, wasNew: i < 3, date: DateTime.now()));
  }
  s.toggleFavorite(s.word('resilience')!);
  s.createList('期中考');
}
