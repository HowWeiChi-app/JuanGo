// 開發版自己抓更新：打開 App 時向 Supabase 查最新的開發版（dev_latest，只回給內測名單裡的帳號），
// 比這支 App 新就跳提醒，按「下載」拿一個 10 分鐘有效的私人下載網址，用瀏覽器抓 APK，點開就能覆蓋安裝。
// 只有開發版（devGosPro）的 Android、而且登入了才會檢查；tools/release_dev.sh 發新版時會一起改 devBuild。

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cloud.dart';
import 'pro.dart';
import 'widgets.dart';

/// 這支 App 的開發版編號，和 pubspec.yaml 版本號 + 後面的數字相同
const devBuild = 7;

class DevUpdate {
  /// 一次開啟只問一次
  static bool _asked = false;

  static Future<void> check(BuildContext Function() context) async {
    if (!devGosPro || _asked || !Platform.isAndroid || !Cloud.shared.signedIn)
      return;
    try {
      final j = await Cloud.shared.rpc(
        'dev_latest',
        const {},
        const Duration(seconds: 10),
      );
      if (j is! Map) return;
      final build = (j['build'] as num?)?.toInt() ?? 0;
      if (build <= devBuild) return;
      final c = context();
      if (_asked || !c.mounted) return;
      _asked = true;
      final notes = '${j['notes'] ?? ''}'.trim();
      await showAlert(
        c,
        '有新的開發版',
        message: [
          '開發版 ${j['version']}（$build）',
          if (notes.isNotEmpty) notes,
          '下載完點開安裝檔就會更新，學習紀錄都會留著。',
        ].join('\n\n'),
        actions: [
          const AlertAction('稍後'),
          AlertAction(
            '下載',
            bold: true,
            onTap: () => unawaited(_download('${j['path']}')),
          ),
        ],
      );
    } catch (e) {
      debugPrint('檢查開發版更新失敗：$e');
    }
  }

  static Future<void> _download(String path) async {
    try {
      await launchUrl(
        Uri.parse(await Cloud.shared.signDevBuild(path)),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('開發版下載網址拿不到：$e');
    }
  }
}
