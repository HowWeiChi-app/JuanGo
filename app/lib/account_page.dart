// 設定 › 帳號登入。排版照 iOS 版 AccountView。

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cloud.dart';
import 'models.dart';
import 'theme.dart';
import 'widgets.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _email = TextEditingController();
  bool _sending = false;
  String? _sentTo;

  Cloud get _cloud => Cloud.shared;
  List<SharedList>? _lists;
  String? _listsFor;

  /// 登入後讀一次自己分享的清單（換帳號會重讀）
  Future<void> _loadLists() async {
    final id = _cloud.session?.userId;
    _listsFor = id;
    if (id == null) return;
    try {
      final l = await _cloud.myLists();
      if (mounted && _listsFor == id) setState(() => _lists = l);
    } catch (_) {}
  }

  void _openList(SharedList l) {
    final code = Cloud.pretty(l.code);
    showAlert(context, l.name, message: '代碼 $code・${l.wordCount} 個字・剩 ${l.hoursLeft} 小時', actions: [
      AlertAction('拷貝代碼', onTap: () => Clipboard.setData(ClipboardData(text: code))),
      AlertAction('停止分享', destructive: true, onTap: () async {
        try {
          await _cloud.deleteList(l.code);
        } catch (e) {
          if (mounted) showAlert(context, '$e');
        }
        await _loadLists();
      }),
      const AlertAction('好', bold: true),
    ]);
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  bool get _validEmail {
    final t = _email.text.trim();
    return t.contains('@') && t.contains('.');
  }

  Future<void> _send() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final email = _email.text.trim();
    setState(() => _sending = true);
    try {
      await _cloud.sendLink(email);
      if (mounted) setState(() => _sentTo = email);
    } catch (e) {
      if (mounted) showAlert(context, '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sync() async {
    try {
      final r = await _cloud.sync();
      if (mounted && r.isNotEmpty) showAlert(context, r);
    } catch (e) {
      if (mounted) showAlert(context, '$e');
    }
  }

  String _time(DateTime? d) => d == null ? '還沒有' : '${d.year}/${d.month}/${d.day} ${hourMinute(d)}';

  List<Widget> _signedIn(Palette p, CloudSession s) => [
        Sec(header: '帳號', footer: '回到 App 時會自動同步，兩台裝置的單字和進度會合併，不會互相刪除。', children: [
          RowTile(title: 'Email', value: s.email),
          RowTile(title: '上次同步', value: _time(_cloud.lastSync)),
          RowTile(
            title: _cloud.syncing ? '同步中…' : '立即同步',
            titleColor: _cloud.syncing ? p.sec : p.accent,
            onTap: _cloud.syncing ? null : _sync,
          ),
        ]),
        _sharedLists(p),
        Sec(children: [RowTile(title: '登出', titleColor: p.destructive, onTap: _cloud.signOut)]),
      ];

  Widget _sharedLists(Palette p) {
    final live = (_lists ?? const <SharedList>[]).where((l) => l.hoursLeft > 0).toList();
    return Sec(
      header: '我分享的清單',
      footer: '代碼 72 小時後失效並從雲端刪除；從清單再分享一次可以延長。點一下可以拷貝或停止分享。',
      children: [
        if (live.isEmpty)
          RowTile(title: _lists == null ? '讀取中…' : '目前沒有分享中的清單', titleColor: p.sec)
        else
          for (final l in live)
            RowTile(
              title: l.name,
              subtitle: '${l.wordCount} 個字・剩 ${l.hoursLeft} 小時',
              value: Cloud.pretty(l.code),
              onTap: () => _openList(l),
            ),
      ],
    );
  }

  List<Widget> _signedOut(Palette p) {
    final canSend = !_sending && _validEmail;
    return [
      Sec(
        header: '登入',
        footer: _sentTo == null
            ? '用 Email 連結登入，資料會同步到雲端，也能參加單字對戰。iPhone 和 Android 用同一個帳號。'
            : '已寄到 $_sentTo。請在這支手機打開信件，點「Sign in」就會回到捲字完成登入。沒收到請查看垃圾郵件。',
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.send,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.email],
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (canSend || (!_sending && _validEmail)) _send();
              },
              style: ts(F.body, c: p.ink),
              decoration: InputDecoration(
                hintText: 'Email',
                hintStyle: ts(F.body, c: p.sec),
                border: InputBorder.none,
              ),
            ),
          ),
          RowTile(
            title: _sending ? '寄送中…' : '寄登入連結',
            titleColor: canSend ? p.accent : p.sec,
            onTap: canSend ? _send : null,
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _cloud,
      builder: (context, _) {
        final p = Palette.of(context);
        final s = _cloud.session;
        if (s?.userId != _listsFor) {
          _lists = null;
          _loadLists();
        }
        return NavPage(title: '帳號登入', safeTop: false, slivers: s == null ? _signedOut(p) : _signedIn(p, s));
      },
    );
  }
}
