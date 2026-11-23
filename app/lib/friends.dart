// 好友和公開房間：好友代碼（就是對戰的 pid）、連結、QR code、Instagram 限動圖片。
// 伺服器端在 supabase/battle_social.sql。連結格式：juango://friend/<好友代碼>、juango://room/<房間代碼>。

import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:ui' as ui;

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, MethodChannel;
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';
import 'package:share_plus/share_plus.dart';

import 'battle.dart';
import 'cloud.dart';
import 'theme.dart';
import 'widgets.dart';
import 'word_quota.dart' show appNavigator;

String _msg(Object e) => '$e'.replaceFirst(RegExp(r'（\d+）$'), '');

/// 好友代碼：pid 轉大寫，比較好念、好輸入
String friendCode(String pid) => pid.toUpperCase();
String friendLink(String code) => 'juango://friend/${code.toUpperCase()}';
String roomLink(String code) => 'juango://room/${code.toUpperCase()}';

class Friend extends BattleSide {
  Friend(super.j) : room = j['room'] as String?;

  /// 好友現在開著、還在等人的房間代碼
  final String? room;
}

class PublicRoom extends BattleSide {
  PublicRoom(super.j) : code = j['code'] as String;
  final String code;
}

class Social {
  static Future<List<Friend>> friends() async {
    final j = await Cloud.shared.rpc(
      'battle_friend_list',
      const {},
      const Duration(seconds: 10),
    );
    return [
      for (final x in (j as List? ?? const []))
        Friend(x as Map<String, dynamic>),
    ];
  }

  static Future<Friend> add(String code) async {
    final j = await Cloud.shared.rpc('battle_add_friend', {
      'p_code': code,
    }, const Duration(seconds: 10));
    return Friend(j as Map<String, dynamic>);
  }

  static Future<void> remove(String pid) => Cloud.shared.rpc(
    'battle_remove_friend',
    {'p_pid': pid},
    const Duration(seconds: 10),
  );

  static Future<List<PublicRoom>> publicRooms() async {
    final j = await Cloud.shared.rpc(
      'battle_public_rooms',
      const {},
      const Duration(seconds: 10),
    );
    return [
      for (final x in (j as List? ?? const []))
        PublicRoom(x as Map<String, dynamic>),
    ];
  }

  /// 自己的對戰資料（個人資料卡、好友代碼）
  static Future<BattlePlayer> me() async {
    final j = await Cloud.shared.rpc('battle_me', {
      'p_level': null,
    }, const Duration(seconds: 10));
    return BattlePlayer(j as Map<String, dynamic>);
  }
}

// MARK: 連結

/// App 被好友／房間連結打開時：加好友，或直接進那個房間
void listenForShareLinks() {
  Cloud.onShareLink = (uri) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = appNavigator.currentContext;
      if (c != null && c.mounted) unawaited(openShareLink(c, uri));
    });
  };
  final pending = Cloud.pendingShareLink;
  Cloud.pendingShareLink = null;
  if (pending != null) Cloud.onShareLink!(pending);
}

Future<void> openShareLink(BuildContext c, Uri uri) async {
  final code = uri.pathSegments.isEmpty
      ? ''
      : uri.pathSegments.first.toUpperCase().replaceAll(
          RegExp('[^A-Z0-9]'),
          '',
        );
  if (code.isEmpty) return;
  if (uri.host == 'room') {
    await presentFull(c, BattlePage(joinCode: code));
    return;
  }
  final room = await presentFull<String>(c, FriendsPage(addCode: code));
  if (room != null && c.mounted)
    await presentFull(c, BattlePage(joinCode: room));
}

// MARK: 好友邀請

bool _inviteShowing = false;
bool _inviteChecking = false;

