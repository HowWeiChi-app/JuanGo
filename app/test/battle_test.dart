// 單字對戰：用假的伺服器走完一場，並檢查每個畫面在小螢幕和大螢幕都不會爆版。

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juango/battle.dart';
import 'package:juango/cloud.dart';
import 'package:juango/store.dart';
import 'package:juango/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

const _shots = String.fromEnvironment('SHOTS');

class _Vault implements CloudVault {
  _Vault(this.value);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? v) async => value = v;
}

Map<String, dynamic> _side(String name, int score) => {
  'name': name,
  'rating': 1000,
  'tier': 2,
  'score': score,
};

Future<void> _signIn(http.Client client) async {
  final claims = base64Url
      .encode(utf8.encode(jsonEncode({'sub': 'u1', 'email': 'a@example.com'})))
      .replaceAll('=', '');
  Cloud.resetForTest(client, _Vault(null));
  Cloud.shared.handle(
    Uri.parse(
      'juango://login-callback#access_token=x.$claims.y&refresh_token=r&expires_in=3600',
    ),
  );
}

void main() {
  setUpAll(setUpData);
  setUp(() => resetState(onboarded: true));

  test('配對、作答到結算', () async {
    final calls = <String, List<Map<String, dynamic>>>{};
    var polls = 0;
    await _signIn(
      MockClient((req) async {
        final name = req.url.pathSegments.last;
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        (calls[name] ??= []).add(body);
        final now = DateTime.now().millisecondsSinceEpoch + 5000; // 伺服器時鐘快五秒
        Object res;
        switch (name) {
          case 'battle_me':
            res = {
              'name': '甲',
              'rating': 1000,
              'tier': 2,
              'games': 0,
              'wins': 0,
              'losses': 0,
              'draws': 0,
            };
          case 'battle_find':
            res = calls[name]!.length == 1
                ? {'match': null, 'waited': 0}
                : {'match': 'm1'};
          default:
            final done = name == 'battle_state' && ++polls > 4;
            res = {
              'id': 'm1',
              'status': done ? 'finished' : 'playing',
              'rated': true,
              'round': 5,
              'now': now,
              'you': _side('甲', done ? 150 : 0),
              'opponent': _side('乙', 0),
              'starts': now - 2000,
              'ends': now + 8000,
              'question': {
                'n': 5,
                'to_zh': false,
                'prompt': '說服',
                'options': ['persuade', 'avoid', 'admit', 'delay'],
                'pos': 'v.',
              },
              if (done)
                'last': {
                  'n': 5,
                  'answer': 0,
                  'pick': 0,
                  'points': 150,
                  'opponent_points': 0,
                },
              if (done)
                'result': {
                  'outcome': 'win',
                  'reason': 'score',
                  'delta': 20,
                  'words': [
                    {'term': 'persuade', 'zh': '說服', 'right': false},
                  ],
                },
            };
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(res)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final m = BattleModel(
      level: '2',
      resultDelay: Duration.zero,
      pollEvery: const Duration(milliseconds: 20),
    );
    final running = m.find();
    while (m.phase != BattlePhase.finished) {
      if (m.state?.status == 'playing') m.answer(0);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await running;
    expect(calls['battle_find']!.first['p_level'], 2);
    final sent = calls['battle_answer']!.single;
    expect(sent['p_pick'], 0);
    expect(sent['p_round'], 5);
    expect(
      sent['p_ms'] as int,
      inInclusiveRange(1900, 2600),
      reason: '要用伺服器時間算作答秒數',
    );
    expect(m.state!.result!.delta, 20);
    expect(m.current?.pos ?? m.state?.question?.pos, 'v.');
    m.dispose();
  });

  test('改對戰名稱：成功更新畫面資料，失敗顯示原因', () async {
    var taken = false;
    await _signIn(
      MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.url.pathSegments.last, 'battle_set_name');
        if (taken)
          return http.Response.bytes(
            utf8.encode(jsonEncode({'message': '這個名稱已經有人使用'})),
            400,
          );
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'name': body['p_name'],
              'rating': 400,
              'tier': 3,
              'games': 0,
              'wins': 0,
              'losses': 0,
              'draws': 0,
            }),
          ),
          200,
        );
      }),
    );
    final m = BattleModel(level: '3');
    expect(await m.rename('單字小王'), isNull);
    expect(m.me?.name, '單字小王');
    taken = true;
    expect(await m.rename('別人的名字'), '這個名稱已經有人使用');
    expect(m.me?.name, '單字小王');
    m.dispose();
  });

  test('檢舉和封鎖送出對方的 pid，不計分的場次帶著說明', () async {
    final calls = <String, Map<String, dynamic>>{};
    await _signIn(
      MockClient((req) async {
        calls[req.url.pathSegments.last] =
            jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          'null',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final m = BattleModel(level: '3');
    expect(await m.report('abc123', 'vulgar'), isNull);
    expect(await m.block('abc123'), isNull);
    expect(calls['battle_report'], {'p_pid': 'abc123', 'p_reason': 'vulgar'});
    expect(calls['battle_block'], {'p_pid': 'abc123'});
    final s = BattleState({
      'id': 'm',
      'status': 'playing',
      'rated': false,
      'round': 1,
      'now': 0,
      'you': _side('甲', 0),
      'rounds': 10,
      'note': '你們今天已經對戰 3 場，這場不計分',
    });
    expect(s.rounds, 10);
    expect(s.note, contains('不計分'));
    m.dispose();
  });

  test('伺服器還沒裝對戰功能時說清楚', () async {
    await _signIn(
      MockClient(
        (_) async => http.Response(
          '{"message":"Could not find the function public.battle_me"}',
          404,
        ),
      ),
    );
    final m = BattleModel(level: '3');
    await m.load();
    expect(m.error, '對戰伺服器還沒開通');
    m.dispose();
  });

  for (final size in const [Size(320, 568), Size(430, 932)]) {
    for (final step in const [
      'home',
      'search',
      'room',
      'lobby',
      'question',
      'reveal',
      'result',
      'board',
    ]) {
      testWidgets('$step ${size.width.toInt()}', (t) async {
        final root = GlobalKey();
        Cloud.resetForTest(
          MockClient((_) async => http.Response('{}', 200)),
          _Vault(null),
        );
        AppStore.resetForTest();
        t.view.physicalSize = size * 3;
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        if (_shots.isNotEmpty) {
          await t.runAsync(() async {
            for (final (family, path) in const [
              (
                'MaterialIcons',
                '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ),
              (
                'Roboto',
                '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
              ),
              (
                'monospace',
                '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
              ),
            ]) {
              await (FontLoader(family)..addFont(
                    Future.value(
                      ByteData.sublistView(File(path).readAsBytesSync()),
                    ),
                  ))
                  .load();
            }
          });
        }
        final m = BattleModel(level: '4')
          ..demo(step == 'board' ? 'home' : step);
        await t.pumpWidget(
          RepaintBoundary(
            key: root,
            child: MaterialApp(
              theme: ThemeData(fontFamily: 'Roboto'),
              home: Builder(
                builder: (c) => Material(
                  color: Palette.of(c).bg,
                  child: step == 'board'
                      ? BattleBoardPage(model: m)
                      : BattlePage(model: m),
                ),
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
        expect(t.takeException(), isNull);
        if (step == 'home') {
          expect(find.text('至尊星耀'), findsOneWidget);
          expect(find.text('離無雙卷哥還差 182 分'), findsOneWidget);
        }
        if (step == 'result') expect(find.text('合計'), findsOneWidget);
        if (step == 'question') {
          expect(find.text('第 3 / 10 題'), findsOneWidget);
          expect(find.text('v.'), findsOneWidget, reason: '題目要標詞性');
        }
        if (step == 'board') expect(find.text('2026 S6 即時排名'), findsOneWidget);
        if (_shots.isNotEmpty && size.width > 400) {
          await t.runAsync(() async {
            final image =
                await (root.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            File('$_shots/battle-$step.png')
              ..createSync(recursive: true)
              ..writeAsBytesSync(data!.buffer.asUint8List());
          });
        }
        await t.pumpWidget(const SizedBox());
      });
    }
  }
}
