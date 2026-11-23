// 自己抓更新（Android）：打開 App 時讀 GitHub 上的 release/latest.json，
// 裡面的 build 比這支 App 新就跳提醒，按「下載」用瀏覽器抓 APK，點開就能覆蓋安裝。
// iPhone 版是原生 App，同一份檔案由 ios/JuanGo/AppUpdate.swift 讀。
// tools/build_release.sh 發版時會重寫這份檔案。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'widgets.dart';
import 'word_report.dart';

class AppUpdate {
  static final manifest = Uri.parse(
    'https://raw.githubusercontent.com/HowWeiChi-app/JuanGo/main/release/latest.json',
  );

  /// 一次開啟只問一次
  static bool _asked = false;

  static Future<void> check(BuildContext Function() context) async {
    if (_asked || !Platform.isAndroid) return;
    try {
      final r = await http.get(manifest).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return;
      final a = jsonDecode(utf8.decode(r.bodyBytes));
      if (a is! Map) return;
      final build = (a['build'] as num?)?.toInt() ?? 0;
      final url = '${a['apk'] ?? ''}';
      if (build <= appBuild || !url.startsWith('https://')) return;
      final c = context();
      if (_asked || !c.mounted) return;
      _asked = true;
      final notes = '${a['notes'] ?? ''}'.trim();
      await showAlert(
        c,
        '有新版本',
        message: [
          '捲字 ${a['version']}（$build）',
          if (notes.isNotEmpty) notes,
          '下載完點開安裝檔就會更新，學習紀錄都會留著。',
        ].join('\n\n'),
        actions: [
          const AlertAction('稍後'),
          AlertAction(
            '下載',
            bold: true,
            onTap: () => unawaited(
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
            ),
          ),
        ],
      );
    } catch (e) {
      debugPrint('檢查更新失敗：$e');
    }
  }
}
