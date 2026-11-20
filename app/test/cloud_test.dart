import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:juango/cloud.dart';
import 'package:juango/dictionary.dart';
import 'package:juango/models.dart';
import 'package:juango/store.dart';

import 'harness.dart';

class _MemoryVault implements CloudVault {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String? v) async => value = v;
}

String _jwt(Map<String, dynamic> claims) =>
    'x.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.y';

Uri _link({int expiresIn = 3600}) => Uri.parse(
  'juango://login-callback#access_token=${_jwt({'sub': 'user-1', 'email': 'a@example.com'})}&refresh_token=r1&expires_in=$expiresIn',
);

/// iOS 版傳上來的備份：日期是到秒的 ISO 8601，設定值混合各種型別
Map<String, dynamic> _iosBackup() => {
  'app': 'JuanGo',
  'format': 1,
  'kind': 'backup',
  'exportedAt': '2026-11-18T08:00:00Z',
  'words': [
    {
      'term': 'resilient',
      'ipa': 'rɪˈzɪliənt',
      'pos': 'adj.',
      'meanings': ['有韌性的'],
      'definition': '',
      'example': '',
      'exampleZh': '',
      'cefr': '6',
      'srsLevel': 3,
      'dueDate': '2030-01-02T00:00:00Z',
      'lastReviewed': '2026-11-18T07:00:00Z',
      'addedAt': '2026-11-01T07:00:00Z',
      'favorite': true,
      'inMyWords': true,
      'reviewCount': 4,
    },
  ],
  'lists': [
    {
      'name': '期中考',
      'createdAt': '2026-11-02T07:00:00Z',
      'terms': ['resilient'],
    },
  ],
  'logs': [
    {
      'term': 'resilient',
      'date': '2026-11-18T07:00:00Z',
      'result': 2,
      'wasNew': false,
    },
  ],
  'settings': {'dailyGoal': 99},
};

http.Response _rows(Map<String, dynamic> data) => http.Response.bytes(
  utf8.encode(
    jsonEncode([
      {'data': data},
    ]),
  ),
  200,
);

