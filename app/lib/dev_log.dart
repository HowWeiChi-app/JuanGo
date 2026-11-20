// 開發版的 log 和「回報問題」。Log 只存在這支手機（開啟、切到背景、伺服器錯誤、登入登出、課文書架同步和辨識結果），
// 只有在開發者選項按「回報問題 › 送出」時才會連同說明一起上傳到 Supabase 的 dev_reports（supabase/dev_reports.sql）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'cloud.dart';
import 'dev_update.dart';
import 'pro.dart';
import 'theme.dart';
import 'widgets.dart';

class DevLog {
  static const _maxLines = 2000;
  static File? _file;
  static Future<void> _queue = Future.value();
  static int _writes = 0;

  /// 測試裡不寫檔
  static bool disabled = false;

  static Future<File> _f() async => _file ??= File('${(await getApplicationSupportDirectory()).path}/devlog.txt');

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 記一行，例如 DevLog.add('cloud', 'POST /rest/v1/pages → 403 …')。只有開發版會記
  static void add(String tag, String message) {
    if (!devGosPro || disabled) return;
    final t = DateTime.now();
    final line = '${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} [$tag] ${message.replaceAll('\n', ' ')}\n';
    _queue = _queue.then((_) async {
      try {
        final f = await _f();
        await f.writeAsString(line, mode: FileMode.append, flush: true);
        if (++_writes % 100 == 0) {
          final lines = (await f.readAsLines()).where((l) => l.isNotEmpty).toList();
          if (lines.length > _maxLines) await f.writeAsString('${lines.sublist(lines.length - _maxLines).join('\n')}\n', flush: true);
        }
      } catch (_) {}
    });
  }

  static Future<String> read() async {
    await _queue;
    try {
      final f = await _f();
      return await f.exists() ? await f.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> clear() async {
    await _queue;
    try {
      final f = await _f();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// App 版本、Android 版本，回報和開啟時記一行
  static String get deviceSummary => 'JuanGo 開發版 $devBuild · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
}

class DevLogPage extends StatefulWidget {
  const DevLogPage({super.key});
  @override
  State<DevLogPage> createState() => _DevLogPageState();
}

class _DevLogPageState extends State<DevLogPage> {
  String? _text;

  @override
  void initState() {
    super.initState();
    unawaited(DevLog.read().then((t) => mounted ? setState(() => _text = t) : null));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final text = _text ?? '';
    return NavPage(
      title: 'Log 紀錄',
      safeTop: false,
      actions: [
        if (text.isNotEmpty)
          BarText('清除', onTap: () => confirmAction(context, '清除這支手機上的 log？', label: '清除', onConfirm: () async {
                await DevLog.clear();
                if (mounted) setState(() => _text = '');
              })),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(text.isEmpty ? (_text == null ? '' : '還沒有紀錄。') : text, style: ts(F.cap, c: p.ink, mono: true)),
          ),
        ),
      ],
    );
  }
}

class DevReportPage extends StatefulWidget {
  const DevReportPage({super.key});
  @override
  State<DevReportPage> createState() => _DevReportPageState();
}

class _DevReportPageState extends State<DevReportPage> {
  final _message = TextEditingController();
  bool _withLog = true;
  bool _sending = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final message = _message.text.trim();
    if (message.isEmpty || _sending) return;
    setState(() => _sending = true);
    FocusScope.of(context).unfocus();
    DevLog.add('report', 'sending a report');
    final log = _withLog ? await DevLog.read() : '';
    String result;
    var sent = false;
    try {
      await Cloud.shared.sendBytes(Uri.parse('${CloudConfig.url}/rest/v1/dev_reports'), 'POST',
          body: utf8.encode(jsonEncode({
            'app': 'juango',
            'platform': 'android',
            'version': '$devBuild',
            'build': '$devBuild',
            'device': DevLog.deviceSummary,
            'message': message,
            'log': log.length > 200000 ? log.substring(log.length - 200000) : log,
          })),
          prefer: 'return=minimal');
      sent = true;
      result = '已送出，謝謝回報！';
    } on CloudFailure catch (e) {
      result = e.message.contains('dev_reports') || e.message.contains('relation') ? '回報的伺服器還沒開通。' : '沒有送出：${e.message}';
    }
    if (!mounted) return;
    setState(() => _sending = false);
    if (sent) _message.clear();
    await showAlert(context, result);
    if (sent && mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return NavPage(
      title: '回報問題',
      safeTop: false,
      slivers: [
        SliverToBoxAdapter(
          child: Sec(footer: '會一起送出：${DevLog.deviceSummary}', children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: TextField(
                controller: _message,
                autofocus: true,
                minLines: 5,
                maxLines: 12,
                style: ts(F.body, c: p.ink),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(hintText: '哪裡怪怪的？怎麼發生的？', hintStyle: ts(F.body, c: p.ter), border: InputBorder.none),
              ),
            ),
          ]),
        ),
        SliverToBoxAdapter(
          child: Sec(footer: 'Log 只有在按「送出」時才會上傳，平常都只存在這支手機。', children: [
            SwitchRow(title: '附上 log 紀錄', value: _withLog, onChanged: (v) => setState(() => _withLog = v)),
            RowTile(title: '看看要送出的 log', chevron: true, onTap: () => pushPage(context, const DevLogPage())),
          ]),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: PrimaryButton(label: _sending ? '送出中…' : '送出', onTap: _message.text.trim().isEmpty || _sending ? null : _send),
          ),
        ),
      ],
    );
  }
}
