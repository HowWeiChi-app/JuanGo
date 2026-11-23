// 捲字雲端 AI（Pro）：Android 沒有裝置端模型，Pro 用戶直接用伺服器的 Agnes（supabase/functions/ai，每月配額內免費）。
// App 不帶任何 AI 金鑰，用登入的帳號呼叫；伺服器檢查 Pro 和配額後轉送到 Agnes。iPhone 版對照 ios/JuanGo/Cloud.swift 的 CloudAI。

import 'dart:convert';

import 'cloud.dart';
import 'dev_log.dart';
import 'models.dart';
import 'pro.dart';

class CloudAI {
  static Uri get endpoint =>
      Uri.parse('${CloudConfig.url}/functions/v1/ai/chat/completions');

  /// 有 Pro 而且登入了才能用
  static bool get available => ProStore.shared.isPro && Cloud.shared.signedIn;

  /// 一次對話，回傳 AI 的文字；不能用（沒登入、配額用完、沒網路…）就丟 CloudFailure
  static Future<String> complete(String prompt, {double temperature = 0.3}) async {
    if (!available) throw const CloudFailure('雲端 AI 是捲字 Pro 的功能，登入後就能用');
    final List<int> bytes;
    try {
      bytes = await Cloud.shared.sendBytes(
        endpoint,
        'POST',
        body: utf8.encode(
          jsonEncode({
            'model': 'agnes-3.0-flash', // 伺服器會換成自己設定的模型
            'temperature': temperature,
            'messages': [
              {
                'role': 'system',
                'content':
                    'English→Traditional Chinese (Taiwan) helper for high-school students. Never use Simplified Chinese.',
              },
              {'role': 'user', 'content': prompt},
            ],
          }),
        ),
        timeout: const Duration(seconds: 40),
      );
    } on CloudFailure catch (e) {
      DevLog.add('ai', '雲端 AI 失敗：$e');
      if (e.message.contains('429') || e.message.contains('太頻繁')) {
        throw const CloudFailure('這個月的雲端 AI 次數用完了，下個月會重新計算');
      }
      rethrow;
    }
    final o = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    Object? text;
    if (o is Map && o['choices'] is List && (o['choices'] as List).isNotEmpty) {
      final first = (o['choices'] as List).first;
      if (first is Map && first['message'] is Map) {
        text = (first['message'] as Map)['content'];
      }
    }
    if (text is! String) throw const CloudFailure('雲端 AI 回應格式不對');
    return text;
  }

  /// 回覆裡的第一個 JSON 物件（容許 ```json 和前後多餘的字）
  static Map<String, dynamic>? jsonObject(String text) {
    final a = text.indexOf('{'), b = text.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      final v = jsonDecode(text.substring(a, b + 1));
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  static final Map<String, ({String en, String zh})> _examples = {};

  /// 字典沒有例句的字：寫一句例句和中文翻譯（同一個字只問一次）
  static Future<({String en, String zh})?> example(DictEntry e) async {
    final hit = _examples[e.w];
    if (hit != null) return hit;
    final text = await complete(
      'Word: ${e.w}\nPart of speech: ${e.pos}\nMeaning: ${e.zh.take(3).join('、')}'
      '${e.def.isEmpty ? '' : ' (${e.def})'}\n'
      'Write one natural, everyday English sentence (6 to 12 words) using the word in this meaning, '
      'and its fluent Traditional Chinese (Taiwan) translation.\nJSON only: {"en": "…", "zh": "…"}',
      temperature: 0.7,
    );
    final o = jsonObject(text);
    final en = (o?['en'] as String?)?.trim() ?? '';
    final zh = (o?['zh'] as String?)?.trim() ?? '';
    if (en.isEmpty || zh.isEmpty || !WordMatch.found(e.w, en)) return null;
    return _examples[e.w] = (en: en, zh: zh);
  }

  /// 課文掃描自動校對：只修拼字（掃錯的字），不改課文用字和文法。回傳 原字 → 建議
  static Future<Map<String, String>> fixSpelling(
    List<String> words,
    String context,
  ) async {
    if (words.isEmpty) return const {};
    final text = await complete(
      'These words came from OCR of an English textbook page and may be misread.\n'
      'Words: ${words.join(', ')}\n'
      'Page excerpt: ${context.length > 1500 ? context.substring(0, 1500) : context}\n'
      'For each word that is clearly a misreading, give the intended correctly spelled word. '
      'Skip names and words that are already correct. Fix spelling only, never change wording.\n'
      'JSON only: {"misread": "correct"}',
      temperature: 0,
    );
    final o = jsonObject(text) ?? const {};
    return {
      for (final MapEntry(:key, :value) in o.entries)
        if (value is String &&
            words.contains(key) &&
            value.trim().isNotEmpty &&
            value.trim() != key)
          key: value.trim(),
    };
  }
}