void main() {
  setUpAll(setUpData);
  setUp(resetState);

  Cloud cloud(MockClientHandler handler, [_MemoryVault? vault]) {
    Cloud.resetForTest(MockClient(handler), vault ?? _MemoryVault());
    return Cloud.shared;
  }

  test('登入連結要帶 iOS 用的回呼網址', () async {
    late http.Request sent;
    await cloud((r) async {
      sent = r;
      return http.Response('{}', 200);
    }).sendLink(' a@example.com ');
    expect(sent.url.path, '/auth/v1/otp');
    expect(sent.url.queryParameters['redirect_to'], 'juango://login-callback');
    expect(jsonDecode(sent.body), {
      'email': 'a@example.com',
      'create_user': true,
    });
  });

  test('讀得懂登入連結，並存進安全儲存', () async {
    final vault = _MemoryVault();
    final c = cloud((_) async => http.Response('[]', 200), vault);
    expect(c.handle(_link()), isTrue);
    expect(c.session?.userId, 'user-1');
    expect(c.session?.email, 'a@example.com');
    await Future<void>.delayed(Duration.zero);
    expect(vault.value, contains('user-1'));

    Cloud.resetForTest(
      MockClient((_) async => http.Response('[]', 200)),
      vault,
    );
    await Cloud.shared.load();
    expect(Cloud.shared.session?.email, 'a@example.com');
  });

  test('過期的連結給看得懂的訊息', () {
    final c = cloud((_) async => http.Response('', 200));
    final ok = c.handle(
      Uri.parse(
        'juango://login-callback#error=access_denied&error_description=Email+link+is+invalid+or+has+expired',
      ),
    );
    expect(ok, isFalse);
    expect(c.signedIn, isFalse);
    expect(c.notice, '登入連結已過期，請重新寄一次');
  });

  test('同步會合併 iOS 的資料，再把結果傳回去', () async {
    Map<String, dynamic>? uploaded;
    final c = cloud((r) async {
      if (r.method == 'GET') return _rows(_iosBackup());
      expect(r.url.path, '/rest/v1/user_backups');
      expect(r.headers['Prefer'], contains('merge-duplicates'));
      uploaded = jsonDecode(r.body) as Map<String, dynamic>;
      return http.Response('', 201);
    });
    AppStore.shared.add(Dict.all.first);
    c.handle(_link());

    expect(await c.sync(), startsWith('已同步'));
    final w = AppStore.shared.word('resilient')!;
    expect(w.srsLevel, 3);
    expect(w.favorite, isTrue);
    expect(AppStore.shared.lists.single.name, '期中考');
    expect(AppStore.shared.logs, hasLength(1));
    expect(c.lastSync, isNotNull);

    expect(uploaded!['user_id'], 'user-1');
    final data = uploaded!['data'] as Map<String, dynamic>;
    final terms = (data['words'] as List)
        .map((e) => (e as Map)['term'])
        .toList();
    expect(terms, containsAll(['resilient', Dict.all.first.w]));
    // iOS 的日期解析不接受小數秒
    final date =
        (data['words'] as List).cast<Map>().firstWhere(
              (e) => e['term'] == 'resilient',
            )['lastReviewed']
            as String;
    expect(date, matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')));
  });

  test('雲端的設定不會蓋掉這台裝置的設定', () async {
    final c = cloud(
      (r) async =>
          r.method == 'GET' ? _rows(_iosBackup()) : http.Response('', 201),
    );
    c.handle(_link());
    await c.sync();
    expect(AppStore.shared.fullBackup()['settings']['dailyGoal'], isNot(99));
  });

  test('token 過期會自動更新，同時的請求只更新一次', () async {
    var refreshes = 0;
    final seen = <String?>[];
    final c = cloud((r) async {
      if (r.url.path == '/auth/v1/token') {
        refreshes += 1;
        expect(jsonDecode(r.body)['refresh_token'], 'r1');
        return http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'r2',
            'expires_in': 3600,
          }),
          200,
        );
      }
      seen.add(r.headers['Authorization']);
      return http.Response(
        r.method == 'GET' ? '[]' : '',
        r.method == 'GET' ? 200 : 201,
      );
    });
    c.handle(_link(expiresIn: 0));
    await Future.wait([c.sync(), c.backgroundPush()]);
    expect(refreshes, 1);
    expect(seen, everyElement('Bearer new'));
    expect(c.session?.refreshToken, 'r2');
  });

  test('refresh token 失效就登出，並說明原因', () async {
    final c = cloud(
      (_) async => http.Response(
        jsonEncode({'error_description': 'Invalid Refresh Token'}),
        400,
      ),
    );
    c.handle(_link(expiresIn: 0));
    await expectLater(
      c.sync(),
      throwsA(predicate((e) => '$e' == '登入已過期，請重新登入')),
    );
    expect(c.signedIn, isFalse);
    expect(c.syncing, isFalse);
  });

  test('更新 token 沒收到回覆會馬上重試，並把新 token 存好', () async {
    var refreshes = 0;
    final vault = _MemoryVault();
    final c = cloud((r) async {
      if (r.url.path == '/auth/v1/token') {
        refreshes += 1;
        if (refreshes == 1) throw http.ClientException('connection lost');
        return http.Response(
          jsonEncode({
            'access_token': 'new',
            'refresh_token': 'r2',
            'expires_in': 3600,
          }),
          200,
        );
      }
      return http.Response(
        r.method == 'GET' ? '[]' : '',
        r.method == 'GET' ? 200 : 201,
      );
    }, vault);
    c.handle(_link(expiresIn: 0));
    await c.sync();
    expect(refreshes, 2);
    expect(c.session?.refreshToken, 'r2');
    expect(vault.value, contains('r2'));
  });

  test('連不上或伺服器出錯時不會登出', () async {
    for (final fail in <Future<http.Response> Function()>[
      () async => throw http.ClientException('offline'),
      () async => http.Response('{}', 500),
    ]) {
      final vault = _MemoryVault();
      final c = cloud((_) => fail(), vault);
      c.handle(_link(expiresIn: 0));
      await expectLater(c.sync(), throwsA(isA<CloudFailure>()));
      expect(c.signedIn, isTrue);
      expect(vault.value, contains('r1'));
    }
  });

  test('進背景時 token 已過期就不更新，留到下次打開', () async {
    var requests = 0;
    final c = cloud((_) async {
      requests += 1;
      return http.Response('', 201);
    });
    c.handle(_link(expiresIn: 0));
    await c.backgroundPush();
    expect(requests, 0);
    expect(c.session?.refreshToken, 'r1');
  });

  test('分享代碼：第一次建立，同一個清單再分享就更新同一個代碼', () async {
    final sent = <String>[];
    final c = cloud((r) async {
      sent.add('${r.method} ${r.url.path}?${r.url.query}');
      if (r.method == 'POST') {
        expect((jsonDecode(r.body) as Map)['name'], '期中考');
        return http.Response.bytes(
          utf8.encode(
            jsonEncode([
              {'code': 'K7Q3P9XM'},
            ]),
          ),
          201,
        );
      }
      return http.Response.bytes(
        utf8.encode(
          jsonEncode([
            {'code': 'K7Q3P9XM'},
          ]),
        ),
        200,
      );
    });
    c.handle(_link());
    AppStore.shared.add(Dict.all.first);
    final file = AppStore.shared.listFile('期中考', AppStore.shared.wordList);
    expect(await c.share(file, 'custom:1'), 'K7Q3P9XM');
    expect(await c.share(file, 'custom:1'), 'K7Q3P9XM');
    expect(sent.first, startsWith('POST /rest/v1/shared_lists'));
    expect(
      sent.last,
      startsWith('PATCH /rest/v1/shared_lists?code=eq.K7Q3P9XM'),
    );
    expect(Cloud.pretty('k7q3p9xm'), 'K7Q3-P9XM');
  });

  test('過期或打錯的代碼給看得懂的訊息；拿得到的清單能讀', () async {
    final list = AppStore.shared.listFile('朋友的', [
      Word.fromEntry(Dict.all.first),
    ]);
    var rows = <Object>[];
    final c = cloud(
      (_) async => http.Response.bytes(utf8.encode(jsonEncode(rows)), 200),
    );
    await expectLater(
      c.fetch('K7Q3-P9XM'),
      throwsA(predicate((e) => '$e'.contains('72 小時'))),
    );
    rows = [
      {'data': list},
    ];
    final f = await c.fetch('K7Q3-P9XM');
    expect(f.isBackup, isFalse);
    expect(f.listName, '朋友的');
  });

  test('分享中的清單顯示還剩幾小時，過期的是 0', () {
    final now = DateTime.now();
    expect(
      SharedList(
        code: 'A',
        name: 'a',
        wordCount: 1,
        expiresAt: now.add(const Duration(hours: 71, minutes: 10)),
      ).hoursLeft,
      72,
    );
    expect(
      SharedList(
        code: 'A',
        name: 'a',
        wordCount: 1,
        expiresAt: now.add(const Duration(minutes: 5)),
      ).hoursLeft,
      1,
    );
    expect(
      SharedList(
        code: 'A',
        name: 'a',
        wordCount: 1,
        expiresAt: now.subtract(const Duration(minutes: 1)),
      ).hoursLeft,
      0,
    );
  });

  test('比 App 新的備份格式不會被硬讀', () async {
    final c = cloud((_) async => _rows({..._iosBackup(), 'format': 3}));
    c.handle(_link());
    await expectLater(
      c.sync(),
      throwsA(predicate((e) => '$e'.contains('較新版'))),
    );
    expect(AppStore.shared.word('resilient'), isNull);
  });
}