/// 好友在房間裡按「邀請」：App 在前景、已登入、沒在配對／房間／對戰中時（停在對戰首頁也算），每 2 秒查一次，跳出邀請
/// （supabase/battle_lobby.sql 的 battle_my_invites）。和 iPhone 版 RootView 的邀請相同。
/// 上一次還沒查完就跳過這次，避免網路慢時同一個邀請跳兩次。
void listenForInvites() {
  Timer.periodic(const Duration(seconds: 2), (_) async {
    if (_inviteChecking) return;
    _inviteChecking = true;
    try {
      await _checkInvites();
    } finally {
      _inviteChecking = false;
    }
  });
}

Future<void> _checkInvites() async {
  if (_inviteShowing || !Cloud.shared.signedIn || BattlePage.inMatch) return;
  if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
  final List<dynamic> list;
  try {
    list = await Cloud.shared.rpc(
          'battle_my_invites',
          const {},
          const Duration(seconds: 8),
        )
        as List? ??
        const [];
  } catch (_) {
    return;
  }
  if (list.isEmpty || BattlePage.inMatch) return;
  final x = list.first as Map<String, dynamic>;
  final code = x['code'] as String;
  final c = appNavigator.currentContext;
  if (c == null || !c.mounted) return;
  _inviteShowing = true;
  // 跳過一次就不再跳；要加入的話一樣從這裡加入
  unawaited(
    Cloud.shared
        .rpc('battle_invite_dismiss', {'p_id': x['id']}, const Duration(seconds: 8))
        .catchError((_) => null),
  );
  try {
    await showAlert(
      c,
      '${x['name']} 邀請你對戰',
      message: '房間代碼 $code',
      actions: [
        const AlertAction('不要'),
        AlertAction(
          '加入',
          bold: true,
          onTap: () {
            if (!BattlePage.joinFromOpenPage(code)) {
              unawaited(presentFull(c, BattlePage(joinCode: code)));
            }
          },
        ),
      ],
    );
  } finally {
    _inviteShowing = false;
  }
}

// MARK: QR code

void paintQr(Canvas canvas, String data, Rect r, Color color) {
  final qr = QrImage(
    QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ),
  );
  final n = qr.moduleCount;
  final s = r.width / n;
  final path = Path();
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      if (qr.isDark(y, x))
        path.addRect(
          Rect.fromLTWH(r.left + x * s, r.top + y * s, s + .5, s + .5),
        );
    }
  }
  canvas.drawPath(
    path,
    Paint()
      ..color = color
      ..isAntiAlias = false,
  );
}

class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 160});
  final String data;
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'QR code',
    child: Container(
      width: size + 24,
      height: size + 24,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: RepaintBoundary(
        child: CustomPaint(size: Size.square(size), painter: _QrPainter(data)),
      ),
    ),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data);
  final String data;
  @override
  void paint(Canvas canvas, Size size) =>
      paintQr(canvas, data, Offset.zero & size, const Color(0xFF000000));
  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}

// MARK: 分享圖片

/// 1080×1920（限動尺寸）的分享圖：標題、QR code、代碼
Future<File> shareImage({
  required String title,
  required String code,
  required String link,
  required String hint,
  required Color bg,
  required Color fg,
}) async {
  const w = 1080.0, h = 1920.0;
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = bg);
  double text(
    String s,
    double size,
    double y, {
    FontWeight weight = FontWeight.w700,
    double spacing = 0,
  }) {
    final b =
        ui.ParagraphBuilder(ui.ParagraphStyle(textAlign: TextAlign.center))
          ..pushStyle(
            ui.TextStyle(
              color: fg,
              fontSize: size,
              fontWeight: weight,
              letterSpacing: spacing,
            ),
          )
          ..addText(s);
    final p = b.build()..layout(const ui.ParagraphConstraints(width: w - 140));
    c.drawParagraph(p, Offset(70, y));
    return y + p.height;
  }

  text('捲字 JuanGo・單字對戰', 52, 250, weight: FontWeight.w600);
  text(title, 88, 340);
  const qs = 620.0, qx = (w - qs) / 2, qy = 620.0;
  c.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(qx - 50, qy - 50, qs + 100, qs + 100),
      const Radius.circular(56),
    ),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  paintQr(
    c,
    link,
    const Rect.fromLTWH(qx, qy, qs, qs),
    const Color(0xFF000000),
  );
  final y = text(code, 120, qy + qs + 130, spacing: 12);
  text(hint, 42, y + 40, weight: FontWeight.w500);
  final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  final f = File('${(await getTemporaryDirectory()).path}/juango-$code.png');
  await f.writeAsBytes(data!.buffer.asUint8List(), flush: true);
  return f;
}

