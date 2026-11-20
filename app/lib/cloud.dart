// 帳號與同步：Email 登入連結、把單字和進度備份到雲端。
// 和 iOS 版共用同一個 Supabase 專案和同一份備份格式，同一個帳號在兩邊的資料會合併。

import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'dev_log.dart';
import 'store.dart';

/// 這把 key 本來就要放在 App 裡，能碰到什麼由 supabase/schema.sql 的資料列權限決定
class CloudConfig {
  static const url = 'https://zqvxfundqjegjveifqus.supabase.co';
  static const key = 'sb_publishable_gUOXTGlBLJQPrfEE1edEag_NAo5mI68';
  static const redirect = 'juango://login-callback';
}

class CloudFailure implements Exception {
  const CloudFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class CloudSession {
  CloudSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.userId,
    required this.email,
  });

  factory CloudSession.fromJson(Map<String, dynamic> j) => CloudSession(
    accessToken: j['accessToken'] as String,
    refreshToken: j['refreshToken'] as String,
    expiresAt: DateTime.parse(j['expiresAt'] as String),
    userId: j['userId'] as String,
    email: j['email'] as String? ?? '',
  );

  String accessToken, refreshToken;
  DateTime expiresAt;
  final String userId, email;

  Map<String, dynamic> toJson() => {
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'userId': userId,
    'email': email,
  };
}

/// 登入資料放的地方；App 用系統加密儲存，測試換成記憶體
abstract class CloudVault {
  Future<String?> read();
  Future<void> write(String? value);
}

class _SecureVault implements CloudVault {
  static const _storage = FlutterSecureStorage();
  static const _key = 'cloud.session';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String? value) => value == null
      ? _storage.delete(key: _key)
      : _storage.write(key: _key, value: value);
}

class Cloud extends ChangeNotifier {
  Cloud._(this._client, this._vault);
  static Cloud shared = Cloud._(http.Client(), _SecureVault());

  @visibleForTesting
  static void resetForTest(http.Client client, CloudVault vault) =>
      shared = Cloud._(client, vault);

  static const _lastSyncKey = 'cloud.lastSync';

  final http.Client _client;
  final CloudVault _vault;
  StreamSubscription<Uri>? _links;
  Future<String>? _refreshing;
  String? _lastLink;

  CloudSession? session;
  DateTime? lastSync;
  bool syncing = false;

  /// 登入連結回來時要告訴使用者的話
  String? notice;

  bool get signedIn => session != null;

