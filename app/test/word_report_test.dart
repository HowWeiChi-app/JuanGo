import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juango/cloud.dart';
import 'package:juango/models.dart';
import 'package:juango/word_report.dart';

import 'harness.dart';

class _NoVault implements CloudVault {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String? v) async {}
}

void main() {
  setUpAll(setUpData);
  setUp(resetState);

  test('App 版本和 pubspec.yaml 一致', () {
    final v = RegExp(
      r'^version:\s*([\d.]+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(appVersion, v);
  });

  test('沒網路時先存著，連上後補送一次', () async {
    var online = false;
    final sent = <Map<String, dynamic>>[];
    Cloud.resetForTest(
      MockClient((req) async {
        if (!online) throw const SocketException('offline');
        expect(req.url.path, endsWith('/rpc/report_word'));
        sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response('"ok"', 200);
      }),
      _NoVault(),
    );

    final w = Word(
      term: 'persuade',
      meanings: ['說服'],
      pos: 'v.',
      example: 'Try to persuade him.',
    );
    final now = await WordReport.submit(
      word: w.term,
      kind: 'meaning',
      note: '  應該是勸說  ',
      snapshot: WordReport.snapshot(w),
    );
    expect(now, isFalse);
    expect(await WordReport.pending(), hasLength(1));

    online = true;
    await WordReport.flush();
    await WordReport.flush(); // 送過的不會再送
    expect(sent, hasLength(1));
    expect(await WordReport.pending(), isEmpty);
    final a = sent.single;
    expect(a['p_word'], 'persuade');
    expect(a['p_kind'], 'meaning');
    expect(a['p_note'], '應該是勸說');
    expect(a['p_platform'], 'android');
    expect((a['p_snapshot'] as Map)['meanings'], ['說服']);
    expect(
      a['p_client_id'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(a['p_device'], isNotEmpty);
  });

  test('說明最多 200 字', () async {
    Map<String, dynamic>? got;
    Cloud.resetForTest(
      MockClient((req) async {
        got = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('"duplicate"', 200);
      }),
      _NoVault(),
    );
    final ok = await WordReport.submit(
      word: 'x',
      kind: 'other',
      note: 'a' * 300,
      snapshot: const {},
    );
    expect(ok, isTrue, reason: 'duplicate 也代表伺服器收過了，不用再送');
    expect((got!['p_note'] as String).length, 200);
  });
}