/// 分享圖片和連結文字（系統分享選單）
Future<void> shareCard(
  BuildContext context, {
  required String title,
  required String code,
  required String link,
  required String hint,
  required String text,
}) async {
  final p = Palette.of(context);
  final box = context.findRenderObject() as RenderBox?;
  try {
    final f = await shareImage(
      title: title,
      code: code,
      link: link,
      hint: hint,
      bg: p.accent,
      fg: p.onAccent,
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(f.path, mimeType: 'image/png')],
        text: text.isEmpty ? null : text,
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  } catch (e) {
    if (context.mounted) await showAlert(context, '無法分享', message: _msg(e));
  }
}

/// Meta App ID（developers.facebook.com 建立的 App）。2023 年起 Instagram 要求「分享到限時動態」
/// 一定要帶這個 ID，沒帶會說「不支援分享到限時動態」。還沒填時改用系統分享選單。
/// iOS 版填在 ios/Info.plist 的 FacebookAppID。
const facebookAppId = '';

const _instagram = MethodChannel('juango/instagram');

/// 直接打開 Instagram 限時動態編輯畫面，背景是 1080×1920 的分享圖
Future<void> shareToStory(
  BuildContext context, {
  required String title,
  required String code,
  required String link,
  required String hint,
}) async {
  final p = Palette.of(context);
  try {
    final f = await shareImage(
      title: title,
      code: code,
      link: link,
      hint: hint,
      bg: p.accent,
      fg: p.onAccent,
    );
    final r = Platform.isAndroid
        ? await _instagram.invokeMethod<String>('shareStory', {
            'path': f.path,
            'appId': facebookAppId,
          })
        : 'noAppId';
    if (!context.mounted) return;
    if (r == 'notInstalled') {
      await showAlert(context, '這台裝置沒有安裝 Instagram');
    } else if (r == 'noAppId') {
      await shareCard(
        context,
        title: title,
        code: code,
        link: link,
        hint: hint,
        text: '',
      );
    }
  } catch (e) {
    if (context.mounted) await showAlert(context, '無法分享', message: _msg(e));
  }
}

// MARK: 好友頁

