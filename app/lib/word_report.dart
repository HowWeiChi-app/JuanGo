// 回報單字問題（supabase/word_reports.sql）。回報先存在這台裝置，送到伺服器才拿掉；
// 沒網路時下次打開 App 再送。每筆有自己的 id，重送也只算一次。

import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud.dart';
import 'models.dart';
import 'theme.dart';
import 'widgets.dart';

/// 和 pubspec.yaml 的 version 一致（test/word_report_test.dart 會檢查）
const appVersion = '0.1.0';

class WordReport {
  static const kinds = [
    ('meaning', '中文解釋錯誤'),
    ('ipa', '音標錯誤'),
    ('pos', '詞性錯誤'),
    ('example', '例句錯誤或不通順'),
    ('example_zh', '例句翻譯錯誤'),
    ('audio', '發音錯誤'),
    ('similar', '相似字詞不對'),
    ('level', '分級錯誤'),
    ('other', '其他'),
  ];
  static const noteLimit = 200;
  static const _queueKey = 'wordReports.pending';
  static const _deviceKey = 'wordReports.device';

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  /// 這台裝置的隨機 id，沒登入的人才不能整天重複回報同一件事
  static Future<String> _device(SharedPreferences prefs) async {
    final d = prefs.getString(_deviceKey);
    if (d != null) return d;
    final n = _uuid();
    await prefs.setString(_deviceKey, n);
    return n;
  }

  /// 單字頁現在顯示的內容，跟回報一起送
  static Map<String, dynamic> snapshot(Word w) => {
        'term': w.term,
        'meanings': w.meanings,
        'pos': w.pos,
        'ipa': w.ipa,
        'definition': w.definition,
        'example': w.example,
        'example_zh': w.exampleZh,
        'level': w.cefr,
      };

  static Future<List<Map<String, dynamic>>> pending() async {
    final raw = (await SharedPreferences.getInstance()).getStringList(_queueKey) ?? const [];
    return [for (final s in raw) jsonDecode(s) as Map<String, dynamic>];
  }

  static Future<void> _save(List<Map<String, dynamic>> q) async =>
      (await SharedPreferences.getInstance()).setStringList(_queueKey, [for (final m in q) jsonEncode(m)]);

  /// 存進佇列並試著送出。現在就送到伺服器時回傳 true
  static Future<bool> submit({required String word, required String kind, String note = '', required Map<String, dynamic> snapshot}) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = note.trim();
    final args = {
      'p_client_id': _uuid(),
      'p_word': word,
      'p_exam_ref': null,
      'p_kind': kind,
      'p_note': trimmed.length > noteLimit ? trimmed.substring(0, noteLimit) : trimmed,
      'p_snapshot': snapshot,
      'p_app_version': appVersion,
      'p_platform': 'android',
      'p_device': await _device(prefs),
    };
    await _save([...await pending(), args]);
    await flush();
    return !(await pending()).any((m) => m['p_client_id'] == args['p_client_id']);
  }

  static bool _flushing = false;

  /// 把還沒送出的回報送出去；回報後和每次回到 App 時呼叫
  static Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      for (final args in await pending()) {
        try {
          await Cloud.shared.reportWord(args);
        } catch (_) {
          return; // 沒網路：下次再送
        }
        await _save([for (final m in await pending()) if (m['p_client_id'] != args['p_client_id']) m]);
      }
    } finally {
      _flushing = false;
    }
  }
}

Future<void> showWordReport(BuildContext c, Word w) => presentSheet(c, (_) => _ReportSheet(w));

class _ReportSheet extends StatefulWidget {
  const _ReportSheet(this.word);
  final Word word;
  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String? _kind;
  final _note = TextEditingController();
  var _sending = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final kind = _kind;
    if (kind == null) return;
    setState(() => _sending = true);
    final sent = await WordReport.submit(
        word: widget.word.term, kind: kind, note: _note.text, snapshot: WordReport.snapshot(widget.word));
    if (!mounted) return;
    final nav = Navigator.of(context);
    await showAlert(context, sent ? '已送出，謝謝你的回報' : '目前沒有網路，連上網路後會自動送出');
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return NavPage(
      title: '回報問題',
      safeTop: false,
      leading: BarText('取消', bold: false, onTap: () => Navigator.of(context).pop()),
      actions: [BarText('送出', onTap: _kind == null || _sending ? null : _send)],
      slivers: [
        Sec(header: '「${widget.word.term}」哪裡有問題？', children: [
          for (final (id, label) in WordReport.kinds)
            RowTile(
              title: label,
              trailing: _kind == id ? Icon(Icons.check_rounded, color: p.accent) : null,
              onTap: () => setState(() => _kind = id),
            ),
        ]),
        Sec(
          footer: '會一起送出這個字目前的解釋、例句和音標，以及 App 版本。${_note.text.length} / ${WordReport.noteLimit}',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: TextField(
                controller: _note,
                minLines: 2,
                maxLines: 5,
                maxLength: WordReport.noteLimit,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                onChanged: (_) => setState(() {}),
                style: ts(F.body, c: p.ink),
                decoration: InputDecoration(
                    isCollapsed: true, border: InputBorder.none, hintText: '補充說明（選填）', hintStyle: ts(F.body, c: p.ter)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