  /// 讀不出登入資料（例如換手機還原）就當作沒登入，不影響 App 其他功能
  Future<void> load() async {
    try {
      final saved = await _vault.read();
      if (saved != null)
        session = CloudSession.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
        );
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_lastSyncKey);
      lastSync = last == null ? null : DateTime.tryParse(last)?.toLocal();
    } catch (e) {
      debugPrint('登入資料讀取失敗：$e');
      session = null;
    }
  }

  /// 開始接收登入連結。App 是被連結打開時，第一筆就是那個連結
  void listenForLinks() {
    if (_links != null) return;
    try {
      _links = AppLinks().uriLinkStream.listen(
        open,
        onError: (Object e) => debugPrint('登入連結讀取失敗：$e'),
      );
    } catch (e) {
      debugPrint('登入連結無法使用：$e');
    }
  }

  // MARK: 登入

  Future<void> sendLink(String email) async {
    await _send(
      Uri.parse('${CloudConfig.url}/auth/v1/otp')
          .replace(queryParameters: {'redirect_to': CloudConfig.redirect}),
      'POST',
      json: {'email': email.trim(), 'create_user': true},
      auth: false,
    );
  }

  /// 收到 juango://login-callback：登入成功就同步一次
  Future<void> open(Uri uri) async {
    final raw = uri.toString();
    if (raw == _lastLink) return; // 畫面重建時系統可能再給一次同一個連結
    _lastLink = raw;
    if (!handle(uri)) {
      notifyListeners();
      return;
    }
    final email = session?.email ?? '';
    try {
      final result = await sync();
      notice = '已登入 $email（$result）';
    } catch (e) {
      notice = '已登入 $email，但同步失敗：$e';
    }
    notifyListeners();
  }

  /// juango://login-callback#access_token=…&refresh_token=…&expires_in=…（或 #error=…）。
  /// 這個連結讓使用者完成登入時回傳 true
  bool handle(Uri uri) {
    if (uri.scheme != 'juango') return false;
    final Map<String, String> p;
    try {
      p = Uri.splitQueryString(
        uri.fragment.isNotEmpty ? uri.fragment : uri.query,
      );
    } catch (_) {
      notice = '登入失敗：看不懂登入資料';
      return false;
    }
    final error = p['error_description'] ?? p['error'];
    if (error != null) {
      notice = error.contains('expired') ? '登入連結已過期，請重新寄一次' : '登入失敗：$error';
      return false;
    }
    final access = p['access_token'], refresh = p['refresh_token'];
    if (access == null || refresh == null) return false;
    final claims = _claims(access);
    final sub = claims?['sub'];
    if (sub is! String) {
      notice = '登入失敗：看不懂登入資料';
      return false;
    }
    _store(
      CloudSession(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: _expiry(num.tryParse(p['expires_in'] ?? '') ?? 3600),
        userId: sub,
        email: claims?['email'] as String? ?? '',
      ),
    );
    return true;
  }

  Future<void> signOut() async {
    final token = session?.accessToken;
    _store(null);
    lastSync = null;
    notifyListeners();
    try {
      (await SharedPreferences.getInstance()).remove(_lastSyncKey);
      if (token != null) {
        await _client
            .post(
              Uri.parse('${CloudConfig.url}/auth/v1/logout'),
              headers: {
                'apikey': CloudConfig.key,
                'Authorization': 'Bearer $token',
              },
            )
            .timeout(const Duration(seconds: 10));
      }
    } catch (e) {
      debugPrint('登出時連不上伺服器：$e');
    }
  }

  /// 刪除帳號和雲端上的所有資料；這台裝置上的單字會保留
  Future<void> deleteAccount() async {
    await _send(_rest('rpc/delete_my_account'), 'POST', json: {});
    _store(null);
    lastSync = null;
    notifyListeners();
    try {
      (await SharedPreferences.getInstance()).remove(_lastSyncKey);
    } catch (_) {}
  }

  static DateTime _expiry(num seconds) =>
      DateTime.now().add(Duration(seconds: seconds.toInt() - 60));

  void _store(CloudSession? s) {
    if ((s == null) != (session == null))
      DevLog.add('cloud', s == null ? '登出' : '登入');
    session = s;
    unawaited(_persist(s));
  }

  Future<void> _persist(CloudSession? s) async {
    try {
      await _vault.write(s == null ? null : jsonEncode(s.toJson()));
    } catch (e) {
      debugPrint('登入資料儲存失敗：$e');
    }
  }

  static Map<String, dynamic>? _claims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return null;
    try {
      return jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<String> _accessToken() {
    final s = session;
    if (s == null) throw const CloudFailure('請先登入');
    if (s.expiresAt.isAfter(DateTime.now())) return Future.value(s.accessToken);
    // refresh token 只能用一次，同時有兩個請求時要共用同一次更新
    return _refreshing ??= _refresh(s).whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh(CloudSession s) async {
    Future<String> request() => _send(
      Uri.parse('${CloudConfig.url}/auth/v1/token')
          .replace(queryParameters: {'grant_type': 'refresh_token'}),
      'POST',
      json: {'refresh_token': s.refreshToken},
      auth: false,
    );
    try {
      final String body;
      try {
        body = await request();
      } on _HttpFailure {
        rethrow;
      } on CloudFailure {
        // 沒收到回覆：伺服器幾秒內還接受同一個 token，馬上再問一次才拿得到新的
        return await _finishRefresh(s, await request());
      }
      return await _finishRefresh(s, body);
    } on _HttpFailure catch (e) {
      if (e.status == 400 || e.status == 401) {
        if (identical(session, s)) _store(null);
        notifyListeners();
        throw const CloudFailure('登入已過期，請重新登入');
      }
      rethrow;
    }
  }

  Future<String> _finishRefresh(CloudSession s, String body) async {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final access = j['access_token'], refresh = j['refresh_token'];
    if (access is! String || refresh is! String)
      throw const CloudFailure('登入資料更新失敗');
    s
      ..accessToken = access
      ..refreshToken = refresh
      ..expiresAt = _expiry(j['expires_in'] as num? ?? 3600);
    // 舊 token 已經失效，新的存好才算完成
    if (identical(session, s)) await _persist(s);
    return access;
  }

  // MARK: 同步

  /// 先把雲端備份合併進這台裝置（不刪任何東西），再把合併後的結果傳回去
  Future<String> sync() async {
    if (!signedIn || syncing) return '';
    syncing = true;
    notifyListeners();
    try {
      var result = '已上傳';
      final remote = await _download();
      if (remote != null)
        result = '已同步（${AppStore.shared.restore(remote, settings: false)}）';
      await _upload();
      await _markSynced();
      return result;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  /// 回到 App 時的自動同步，失敗了下次再試，不打擾使用者
  Future<void> syncQuietly() async {
    try {
      await sync();
    } catch (e) {
      debugPrint('同步失敗：$e');
    }
  }

  /// App 進背景時把最新資料傳上去。token 過期就等下次打開，免得更新到一半被系統暫停
  Future<void> backgroundPush() async {
    final s = session;
    if (s == null || syncing || !s.expiresAt.isAfter(DateTime.now())) return;
    try {
      await _upload();
      await _markSynced();
      notifyListeners();
    } catch (e) {
      debugPrint('上傳失敗：$e');
    }
  }

  Future<void> _markSynced() async {
    lastSync = DateTime.now();
    (await SharedPreferences.getInstance()).setString(
      _lastSyncKey,
      lastSync!.toUtc().toIso8601String(),
    );
  }

  Uri _rest(String path, [Map<String, String>? query]) =>
      Uri.parse('${CloudConfig.url}/rest/v1/$path')
          .replace(queryParameters: query);

  Future<void> _upload() async {
    final s = session;
    if (s == null) return;
    await _send(
      _rest('user_backups'),
      'POST',
      json: {
        'user_id': s.userId,
        'data': AppStore.shared.fullBackup(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      prefer: 'resolution=merge-duplicates,return=minimal',
    );
  }

  Future<BackupFile?> _download() async {
    final rows = jsonDecode(
      await _send(_rest('user_backups', {'select': 'data'}), 'GET'),
    ) as List;
    if (rows.isEmpty) return null;
    final data = (rows.first as Map<String, dynamic>)['data'];
    try {
      return AppStore.parseMap(data as Map<String, dynamic>?);
    } on FormatException catch (e) {
      throw CloudFailure(e.message.contains('較新版') ? e.message : '雲端資料格式不對');
    } on TypeError {
      throw const CloudFailure('雲端資料格式不對');
    }
  }

  // MARK: 對戰

  /// 呼叫 supabase/battle.sql 裡的 battle_* 函式
  Future<Object?> rpc(
    String name, [
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    try {
      final body = await _send(
        _rest('rpc/$name'),
        'POST',
        json: args,
        timeout: timeout,
      );
      return body.isEmpty ? null : jsonDecode(body);
    } on _HttpFailure catch (e) {
      if (e.message.contains('Could not find the function'))
        throw const CloudFailure('對戰伺服器還沒開通');
      rethrow;
    }
  }

  /// 開發版：把私人空間 dev-builds 裡的安裝檔換成 10 分鐘有效的下載網址（只有內測名單的帳號可以）
  Future<String> signDevBuild(String path) async {
    final body = jsonDecode(
      await _send(
        Uri.parse('${CloudConfig.url}/storage/v1/object/sign/dev-builds/$path'),
        'POST',
        json: {'expiresIn': 600},
      ),
    ) as Map<String, dynamic>;
    return '${CloudConfig.url}/storage/v1${body['signedURL']}&download=JuanGo-dev.apk';
  }

  // MARK: 分享代碼

  static const _shareCodesKey = 'cloud.shareCodes';

  /// 上傳一個清單，回傳代碼；同一個清單再分享一次會更新同一個代碼，並重新計算 72 小時（由伺服器決定）
  Future<String> share(Map<String, dynamic> listFile, String key) async {
    final lists = listFile['lists'] as List;
    final raw = lists.isEmpty
        ? '清單'
        : (lists.first as Map)['name'] as String? ?? '清單';
    final name = raw.length > 60 ? raw.substring(0, 60) : raw;
    final body = {
      'name': name,
      'data': listFile,
      'word_count': (listFile['words'] as List).length,
    };
    final prefs = await SharedPreferences.getInstance();
    final codes = Map<String, String>.from(
      jsonDecode(prefs.getString(_shareCodesKey) ?? '{}') as Map,
    );
    final old = codes[key];
    if (old != null) {
      final rows = jsonDecode(
        await _send(
          _rest('shared_lists', {'code': 'eq.$old'}),
          'PATCH',
          json: body,
          prefer: 'return=representation',
        ),
      ) as List;
      if (rows.isNotEmpty) return old;
    }
    final rows = jsonDecode(
      await _send(
        _rest('shared_lists'),
        'POST',
        json: body,
        prefer: 'return=representation',
      ),
    ) as List;
    final code = rows.isEmpty ? null : (rows.first as Map)['code'] as String?;
    if (code == null) throw const CloudFailure('建立分享代碼失敗');
    codes[key] = code;
    await prefs.setString(_shareCodesKey, jsonEncode(codes));
    return code;
  }

  /// 不用登入也能用代碼拿清單
  Future<BackupFile> fetch(String code) async {
    final rows = jsonDecode(
      await _send(
        _rest('rpc/get_shared_list'),
        'POST',
        json: {'p_code': code},
        auth: signedIn,
      ),
    ) as List;
    if (rows.isEmpty)
      throw CloudFailure('找不到代碼「${pretty(code)}」的清單，可能打錯了，或已經超過 72 小時');
    try {
      return AppStore.parseMap(
        (rows.first as Map)['data'] as Map<String, dynamic>?,
      );
    } on FormatException catch (e) {
      throw CloudFailure(e.message);
    } on TypeError {
      throw const CloudFailure('清單的格式不對');
    }
  }

  Future<List<SharedList>> myLists() async {
    final rows = jsonDecode(
      await _send(
        _rest('shared_lists', {
          'select': 'code,name,word_count,expires_at',
          'order': 'updated_at.desc',
        }),
        'GET',
      ),
    ) as List;
    return rows
        .map((r) => SharedList.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteList(String code) async {
    await _send(_rest('shared_lists', {'code': 'eq.$code'}), 'DELETE');
    final prefs = await SharedPreferences.getInstance();
    final codes = Map<String, String>.from(
      jsonDecode(prefs.getString(_shareCodesKey) ?? '{}') as Map,
    )..removeWhere((_, v) => v == code);
    await prefs.setString(_shareCodesKey, jsonEncode(codes));
  }

  /// "K7Q3P9XM" → "K7Q3-P9XM"
  static String pretty(String code) {
    final c = code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    return c.length == 8 ? '${c.substring(0, 4)}-${c.substring(4)}' : c;
  }

  /// 回報單字問題：沒登入也能送。回傳 ok 或 duplicate（已經收過，或今天回報過同一件事）
  Future<String> reportWord(Map<String, dynamic> args) async {
    final body = await _send(
      _rest('rpc/report_word'),
      'POST',
      json: args,
      auth: signedIn,
    );
    final v = jsonDecode(body);
    return v is String ? v : 'ok';
  }

  // MARK: 連線

  Future<String> _send(
    Uri url,
    String method, {
    Map<String, dynamic>? json,
    String? prefer,
    bool auth = true,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final res = await sendBytes(
      url,
      method,
      body: json == null ? null : utf8.encode(jsonEncode(json)),
      prefer: prefer,
      auth: auth,
      timeout: timeout,
    );
    return utf8.decode(res, allowMalformed: true);
  }

  /// 任何要登入的請求，body 自己準備好：課文書架的資料表用 JSON 陣列，Storage 用 JPEG 位元組
  Future<List<int>> sendBytes(
    Uri url,
    String method, {
    List<int>? body,
    String contentType = 'application/json',
    String? prefer,
    Map<String, String> headers = const {},
    bool auth = true,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final bearer = auth ? await _accessToken() : CloudConfig.key;
    final req = http.Request(method, url)
      ..headers.addAll({
        'apikey': CloudConfig.key,
        'Authorization': 'Bearer $bearer',
        'Content-Type': contentType,
        if (prefer != null) 'Prefer': prefer,
        ...headers,
      });
    if (body != null) req.bodyBytes = body;
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _client.send(req).timeout(timeout),
      );
    } catch (_) {
      DevLog.add('cloud', '$method ${url.path} → 沒有回應');
      throw const CloudFailure('連不上伺服器，請檢查網路');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res.bodyBytes;
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (res.statusCode == 429) throw _HttpFailure(429, '太頻繁了，請稍後再試');
    String? message;
    try {
      final o = jsonDecode(text) as Map<String, dynamic>;
      message =
          (o['msg'] ?? o['message'] ?? o['error_description'] ?? o['error'])
              as String?;
    } catch (_) {}
    DevLog.add(
      'cloud',
      '$method ${url.path} → ${res.statusCode} ${message ?? ''}',
    );
    throw _HttpFailure(
      res.statusCode,
      '${message ?? '伺服器錯誤'}（${res.statusCode}）',
    );
  }
}

class _HttpFailure extends CloudFailure {
  const _HttpFailure(this.status, super.message);
  final int status;
}

/// 自己分享出去的清單
class SharedList {
  SharedList({
    required this.code,
    required this.name,
    required this.wordCount,
    this.expiresAt,
  });
  factory SharedList.fromJson(Map<String, dynamic> j) => SharedList(
    code: j['code'] as String,
    name: j['name'] as String? ?? '',
    wordCount: j['word_count'] as int? ?? 0,
    expiresAt: DateTime.tryParse(j['expires_at'] as String? ?? ''),
  );
  final String code, name;
  final int wordCount;
  final DateTime? expiresAt;

  /// 還剩幾小時失效（無條件進位，過期是 0）
  int get hoursLeft {
    final e = expiresAt;
    if (e == null) return 72;
    final m = e.difference(DateTime.now()).inMinutes;
    return m <= 0 ? 0 : (m + 59) ~/ 60;
  }
}