class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key, this.me, this.addCode});

  /// 自己的對戰資料（個人資料卡和好友代碼）；沒有就自己讀
  final BattlePlayer? me;

  /// 從好友連結或 QR code 打開時，自動加這個代碼
  final String? addCode;
  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  final _code = TextEditingController();
  late BattlePlayer? _me = widget.me;
  bool _meFailed = false;
  List<Friend>? _friends;
  String? _failed;
  bool _busy = false;
  Timer? _refresh;

  String get _clean =>
      _code.text.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  @override
  void initState() {
    super.initState();
    if (!Cloud.shared.signedIn) return;
    unawaited(_load());
    if (_me == null) unawaited(_loadMe());
    final add = widget.addCode;
    if (add != null && add.isNotEmpty)
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_add(add)));
    // 好友開房間時「加入房間」要及時出現
    _refresh = Timer.periodic(
      const Duration(seconds: 8),
      (_) => unawaited(_load()),
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _loadMe() async {
    setState(() => _meFailed = false);
    try {
      final m = await Social.me();
      if (mounted) setState(() => _me = m);
    } catch (_) {
      if (mounted) setState(() => _meFailed = true);
    }
  }

  Future<void> _load() async {
    try {
      final f = await Social.friends();
      if (mounted)
        setState(() {
          _friends = f;
          _failed = null;
        });
    } catch (e) {
      if (mounted) setState(() => _failed = _msg(e));
    }
  }

  Future<void> _add(String code) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final f = await Social.add(code);
      _code.clear();
      await _load();
      if (mounted) await showAlert(context, '已加 ${f.name} 為好友');
    } catch (e) {
      if (mounted) await showAlert(context, '無法加好友', message: _msg(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static const _hint = '用相機掃 QR code，或在捲字「單字對戰 › 好友」輸入代碼';

  /// 分享按鈕：跳出面板選分享方式
  Future<void> _share(BuildContext c, String code) => chooseAction(
    context,
    '分享好友代碼',
    actions: [
      AlertAction(
        '複製代碼',
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: code));
          if (mounted) await showAlert(context, '已複製好友代碼');
        },
      ),
      AlertAction(
        '分享連結',
        onTap: () {
          final box = c.findRenderObject() as RenderBox?;
          unawaited(
            SharePlus.instance.share(
              ShareParams(
                text:
                    '加我捲字 JuanGo 好友，一起單字對戰！\n好友代碼：$code\n${friendLink(code)}',
                sharePositionOrigin: box == null
                    ? null
                    : box.localToGlobal(Offset.zero) & box.size,
              ),
            ),
          );
        },
      ),
      AlertAction(
        '分享 QR code 圖片',
        onTap: () => unawaited(
          shareCard(
            c,
            title: '加我好友',
            code: code,
            link: friendLink(code),
            hint: _hint,
            text: '加我捲字 JuanGo 好友：$code\n${friendLink(code)}',
          ),
        ),
      ),
      AlertAction(
        '分享到 Instagram 限動',
        onTap: () => unawaited(
          shareToStory(
            c,
            title: '加我好友',
            code: code,
            link: friendLink(code),
            hint: _hint,
          ),
        ),
      ),
    ],
  );

  void _tapFriend(Friend f) => showAlert(
    context,
    f.name,
    message: '${f.tierText}・${f.rating}',
    actions: [
      if (f.room != null)
        AlertAction(
          '加入房間',
          bold: true,
          onTap: () => Navigator.of(context).pop(f.room),
        ),
      AlertAction(
        '刪除好友',
        destructive: true,
        onTap: () async {
          final pid = f.pid;
          if (pid == null) return;
          try {
            await Social.remove(pid);
          } catch (_) {}
          await _load();
        },
      ),
      const AlertAction('取消'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (!Cloud.shared.signedIn) {
      return NavPage(
        title: '好友',
        close: true,
        slivers: const [Sec(footer: '登入後就能加好友、邀請好友對戰。')],
      );
    }
    final me = _me;
    final pid = me?.pid;
    final code = pid == null ? null : friendCode(pid);
    final friends = _friends;
    return NavPage(
      title: '好友',
      close: true,
      slivers: [
        // 個人資料卡：和單字對戰首頁的戰績相同，只是不能改名
        Sec(
          children: [
            if (me == null && _meFailed)
              RowTile(
                title: '讀不到個人資料，再試一次',
                titleColor: p.accent,
                onTap: () => unawaited(_loadMe()),
              )
            else
              Padding(
                padding: const EdgeInsets.all(16),
                child: me == null
                    ? const SizedBox(
                        height: 96,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  me.name,
                                  style: ts(F.headline, w: w6, c: p.ink),
                                ),
                              ),
                              const Spacer(),
                              Text(
                                me.tierText,
                                style: ts(F.sub, w: w6, c: p.accent),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${me.rating}',
                            style: ts(44, w: w7, c: p.ink, h: 1.15),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${me.wins} 勝　${me.losses} 敗　${me.draws} 和',
                            style: ts(F.sub, c: p.sec),
                          ),
                        ],
                      ),
              ),
          ],
        ),
        // 加好友：輸入朋友的代碼，或把自己的 QR code／代碼分享出去
        Sec(
          header: '加好友',
          footer: '朋友掃 QR code、點連結或輸入代碼，就會互相變成好友。',
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _code,
                      textCapitalization: TextCapitalization.characters,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) {
                        if (_clean.length >= 6) unawaited(_add(_clean));
                      },
                      style: ts(F.body, c: p.ink),
                      decoration: InputDecoration(
                        hintText: '輸入朋友的好友代碼',
                        hintStyle: ts(F.body, c: p.sec),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  Tap(
                    onTap: _clean.length >= 6 && !_busy
                        ? () => unawaited(_add(_clean))
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                      child: Text(
                        '加好友',
                        style: ts(F.body, w: w6, c: p.accent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: code == null
                    ? const SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : Column(
                        children: [
                          QrView(data: friendLink(code), size: 150),
                          const SizedBox(height: 12),
                          SelectableText(
                            code,
                            style: ts(
                              26,
                              w: w7,
                              c: p.ink,
                              mono: true,
                            ).copyWith(letterSpacing: 3),
                          ),
                        ],
                      ),
              ),
            ),
            if (code != null)
              Builder(
                builder: (c) => RowTile(
                  leading: Icon(Icons.ios_share_rounded, size: 21, color: p.accent),
                  title: '分享我的好友代碼',
                  onTap: () => unawaited(_share(c, code)),
                ),
              ),
          ],
        ),
        Sec(
          header: friends == null ? '好友' : '好友（${friends.length}）',
          footer:
              _failed ??
              (friends != null && friends.isEmpty
                  ? '還沒有好友。把好友代碼、連結或 QR code 傳給朋友吧。'
                  : '好友開了房間會顯示「加入房間」。點好友可以加入或刪除。'),
          children: [
            if (friends == null && _failed == null)
              const Padding(
                padding: EdgeInsets.all(18),
                child: Center(child: CircularProgressIndicator()),
              ),
            for (final f in friends ?? const <Friend>[])
              RowTile(
                leading: Icon(Icons.person_rounded, size: 21, color: p.accent),
                title: f.name,
                subtitle: '${f.tierText}・${f.rating}',
                trailing: f.room == null
                    ? null
                    : Text(
                        '加入房間',
                        style: ts(F.sub, w: w6, c: p.accent),
                      ),
                onTap: () => _tapFriend(f),
              ),
          ],
        ),
      ],
    );
  }
}

