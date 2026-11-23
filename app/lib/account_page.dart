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
  final _code = TextEditingController();
  bool _sending = false;
  bool _verifying = false;
  bool _deleting = false;
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
    showAlert(
      context,
      l.name,
      message: '代碼 $code・${l.wordCount} 個字・剩 ${l.hoursLeft} 小時',
      actions: [
        AlertAction(
          '拷貝代碼',
          onTap: () => Clipboard.setData(ClipboardData(text: code)),
        ),
        AlertAction(
          '停止分享',
          destructive: true,
          onTap: () async {
            try {
              await _cloud.deleteList(l.code);
            } catch (e) {
              if (mounted) showAlert(context, '$e');
            }
            await _loadLists();
          },
        ),
        const AlertAction('好', bold: true),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _code.addListener(() {
      if (mounted) setState(() {});
    });
    if (_cloud.signedIn && _cloud.account == null) _cloud.loadAccount();
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
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
      await _cloud.sendCode(email);
      if (mounted) {
        setState(() {
          _sentTo = email;
          _code.clear();
        });
      }
    } catch (e) {
      if (mounted) showAlert(context, '$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verify() async {
    final email = _sentTo;
    if (email == null || _code.text.length != 6 || _verifying) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _verifying = true);
    try {
      final msg = await _cloud.verify(email, _code.text);
      _sentTo = null;
      _code.clear();
      if (mounted) showAlert(context, msg);
    } catch (e) {
      _code.clear();
      if (mounted) showAlert(context, '$e');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _confirmDelete() => showAlert(
    context,
    '刪除帳號？',
    message:
        '會永久刪除這個帳號和雲端上的所有資料，無法復原。這台裝置上的單字和進度會保留。有訂閱的話，要另外到 Google Play 取消。',
    actions: [
      const AlertAction('取消'),
      AlertAction('刪除', destructive: true, bold: true, onTap: _delete),
    ],
  );

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      await _cloud.deleteAccount();
      if (mounted) showAlert(context, '帳號已刪除');
    } catch (e) {
      if (mounted) showAlert(context, '$e');
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  bool _signingOut = false;

  void _confirmSignOut() => showAlert(
    context,
    '要登出嗎？',
    message: '會先把單字、進度和設定傳到雲端，再從這支手機移除。下次登入就會回來。',
    actions: [
      const AlertAction('取消'),
      AlertAction('登出', destructive: true, bold: true, onTap: _signOut),
    ],
  );

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    try {
      await _cloud.signOut();
    } catch (e) {
      if (mounted) showAlert(context, '沒有登出：資料還沒傳到雲端（$e）。請連上網路再試一次。');
    } finally {
      if (mounted) setState(() => _signingOut = false);
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

  String _time(DateTime? d) =>
      d == null ? '還沒有' : '${d.year}/${d.month}/${d.day} ${hourMinute(d)}';

  List<Widget> _signedIn(Palette p, CloudSession s) => [
    Sec(
      header: '帳號',
      footer: '回到 App 時會自動同步，兩台裝置的單字和進度會合併，不會互相刪除。設定也會存到雲端，登入新手機時一起拿回來。',
      children: [
        RowTile(
          title: '使用者 ID',
          value: _cloud.accountId ?? '讀取中…',
          onTap: _cloud.accountId == null
              ? null
              : () {
                  Clipboard.setData(ClipboardData(text: _cloud.accountId!));
                  showAlert(context, '已拷貝使用者 ID');
                },
        ),
        RowTile(title: 'Email', value: s.email),
        RowTile(title: '上次同步', value: _time(_cloud.lastSync)),
        RowTile(
          title: _cloud.syncing ? '同步中…' : '立即同步',
          titleColor: _cloud.syncing ? p.sec : p.accent,
          onTap: _cloud.syncing ? null : _sync,
        ),
      ],
    ),
    _sharedLists(p),
    Sec(
      footer: '登出會先把單字、進度和設定傳到雲端，再從這支手機移除，下次登入就會回來。刪除帳號會刪掉雲端上的備份和分享中的清單，這台裝置上的單字和進度會保留。',
      children: [
        RowTile(
          title: _signingOut ? '登出中…' : '登出',
          titleColor: p.destructive,
          onTap: _signingOut ? null : _confirmSignOut,
        ),
        RowTile(
          title: _deleting ? '刪除中…' : '刪除帳號',
          titleColor: p.destructive,
          onTap: _deleting ? null : _confirmDelete,
        ),
      ],
    ),
  ];

  Widget _sharedLists(Palette p) {
    final live = (_lists ?? const <SharedList>[])
        .where((l) => l.hoursLeft > 0)
        .toList();
    return Sec(
      header: '我分享的清單',
      footer: '代碼 72 小時後失效並從雲端刪除；從清單再分享一次可以延長。點一下可以拷貝或停止分享。',
      children: [
        if (live.isEmpty)
          RowTile(
            title: _lists == null ? '讀取中…' : '目前沒有分享中的清單',
            titleColor: p.sec,
          )
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
    final sent = _sentTo;
    return [
      Sec(
        header: '登入',
        footer: '用 Email 收 6 位數驗證碼登入，資料會同步到雲端，也能參加單字對戰。iPhone 和 Android 用同一個帳號。',
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _email,
              enabled: sent == null,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.send,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.email],
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (canSend) _send();
              },
              style: ts(F.body, c: p.ink),
              decoration: InputDecoration(
                hintText: 'Email',
                hintStyle: ts(F.body, c: p.sec),
                border: InputBorder.none,
              ),
            ),
          ),
          if (sent == null)
            RowTile(
              title: _sending ? '寄送中…' : '寄驗證碼',
              titleColor: canSend ? p.accent : p.sec,
              onTap: canSend ? _send : null,
            ),
        ],
      ),
      if (sent != null)
        Sec(
          header: '輸入驗證碼',
          footer: '已寄到 $sent，在任何裝置上看信都可以。沒收到請查看垃圾郵件。',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: CodeBoxes(controller: _code, onDone: _verify),
            ),
            RowTile(
              title: _verifying ? '登入中…' : '登入',
              titleColor: !_verifying && _code.text.length == 6
                  ? p.accent
                  : p.sec,
              onTap: !_verifying && _code.text.length == 6 ? _verify : null,
            ),
            RowTile(
              title: '重新寄驗證碼',
              titleColor: _sending ? p.sec : p.accent,
              onTap: _sending ? null : _send,
            ),
            RowTile(
              title: '換一個 Email',
              titleColor: p.accent,
              onTap: () => setState(() {
                _sentTo = null;
                _code.clear();
              }),
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
        return NavPage(
          title: '帳號登入',
          slivers: s == null ? _signedOut(p) : _signedIn(p, s),
        );
      },
    );
  }
}

/// 6 格驗證碼：一個看不到的輸入框接收打字（和鍵盤建議的簡訊／信件驗證碼），上面畫 6 格
class CodeBoxes extends StatefulWidget {
  const CodeBoxes({super.key, required this.controller, required this.onDone});
  final TextEditingController controller;
  final VoidCallback onDone;
  @override
  State<CodeBoxes> createState() => _CodeBoxesState();
}

class _CodeBoxesState extends State<CodeBoxes> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final code = widget.controller.text;
    return Semantics(
      label: '6 位數驗證碼',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _focus.requestFocus,
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  showCursor: false,
                  onChanged: (v) {
                    if (v.length == 6) widget.onDone();
                  },
                ),
              ),
            ),
            IgnorePointer(
              child: ListenableBuilder(
                listenable: _focus,
                builder: (context, _) => Row(
                  children: [
                    for (var i = 0; i < 6; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: p.fill,
                            borderRadius: BorderRadius.circular(Radii.md),
                            border: Border.all(
                              color: _focus.hasFocus &&
                                      i == (code.length < 6 ? code.length : 5)
                                  ? p.accent
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: Text(
                            i < code.length ? code[i] : '',
                            style: ts(24, w: w7, c: p.ink),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