// MARK: 公開房間

class PublicRoomsPage extends StatefulWidget {
  const PublicRoomsPage({super.key});
  @override
  State<PublicRoomsPage> createState() => _PublicRoomsPageState();
}

class _PublicRoomsPageState extends State<PublicRoomsPage> {
  List<PublicRoom>? _rooms;
  String? _failed;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _refresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_load()),
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await Social.publicRooms();
      if (mounted)
        setState(() {
          _rooms = r;
          _failed = null;
        });
    } catch (e) {
      if (mounted) setState(() => _failed = _msg(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final rooms = _rooms;
    return NavPage(
      title: '公開房間',
      close: true,
      slivers: [
        Sec(
          footer:
              _failed ??
              (rooms != null && rooms.isEmpty
                  ? '現在沒有公開房間。你也可以建立房間，再打開「公開房間」。'
                  : '房間對戰不影響積分。每 5 秒自動更新。'),
          children: [
            if (rooms == null && _failed == null)
              const Padding(
                padding: EdgeInsets.all(18),
                child: Center(child: CircularProgressIndicator()),
              ),
            for (final r in rooms ?? const <PublicRoom>[])
              RowTile(
                leading: Icon(
                  Icons.meeting_room_rounded,
                  size: 21,
                  color: p.accent,
                ),
                title: r.name,
                subtitle: '${r.tierText}・${r.rating}',
                trailing: Text(
                  '加入',
                  style: ts(F.body, w: w6, c: p.accent),
                ),
                onTap: () => Navigator.of(context).pop(r.code),
              ),
          ],
        ),
      ],
    );
  }
}
