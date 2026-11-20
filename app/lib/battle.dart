// 單字對戰：十題即時對戰，有段位和賽季。答案、時間和分數都由 supabase/battle.sql 決定，App 只顯示狀態和送出點選。
// 排版照 iOS 版 Battle.swift。

import 'dart:async';
import 'dart:io' show Platform, Process;
import 'dart:math' as math;

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'account_page.dart';
import 'cloud.dart';
import 'dictionary.dart';
import 'exam.dart' show AnswerOption, AnswerState;
import 'models.dart';
import 'onboarding.dart';
import 'pro.dart' show devGosPro;
import 'settings.dart';
import 'store.dart';
import 'study_flow.dart';
import 'theme.dart';
import 'widgets.dart';

class BattleSide {
  BattleSide(Map<String, dynamic> j)
    : name = j['name'] as String,
      pid = j['pid'] as String?,
      rating = j['rating'] as int,
      tier = j['tier'] as int,
      tierName = j['tier_name'] as String?,
      score = j['score'] as int? ?? 0;
  final String name;
  final String? pid, tierName;
  final int rating, tier, score;

  /// 段位名稱（尊貴鉑金…傳奇卷神），舊資料沒有就顯示等級
  String get tierText => tierName ?? levelLabel('$tier');
}

class BattlePlayer extends BattleSide {
  BattlePlayer(super.j)
    : wins = j['wins'] as int,
      losses = j['losses'] as int,
      draws = j['draws'] as int,
      tierFrom = j['tier_from'] as int?,
      tierNext = j['tier_next'] as int?,
      nextName = j['next_name'] as String?,
      season = j['season'] as String?,
      seasonNotice = j['season_notice'] as String?,
      open = j['open'] as bool? ?? true,
      freeLeft = j['free_left'] as int?,
      hidden = j['hidden'] as bool? ?? false,
      raw = j;
  final int wins, losses, draws;
  final int? tierFrom, tierNext;
  final String? nextName, season, seasonNotice;
  final bool open, hidden;

  /// 免費版今天還能打幾場排名賽；Pro 是 null
  final int? freeLeft;
  final Map<String, dynamic> raw;
}

class BattleQuestion {
  BattleQuestion(Map<String, dynamic> j)
    : n = j['n'] as int,
      toZh = j['to_zh'] as bool,
      prompt = j['prompt'] as String,
      options = (j['options'] as List).cast<String>(),
      pos = j['pos'] as String? ?? '';
  final int n;
  final bool toZh;
  final String prompt;
  final List<String> options;

  /// 這個字的詞性（n.、v.、adj./adv.…），沒有時是空字串
  final String pos;
}

class BattleLast {
  BattleLast(Map<String, dynamic> j)
    : n = j['n'] as int,
      answer = j['answer'] as int,
      pick = j['pick'] as int?,
      points = j['points'] as int,
      opponentPoints = j['opponent_points'] as int,
      term = j['term'] as String? ?? '',
      zh = j['zh'] as String? ?? '';
  final int n, answer, points, opponentPoints;
  final String term, zh;
  final int? pick;
}

class BattleWord {
  BattleWord(Map<String, dynamic> j) : term = j['term'] as String, zh = j['zh'] as String, right = j['right'] as bool;
  final String term, zh;
  final bool right;
}

class BattleOutcome {
  BattleOutcome(Map<String, dynamic> j)
    : outcome = j['outcome'] as String,
      reason = j['reason'] as String,
      delta = j['delta'] as int,
      words = [for (final w in j['words'] as List) BattleWord(w as Map<String, dynamic>)],
      breakdown = [
        for (final b in (j['breakdown'] as List? ?? const []))
          ((b as Map<String, dynamic>)['label'] as String, b['value'] as int),
      ],
      tierFrom = j['tier_from'] as int?,
      tierNext = j['tier_next'] as int?,
      nextName = j['next_name'] as String?,
      rematch = j['rematch'] as String?,
      canRematch = j['can_rematch'] as bool? ?? false;
  final String outcome, reason;

  /// 朋友對戰才有：「再來一場」開了，mine 是在等朋友，theirs 是朋友在等
  final String? rematch;
  final bool canRematch;
  final int delta;
  final List<BattleWord> words;

  /// 這局加扣分的明細：基本 +20、對手較強 +2…
  final List<(String, int)> breakdown;
  final int? tierFrom, tierNext;
  final String? nextName;
}

class BattleState {
  BattleState(Map<String, dynamic> j)
    : id = j['id'] as String,
      status = j['status'] as String,
      rated = j['rated'] as bool,
      round = j['round'] as int,
      now = (j['now'] as num).toDouble(),
      you = BattleSide(j['you'] as Map<String, dynamic>),
      opponent = j['opponent'] == null ? null : BattleSide(j['opponent'] as Map<String, dynamic>),
      starts = (j['starts'] as num?)?.toDouble(),
      ends = (j['ends'] as num?)?.toDouble(),
      opponentAnswered = j['opponent_answered'] as bool? ?? false,
      question = j['question'] == null ? null : BattleQuestion(j['question'] as Map<String, dynamic>),
      last = j['last'] == null ? null : BattleLast(j['last'] as Map<String, dynamic>),
      result = j['result'] == null ? null : BattleOutcome(j['result'] as Map<String, dynamic>),
      rounds = j['rounds'] as int? ?? 10,
      roundMs = j['round_ms'] as int? ?? 10000,
      note = j['note'] as String?,
      boss = j['boss'] as String?;
  final int rounds, roundMs;

  /// 隱藏電腦的開場台詞；只有對手是它的時候才有
  final String? boss;

  /// 倒數畫面的說明，例如「你們今天已經對戰 3 場，這場不計分」
  final String? note;
  final String id, status;
  final bool rated, opponentAnswered;
  final int round;
  final double now;
  final double? starts, ends;
  final BattleSide you;
  final BattleSide? opponent;
  final BattleQuestion? question;
  final BattleLast? last;
  final BattleOutcome? result;
}

/// 自動對戰（tools/battle_autoplay_android.sh）：開發版讀 debug.juango.autoplay 這個系統屬性，
/// 有秒數就一打開 App 就進單字對戰配對，每題開始後那麼多秒選正確答案，打完 5 秒後再開下一場，
/// 每一步都印到 logcat（腳本會顯示在終端機）
class BattleAutoplay {
  static double? delay;

  /// debug.juango.battle 有值（例如 boss）就不連伺服器，直接打開那個展示畫面
  static String? demoStep;

  static Future<void> read() async {
    if (!devGosPro || !Platform.isAndroid) return;
    try {
      final r = await Process.run('getprop', ['debug.juango.autoplay']);
      delay = double.tryParse('${r.stdout}'.trim());
      final d = '${(await Process.run('getprop', ['debug.juango.battle'])).stdout}'.trim();
      demoStep = d.isEmpty ? null : d;
    } catch (_) {}
  }

  static void log(String line) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    // ignore: avoid_print
    print('[JuanGo 自動對戰 ${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $line');
  }

  /// 伺服器事後才說哪個是正解，所以用內建字典判斷
  static int? rightOption(BattleQuestion q) {
    List<String> meanings(String term) => Dict.lookup(term)?.zh ?? const [];
    bool matches(String zh, List<String> list) => list.any((m) => m == zh || m.contains(zh) || zh.contains(m));
    final i = q.toZh
        ? q.options.indexWhere((o) => matches(o, meanings(q.prompt)))
        : q.options.indexWhere((o) => matches(q.prompt, meanings(o)));
    return i < 0 ? null : i;
  }
}

enum BattlePhase { home, searching, room, rematch, playing, finished }

class BattleModel extends ChangeNotifier {
  /// 沒做完 18 題程度測驗時 level 是 null，伺服器就不讓這個人配對
  BattleModel({String? level, bool? tested, this.resultDelay = const Duration(seconds: 3), this.pollEvery = const Duration(milliseconds: 500)})
    : level = (tested ?? (level != null || AppSettings.shared.levelTested)) ? int.tryParse(level ?? AppSettings.shared.level) ?? 3 : null;

  final int? level;
  final Duration resultDelay, pollEvery;

  BattlePhase phase = BattlePhase.home;
  BattlePlayer? me;
  bool meFailed = false;
  BattleState? state;
  BattleQuestion? current, previous;
  final Map<int, int> picks = {};
  String? code, error;
  int waited = 0;

  /// 這次配對開始的時間：等待畫面的時鐘用手機自己算，每秒都會跳，不用等伺服器
  DateTime searchStarted = DateTime.now();

  double _clockOffset = 0, _bestTrip = double.infinity;
  int _run = 0; // 每次換畫面就加一，舊的輪詢看到不同的值就停
  bool _demo = false, _closed = false;

  Cloud get _cloud => Cloud.shared;

  /// 逾時設短一點：以前一個卡住的請求會讓整場停住，直到 30 秒後才放棄
  Future<Object?> _rpc(String name, [Map<String, dynamic> args = const {}]) =>
      _cloud.rpc(name, args, const Duration(seconds: 5));
  double get _local => DateTime.now().millisecondsSinceEpoch.toDouble();
  double get serverNow => _local + _clockOffset;

  void _set(VoidCallback f) {
    f();
    if (!_closed) notifyListeners();
  }

  void _reset(BattlePhase p) {
    _run++;
    phase = p;
    state = current = previous = null;
    picks.clear();
    code = error = null;
    waited = 0;
    searchStarted = DateTime.now();
    _bestTrip = double.infinity;
    if (!_closed) notifyListeners();
  }

  void _fail(int run, Object e) {
    if (run != _run) return;
    _reset(BattlePhase.home);
    _set(() => error = '$e');
  }

  Future<void> _wait(Duration d) => Future<void>.delayed(d);

  static String _clean(Object e) => '$e'.replaceFirst(RegExp(r'（\d+）$'), '');

  static const reportReasons = [('vulgar', '不雅'), ('offensive', '冒犯'), ('impersonation', '冒充他人'), ('other', '其他')];

  /// 檢舉暱稱。成功回傳 null，失敗回傳原因
  Future<String?> report(String pid, String reason) async {
    if (_demo) return null;
    try {
      await _cloud.rpc('battle_report', {'p_pid': pid, 'p_reason': reason}, const Duration(seconds: 10));
      return null;
    } catch (e) {
      return _clean(e);
    }
  }

  Future<String?> block(String pid) async {
    if (_demo) return null;
    try {
      await _cloud.rpc('battle_block', {'p_pid': pid}, const Duration(seconds: 10));
      return null;
    } catch (e) {
      return _clean(e);
    }
  }

  Future<Map<String, dynamic>> board() async {
    if (_demo) return demoBoard;
    return await _cloud.rpc('battle_board', const {}, const Duration(seconds: 10)) as Map<String, dynamic>;
  }

  /// 改對戰名稱。成功回傳 null，失敗回傳要顯示的原因
  Future<String?> rename(String name) async {
    final old = me;
    if (_demo && old != null) {
      _set(() => me = BattlePlayer({...old.raw, 'name': name}));
      return null;
    }
    try {
      final j = await _rpc('battle_set_name', {'p_name': name, 'p_level': level}) as Map<String, dynamic>;
      _set(() => me = BattlePlayer(j));
      return null;
    } catch (e) {
      return _clean(e);
    }
  }

  Future<void> load() async {
    if (_demo) return;
    if (!_cloud.signedIn) {
      _set(() => me = null);
      return;
    }
    try {
      final j = await _rpc('battle_me', {'p_level': level}) as Map<String, dynamic>;
      _set(() {
        me = BattlePlayer(j);
        meFailed = false;
      });
    } catch (e) {
      _set(() {
        meFailed = true;
        error = '$e';
      });
    }
  }

  Future<void> find() async {
    _reset(BattlePhase.searching);
    final run = _run;
    var failures = 0;
    while (run == _run) {
      try {
        final t = await _rpc('battle_find', {'p_level': level}) as Map<String, dynamic>;
        if (run != _run) return;
        failures = 0;
        final id = t['match'] as String?;
        if (id != null) return await _poll(id, run);
        _set(() => waited = t['waited'] as int? ?? waited);
      } catch (e) {
        if (++failures >= 4) return _fail(run, e);
      }
      await _wait(const Duration(seconds: 1));
    }
  }

  Future<void> createRoom() async {
    _reset(BattlePhase.searching);
    final run = _run;
    try {
      final t = await _rpc('battle_create_room', {'p_level': level}) as Map<String, dynamic>;
      if (run != _run) return;
      _set(() {
        code = t['code'] as String;
        phase = BattlePhase.room;
      });
      await _poll(t['match'] as String, run);
    } catch (e) {
      _fail(run, e);
    }
  }

  Future<void> join(String roomCode) async {
    _reset(BattlePhase.searching);
    final run = _run;
    try {
      final t = await _rpc('battle_join', {'p_code': roomCode, 'p_level': level}) as Map<String, dynamic>;
      if (run == _run) await _poll(t['match'] as String, run);
    } catch (e) {
      _fail(run, e);
    }
  }

  Future<void> _poll(String id, int run) async {
    var failures = 0;
    while (run == _run) {
      try {
        final sent = _local;
        final j = await _rpc('battle_state', {'p_match': id}) as Map<String, dynamic>;
        failures = 0;
        final s = BattleState(j);
        _apply(s, sent, run);
        if (s.status == 'finished') return;
      } catch (e) {
        if (++failures >= 16) return _fail(run, e);
      }
      await _wait(_nextPoll());
    }
  }

  /// 平常每 0.5 秒問一次；下一題快能拿到（開始前 1 秒）或時間快到時提早問，倒數才不會停在 1
  Duration _nextPoll() {
    final s = state;
    if (s == null || s.status != 'playing') return pollEvery;
    final now = serverNow;
    final marks = [if (s.starts != null) s.starts! - 900, if (s.ends != null) s.ends! + 60].where((m) => m > now);
    if (marks.isEmpty) return pollEvery;
    final ms = (marks.reduce((a, b) => a < b ? a : b) - now).clamp(80, pollEvery.inMilliseconds.toDouble());
    return Duration(milliseconds: ms.round());
  }

  void _apply(BattleState s, double sent, int run) {
    // 答案和輪詢同時在路上時，晚到的舊狀態不能蓋掉新的
    if (run != _run || s.now < (state?.now ?? 0)) return;
    final received = _local;
    if (received - sent < _bestTrip) {
      _bestTrip = received - sent;
      _clockOffset = s.now - (sent + received) / 2;
    }
    final q = s.question;
    final fresh = q != null && q.n != current?.n;
    if (fresh) {
      previous = current;
      current = q;
    }
    state = s;
    _autoReport(s);
    if (fresh) _autoplay(q, s.starts, run);
    if (s.status == 'playing') {
      phase = BattlePhase.playing;
    } else if (s.status == 'finished' && s.result != null && phase != BattlePhase.finished) {
      if (phase == BattlePhase.room || phase == BattlePhase.rematch) {
        _reset(BattlePhase.home);
        return;
      }
      // 最後一題的答案先留在畫面上一下，再進結果頁
      final played = s.last != null && s.result!.reason == 'score';
      unawaited(_showResult(played ? resultDelay : Duration.zero, run));
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _showResult(Duration delay, int run) async {
    await _wait(delay);
    if (run != _run) return;
    _set(() => phase = BattlePhase.finished);
    await load();
    _autoNext(run);
    final s = state;
    if (s != null && (s.result?.canRematch ?? false)) await _watchRematch(s.id, run);
  }

  /// 朋友對戰結束後繼續更新結果，結果頁才看得到「朋友想再來一場」
  Future<void> _watchRematch(String id, int run) async {
    while (run == _run && phase == BattlePhase.finished) {
      await _wait(const Duration(seconds: 2));
      if (run != _run || phase != BattlePhase.finished) return;
      try {
        final j = await _rpc('battle_state', {'p_match': id}) as Map<String, dynamic>;
        if (run == _run && phase == BattlePhase.finished) _set(() => state = BattleState(j));
      } catch (_) {}
    }
  }

  /// 再來一場：先按的人等朋友，後按的人一按就開始
  Future<void> rematch() async {
    final id = state?.id;
    if (id == null) return;
    _reset(BattlePhase.searching);
    final run = _run;
    try {
      final t = await _rpc('battle_rematch', {'p_match': id}) as Map<String, dynamic>;
      if (run != _run) return;
      if (t['waiting'] == true) _set(() => phase = BattlePhase.rematch);
      await _poll(t['match'] as String, run);
    } catch (e) {
      _fail(run, e);
    }
  }

  void answer(int i) {
    final s = state, q = current, starts = s?.starts;
    if (s == null || q == null || starts == null || q.n != s.round || picks.containsKey(q.n)) return;
    _set(() => picks[q.n] = i);
    final run = _run, sent = _local;
    final ms = (serverNow - starts).round().clamp(0, 10000);
    unawaited(
      _cloud
          .rpc('battle_answer', {'p_match': s.id, 'p_round': q.n, 'p_pick': i, 'p_ms': ms})
          .then((j) => _apply(BattleState(j as Map<String, dynamic>), sent, run))
          .catchError((Object e) => debugPrint('送出答案失敗：$e')),
    );
  }

  int _reported = 0, _games = 0, _wins = 0;

  /// 自動對戰：開始配對下一場
  void autoFind() {
    if (BattleAutoplay.delay == null) return;
    if (!_cloud.signedIn) return BattleAutoplay.log('沒有登入，不能對戰：先在 App 裡登入');
    _games++;
    BattleAutoplay.log('—— 第 $_games 場：開始配對 ——');
    _reported = 0;
    unawaited(find());
  }

  void _autoNext(int run) {
    if (BattleAutoplay.delay == null) return;
    unawaited(_wait(const Duration(seconds: 5)).then((_) {
      if (phase == BattlePhase.finished) autoFind();
    }));
  }

  void _autoplay(BattleQuestion q, double? starts, int run) {
    final delay = BattleAutoplay.delay;
    if (delay == null) return;
    final options = [for (var i = 0; i < q.options.length; i++) '${String.fromCharCode(65 + i)} ${q.options[i]}'].join('  ');
    final pick = BattleAutoplay.rightOption(q);
    if (pick == null) return BattleAutoplay.log('第 ${q.n} 題：${q.prompt}｜$options｜字典判斷不出答案，不作答');
    final wait = (starts ?? serverNow) + delay * 1000 - serverNow;
    unawaited(_wait(Duration(milliseconds: wait > 0 ? wait.round() : 0)).then((_) {
      if (run != _run) return;
      answer(pick);
      BattleAutoplay.log('第 ${q.n} 題：${q.prompt}｜$options｜選 ${String.fromCharCode(65 + pick)} ${q.options[pick]}');
    }));
  }

  void _autoReport(BattleState s) {
    if (BattleAutoplay.delay == null) return;
    final o = s.opponent;
    if (_reported == 0 && o != null) {
      _reported = -1;
      BattleAutoplay.log('配對到 ${o.name}（${o.tierText}・${o.rating}），${s.rated ? '排位' : '不計分'}');
    }
    final l = s.last;
    if (l != null && l.n > math.max(_reported, 0)) {
      _reported = l.n;
      final mine = l.points > 0 ? '答對 +${l.points}' : l.pick == null ? '沒作答' : '答錯（正解 ${l.term} ${l.zh}）';
      BattleAutoplay.log('　→ $mine｜對手 +${l.opponentPoints}｜比分 ${s.you.score} : ${s.opponent?.score ?? 0}');
    }
    final r = s.result;
    if (s.status == 'finished' && r != null && _reported != 1 << 30) {
      _reported = 1 << 30;
      if (r.outcome == 'win') _wins++;
      final word = const {'win': '贏了', 'loss': '輸了', 'draw': '平手'}[r.outcome] ?? r.outcome;
      final delta = r.delta > 0 ? '+${r.delta}' : '${r.delta}';
      BattleAutoplay.log('結果：$word（${r.reason}），積分 $delta → ${s.you.rating + r.delta}｜目前 $_wins 勝 / $_games 場，5 秒後下一場');
    }
  }

  /// 離開目前的畫面。對戰進行中離開算輸
  Future<void> leave() async {
    final id = state?.status == 'finished' ? null : state?.id;
    final searching = phase == BattlePhase.searching;
    _reset(BattlePhase.home);
    try {
      if (id != null) {
        await _rpc('battle_quit', {'p_match': id});
      } else if (searching) {
        await _rpc('battle_cancel_find');
      }
    } catch (e) {
      debugPrint('離開對戰失敗：$e');
    }
    await load();
  }

  @override
  void dispose() {
    _closed = true;
    _run++;
    super.dispose();
  }

  /// 不連伺服器，直接顯示某個畫面（測試截圖用）
  @visibleForTesting
  void demo(String step) {
    _demo = true;
    final result = step == 'result';
    final q = {
      'n': 3,
      'to_zh': true,
      'prompt': 'persuade',
      'options': ['說服', '猶豫', '承認', '避免'],
      'pos': 'v.',
    };
    final now = _local;
    me = BattlePlayer({
      'name': '勇敢的水獺08',
      'pid': 'demo-me',
      'rating': 1218,
      'tier': 3,
      'tier_name': '至尊星耀',
      'tier_from': 1200,
      'tier_next': 1400,
      'next_name': '無雙卷哥',
      'season': '2026 S6',
      'open': true,
      'free_left': 7,
      'wins': 7,
      'losses': 4,
      'draws': 1,
    });
    if (step == 'home') return;
    if (step == 'search') {
      phase = BattlePhase.searching;
      waited = 6;
      searchStarted = DateTime.now().subtract(const Duration(seconds: 6));
      return;
    }
    if (step == 'room') {
      phase = BattlePhase.room;
      code = 'K7Q3';
      return;
    }
    if (step == 'boss') {
      state = BattleState({
        'id': 'demo',
        'status': 'playing',
        'rated': true,
        'round': 1,
        'now': now,
        'boss': '我要把你當掉',
        'you': {'name': '勇敢的水獺08', 'pid': 'demo-me', 'rating': 1218, 'tier': 3, 'tier_name': '至尊星耀', 'score': 0},
        'opponent': {'name': '優質霸王', 'pid': 'demo-boss', 'rating': 9999, 'tier': 6, 'tier_name': '扛不住', 'score': 0},
        'starts': now + 8000,
        'ends': now + 16000,
      });
      phase = BattlePhase.playing;
      return;
    }
    final reveal = step == 'reveal';
    if (reveal) picks[3] = 0;
    current = BattleQuestion(q);
    state = BattleState({
      'id': 'demo',
      'status': result ? 'finished' : 'playing',
      'rated': true,
      'round': reveal ? 4 : 3,
      'now': now,
      'you': {'name': '勇敢的水獺08', 'pid': 'demo-me', 'rating': 1218, 'tier': 3, 'tier_name': '至尊星耀', 'score': result ? 705 : 188},
      'opponent': {'name': '柚子', 'pid': 'demo-opp', 'rating': 1236, 'tier': 3, 'tier_name': '至尊星耀', 'score': result ? 612 : 170},
      'rounds': 10,
      'round_ms': 10000,
      'starts': reveal ? now + 60000 : now - 3200,
      'ends': reveal ? now + 70000 : now + 600000,
      'opponent_answered': true,
      if (!reveal) 'question': q,
      if (reveal) 'last': {'n': 3, 'answer': 0, 'pick': 0, 'points': 84, 'opponent_points': 0},
      if (result)
        'result': {
          'outcome': 'win',
          'reason': 'score',
          'delta': 27,
          'breakdown': [
            {'label': '基本', 'value': 20},
            {'label': '對手較強', 'value': 2},
            {'label': '表現', 'value': 3},
            {'label': '3 連勝', 'value': 2},
          ],
          'tier_from': 1200,
          'tier_next': 1400,
          'next_name': '無雙卷哥',
          'words': [
            {'term': 'persuade', 'zh': '說服', 'right': true},
            {'term': 'reluctant', 'zh': '不情願的', 'right': false},
            {'term': 'abandon', 'zh': '放棄', 'right': true},
            {'term': 'vivid', 'zh': '生動的', 'right': true},
            {'term': 'scarce', 'zh': '稀少的', 'right': false},
          ],
        },
    });
    phase = result ? BattlePhase.finished : BattlePhase.playing;
  }

  static final demoBoard = <String, dynamic>{
    'season': '2026 S6',
    'previous': '2026 S5',
    'has_previous': true,
    'min_games': 60,
    'live_min_games': 10,
    'current': {
      'top': [
        {'rank': 1, 'name': '單字狂人', 'pid': 'd1', 'rating': 1684, 'tier_name': '璀璨卷王', 'win_rate': 0.71},
        {'rank': 2, 'name': '柚子', 'pid': 'd2', 'rating': 1522, 'tier_name': '無雙卷哥', 'win_rate': 0.66},
        {'rank': 3, 'name': '匿名玩家', 'pid': null, 'rating': 1407, 'tier_name': '無雙卷哥', 'win_rate': 0.63},
        {'rank': 4, 'name': '勇敢的水獺08', 'pid': 'demo-me', 'rating': 1218, 'tier_name': '至尊星耀', 'win_rate': 0.58, 'me': true},
      ],
      'me': {'rank': 4, 'rating': 1218, 'tier_name': '至尊星耀', 'win_rate': 0.58, 'games': 12},
    },
    'last': {
      'top': [
        {'rank': 1, 'name': '單字狂人', 'pid': 'd1', 'rating': 2214, 'tier_name': '傳奇卷神', 'win_rate': 0.71},
        {'rank': 2, 'name': '柚子', 'pid': 'd2', 'rating': 1987, 'tier_name': '傳奇卷神', 'win_rate': 0.66},
      ],
      'me': null,
    },
  };
}

// MARK: 畫面

class BattlePage extends StatefulWidget {
  const BattlePage({super.key, this.model});
  final BattleModel? model;
  @override
  State<BattlePage> createState() => _BattlePageState();
}

class _BattlePageState extends State<BattlePage> {
  /// 第一次對戰前每個人都要做完 18 題程度測驗，積分才會從自己的程度開始
  late bool _placing = widget.model == null && !AppSettings.shared.levelTested;
  BattleModel? _model;
  BattleModel get _m => _model!;

  @override
  void initState() {
    super.initState();
    Cloud.shared.addListener(_signedInChanged);
    if (!_placing) _start();
  }

  void _start() {
    _model = widget.model ?? BattleModel();
    unawaited(_m.load().then((_) {
      if (mounted && BattleAutoplay.delay != null && _m.phase == BattlePhase.home) _m.autoFind();
    }));
  }

  void _signedInChanged() {
    if (_model?.phase == BattlePhase.home) unawaited(_m.load());
  }

  @override
  void dispose() {
    Cloud.shared.removeListener(_signedInChanged);
    _model?.dispose();
    super.dispose();
  }

  Widget _placement() {
    final p = Palette.of(context);
    return ColoredBox(
      color: p.bg,
      child: Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 16, 20, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('對戰前先測程度', style: ts(F.title2, w: w7)),
                const SizedBox(height: 4),
                Text('做完 18 題，積分會從你的程度開始。', style: ts(F.sub, c: p.sec)),
              ]),
            ),
            CircleBtn(icon: Icons.close_rounded, label: '關閉', onTap: () => Navigator.of(context).maybePop()),
          ]),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: OnboardingView(
              testOnly: true,
              onTested: (_) => setState(() {
                _placing = false;
                _start();
              }),
            ),
          ),
        ),
      ]),
    );
  }

  void _askLeave() => showAlert(
    context,
    '離開這場對戰？',
    message: '對戰進行中離開會算輸。',
    actions: [
      const AlertAction('取消'),
      AlertAction('離開並判負', destructive: true, onTap: () => unawaited(_m.leave())),
    ],
  );

  @override
  Widget build(BuildContext context) => _placing ? _placement() : ListenableBuilder(
    listenable: _m,
    builder: (context, _) {
      final err = _m.error;
      if (err != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _m.error == null) return;
          _m.error = null;
          showAlert(context, '無法對戰', message: err);
        });
      }
      final playing = _m.phase == BattlePhase.playing;
      return PopScope(
        canPop: !playing,
        onPopInvokedWithResult: (popped, _) {
          if (!popped && playing) _askLeave();
        },
        child: switch (_m.phase) {
          BattlePhase.home => _Home(model: _m),
          BattlePhase.searching => _Searching(model: _m),
          BattlePhase.room => _Room(model: _m),
          BattlePhase.rematch => _RematchWait(model: _m),
          BattlePhase.playing => _Game(model: _m, onLeave: _askLeave),
          BattlePhase.finished => _Result(model: _m),
        },
      );
    },
  );
}

class _Home extends StatefulWidget {
  const _Home({required this.model});
  final BattleModel model;
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String get _clean => _code.text.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final m = widget.model;
    final me = m.me;
    final canJoin = _clean.length == 4;
    return NavPage(
      title: '單字對戰',
      close: true,
      slivers: Cloud.shared.signedIn || me != null
          ? [
              if (me?.seasonNotice != null)
                Sec(children: [
                  RowTile(leading: Icon(Icons.nightlight_round, size: 21, color: p.accent), title: me!.seasonNotice),
                ]),
              Sec(
                header: me?.season,
                children: [
                  if (me == null && m.meFailed)
                    RowTile(title: '讀不到積分，再試一次', titleColor: p.accent, onTap: () => unawaited(m.load()))
                  else
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: me == null
                          ? const SizedBox(height: 96, child: Center(child: CircularProgressIndicator()))
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
                                    Semantics(
                                      button: true,
                                      label: '修改對戰名稱',
                                      child: Tap(
                                        onTap: () => pushPage(context, _RenamePage(model: m)),
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Icon(Icons.edit_rounded, size: 18, color: p.accent),
                                        ),
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
                                const SizedBox(height: 8),
                                _TierProgress(rating: me.rating, from: me.tierFrom, next: me.tierNext, nextName: me.nextName),
                                const SizedBox(height: 6),
                                Text('${me.wins} 勝　${me.losses} 敗　${me.draws} 和', style: ts(F.sub, c: p.sec)),
                              ],
                            ),
                    ),
                  RowTile(
                    leading: Icon(Icons.format_list_numbered_rounded, size: 21, color: p.accent),
                    title: '賽季排行',
                    chevron: true,
                    onTap: () => pushPage(context, BattleBoardPage(model: m)),
                  ),
                ],
              ),
              Sec(
                footer: [
                  '配對積分相近的對手，一共 10 題，每題 10 秒。答對 25 分，越快最多再加 75 分。',
                  if (me?.freeLeft case final left?)
                    left > 0 ? '免費版今天還能打 $left 場排名賽。' : '今天的 10 場免費排名賽打完了，升級 Pro 就不限場次。',
                ].join('\n'),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: PrimaryButton(
                      label: '開始配對',
                      icon: Icons.bolt_rounded,
                      onTap: me?.open == false || me?.freeLeft == 0 ? null : () => unawaited(m.find()),
                    ),
                  ),
                ],
              ),
              Sec(
                header: '和朋友對戰',
                children: [
                  RowTile(
                    leading: Icon(Icons.group_rounded, size: 22, color: p.accent),
                    title: '建立房間',
                    chevron: true,
                    onTap: () => unawaited(m.createRoom()),
                  ),
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
                            textInputAction: TextInputAction.join,
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) {
                              if (_clean.length == 4) unawaited(m.join(_clean));
                            },
                            style: ts(F.body, c: p.ink),
                            decoration: InputDecoration(
                              hintText: '輸入 4 碼房間代碼',
                              hintStyle: ts(F.body, c: p.sec),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        Tap(
                          onTap: canJoin ? () => unawaited(m.join(_clean)) : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                            child: Text(
                              '加入',
                              style: ts(F.body, w: w6, c: p.accent),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ]
          : [
              Sec(
                footer: '對手只會看到你的對戰名稱和積分，不會看到 Email。',
                children: [RowTile(title: '登入後就能對戰', chevron: true, onTap: () => pushPage(context, const AccountPage()))],
              ),
            ],
    );
  }
}

class _RenamePage extends StatefulWidget {
  const _RenamePage({required this.model});
  final BattleModel model;
  @override
  State<_RenamePage> createState() => _RenamePageState();
}

class _RenamePageState extends State<_RenamePage> {
  late final _name = TextEditingController(text: widget.model.me?.name ?? '');
  bool _saving = false;
  String? _problem;

  String get _clean => _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
  bool get _valid => _clean.runes.length >= 2 && _clean.runes.length <= 12;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    setState(() => _saving = true);
    final problem = await widget.model.rename(_clean);
    if (!mounted) return;
    if (problem == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return NavPage(
      title: '對戰名稱',
      actions: [BarText(_saving ? '儲存中…' : '儲存', onTap: _valid && !_saving ? () => unawaited(_save()) : null)],
      slivers: [
        Sec(
          footer: _problem ?? '2 到 12 個字，對手會看到這個名稱。',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _name,
                autofocus: true,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => unawaited(_save()),
                style: ts(F.body, c: p.ink),
                decoration: InputDecoration(
                  hintText: '對戰名稱',
                  hintStyle: ts(F.body, c: p.sec),
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 雷達波紋、等待時間和目前配對的積分範圍。時鐘用手機算，網路慢也會每秒跳
class _Searching extends StatefulWidget {
  const _Searching({required this.model});
  final BattleModel model;
  @override
  State<_Searching> createState() => _SearchingState();
}

class _SearchingState extends State<_Searching> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}))..start();

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final m = widget.model;
    final still = MediaQuery.disableAnimationsOf(context);
    final t = DateTime.now().difference(m.searchStarted).inMilliseconds / 1000;
    final sec = t.floor().clamp(0, 5999);
    final r = m.me?.rating;
    // 伺服器從 ±10 開始，每秒放寬 10（10 秒），再用 ±200 擴大範圍找 6 秒，之後再過 4～7 秒配電腦
    final w = 10 + 10 * sec;
    final range = sec >= 16
        ? '正在尋找實力相當的對手'
        : sec >= 10
        ? '正在擴大範圍搜尋'
        : (r != null ? '積分 ${(r - w).clamp(0, 99999)}–${r + w}' : '尋找積分相近的對手');
    final name = m.me?.name ?? '';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            ExcludeSemantics(
              child: SizedBox(
                width: 250,
                height: 250,
                child: CustomPaint(
                  painter: _Radar(t: still ? null : t, color: p.accent),
                  child: Center(
                    child: Transform.scale(
                      scale: still ? 1 : 1 + .04 * math.sin(t * 4),
                      child: Container(
                        width: 76,
                        height: 76,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                        child: Text(name.isEmpty ? '我' : name.characters.first, style: ts(30, w: w7, c: p.onAccent)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text('正在尋找對手', style: ts(F.title2, w: w7, c: p.ink)),
            const SizedBox(height: 6),
            Text('${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}', style: ts(F.title3, w: w6, c: p.accent)),
            const SizedBox(height: 18),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Container(
                key: ValueKey(range),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(99)),
                child: Text(range, style: ts(F.sub, w: w6, c: p.sec)),
              ),
            ),
            const Spacer(),
            PillButton(label: '取消', width: double.infinity, onTap: () => unawaited(m.leave())),
          ],
        ),
      ),
    );
  }
}

/// 三圈往外擴散的波紋加一道掃描光；t 是 null 時（減少動態效果）只畫靜止的圈
class _Radar extends CustomPainter {
  _Radar({required this.t, required this.color});
  final double? t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final f = t == null ? .35 + i * .25 : (t! / 2.4 + i / 3) % 1;
      canvas.drawCircle(
        c,
        (120 + 126 * f) / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: .5 * (1 - f)),
      );
    }
    canvas.drawCircle(c, 60, Paint()..color = color.withValues(alpha: .12));
    if (t != null) {
      final a = t! * 150 * math.pi / 180;
      final rect = Rect.fromCircle(center: c, radius: 60);
      canvas.drawArc(
        rect,
        a - .18 * 2 * math.pi,
        .18 * 2 * math.pi,
        true,
        Paint()
          ..shader = SweepGradient(
            startAngle: a - .18 * 2 * math.pi,
            endAngle: a,
            colors: [color.withValues(alpha: 0), color.withValues(alpha: .55)],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_Radar old) => old.t != t || old.color != color;
}

class _RematchWait extends StatelessWidget {
  const _RematchWait({required this.model});
  final BattleModel model;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            const CircularProgressIndicator(),
            const SizedBox(height: 18),
            Text('等朋友按「再來一場」', style: ts(F.title3, w: w6, c: p.ink)),
            const SizedBox(height: 10),
            Text('朋友按下後立刻開始。朋友對戰不影響積分。', textAlign: TextAlign.center, style: ts(F.sub, c: p.sec)),
            const Spacer(),
            PillButton(label: '取消', width: double.infinity, onTap: () => unawaited(model.leave())),
          ],
        ),
      ),
    );
  }
}

class _Room extends StatelessWidget {
  const _Room({required this.model});
  final BattleModel model;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final code = model.code ?? '';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            Text('房間代碼', style: ts(F.sub, c: p.sec)),
            const SizedBox(height: 10),
            SelectableText(
              code,
              style: ts(44, w: w7, c: p.ink, mono: true).copyWith(letterSpacing: 4),
            ),
            const SizedBox(height: 10),
            Text(
              '請朋友到「單字對戰」輸入代碼，加入後立刻開始。朋友對戰不影響積分。',
              textAlign: TextAlign.center,
              style: ts(F.sub, c: p.sec),
            ),
            const SizedBox(height: 18),
            PrimaryButton(
              label: '傳給朋友',
              icon: Icons.ios_share_rounded,
              width: double.infinity,
              onTap: () => SharePlus.instance.share(ShareParams(text: '來捲字 JuanGo 和我對戰，房間代碼：$code')),
            ),
            const Spacer(),
            PillButton(label: '關閉房間', width: double.infinity, onTap: () => unawaited(model.leave())),
          ],
        ),
      ),
    );
  }
}

class _Game extends StatefulWidget {
  const _Game({required this.model, required this.onLeave});
  final BattleModel model;
  final VoidCallback onLeave;
  @override
  State<_Game> createState() => _GameState();
}

/// 倒數條跟著螢幕每一格重畫（高刷螢幕就是 90／120 Hz），整頁仍是每 0.1 秒更新
class _TimeBar extends StatefulWidget {
  const _TimeBar({required this.palette, required this.ends, required this.now, this.length = 10000});
  final Palette palette;
  final double? ends;
  final double length;
  final double Function() now;
  @override
  State<_TimeBar> createState() => _TimeBarState();
}

class _TimeBarState extends State<_TimeBar> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    if (widget.ends != null) _ticker.start();
  }

  @override
  void didUpdateWidget(_TimeBar old) {
    super.didUpdateWidget(old);
    if (widget.ends == null && _ticker.isActive) _ticker.stop();
    if (widget.ends != null && !_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette, ends = widget.ends;
    final left = ends == null ? 0.0 : ((ends - widget.now()) / widget.length).clamp(0.0, 1.0);
    return Semantics(
      label: '剩餘 ${(left * widget.length / 1000).ceil()} 秒',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: left,
          minHeight: 8,
          backgroundColor: p.accent.withValues(alpha: .14),
          color: left < .3 ? p.hsnuMagenta : p.accent,
        ),
      ),
    );
  }
}

class _GameState extends State<_Game> {
  late final Timer _tick;

  /// 已經播完隱藏電腦開場的那場對戰
  String? _bossDone;

  /// 開場色塊已經蓋滿畫面的那場對戰；蓋滿之前底下維持配對等待畫面
  String? _bossCovered;

  /// 隱藏電腦開場結束時，頭像、名字、段位各自落到頁面上的位置
  final _spots = {for (final k in _Spot.values) k: GlobalKey()};

  bool _bossPlaying(BattleState s) =>
      s.boss != null && s.opponent != null && s.round == 1 && s.last == null && _bossDone != s.id;

  Rect? _spotRect(_Spot k) {
    final box = _spots[k]!.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  BattleModel get _m => widget.model;

  /// 這回合結束後，答案留到下一題開始（最後一題則留到結果頁）
  BattleQuestion? _revealed(BattleState s, double now) {
    final l = s.last;
    if (l == null || !(s.status == 'finished' || now < (s.starts ?? 0))) return null;
    for (final q in [_m.current, _m.previous]) {
      if (q?.n == l.n) return q;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = _m.state;
    if (s == null) return const SizedBox.shrink();
    final now = _m.serverNow;
    final shown = _revealed(s, now);
    final q = _m.current;
    final starts = s.starts, ends = s.ends;
    final live = shown == null && q != null && q.n == s.round && starts != null && ends != null && now >= starts;
    final n = shown?.n ?? s.round;

    final List<Widget> body;
    if (shown != null) {
      final l = s.last!;
      body = [
        _bar(p, null, s),
        Expanded(child: _question(p, s, shown, l)),
        _PopIn(
          key: ValueKey('points${l.n}'),
          child: Text(
            l.points > 0 ? '+${l.points}' : (l.pick == null ? '時間到' : '答錯了'),
            style: ts(F.title2, w: w7, c: l.points > 0 ? p.hsnuSky : p.hsnuMagenta),
          ),
        ),
        Text('對手 +${l.opponentPoints}', style: ts(F.sub, c: p.sec)),
      ];
    } else if (live) {
      final timeUp = now >= ends;
      body = [
        _bar(p, ends, s),
        Expanded(child: _question(p, s, q, null)),
        Text(timeUp ? '時間到' : (_m.picks.containsKey(q.n) ? '等對手作答' : ' '), style: ts(F.sub, c: p.sec)),
      ];
    } else {
      final left = (((starts ?? now) - now) / 1000).ceil().clamp(1, 9);
      body = [
        const Spacer(),
        if (s.round == 1 && s.last == null)
          _Intro(you: s.you, opponent: s.opponent, avatarKey: _spots[_Spot.avatar], hideAvatar: _bossPlaying(s)),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutBack,
          transitionBuilder: (child, a) => MediaQuery.disableAnimationsOf(context)
              ? FadeTransition(opacity: a, child: child)
              : FadeTransition(
                  opacity: a,
                  child: ScaleTransition(scale: Tween(begin: 1.8, end: 1.0).animate(a), child: child),
                ),
          child: Text('$left', key: ValueKey(left), style: ts(72, w: w7, c: p.ink)),
        ),
        Text(
          s.round == 1 ? '準備開始' : '下一題',
          style: ts(F.headline, w: w6, c: p.sec),
        ),
        if (s.round == 1 && s.last == null && s.note != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s.note!, textAlign: TextAlign.center, style: ts(F.sub, w: w6, c: p.accent)),
          ),
        const Spacer(),
      ];
    }

    return Stack(children: [
      if (_bossPlaying(s) && _bossCovered != s.id) _Searching(model: _m) else _page(p, s, n, body),
      if (_bossPlaying(s))
        Positioned.fill(
          child: _BossTakeover(
            key: ValueKey(s.id),
            boss: s.opponent!,
            line: s.boss!,
            late: (s.starts ?? 0) - now < 5000,
            target: _spotRect,
            onCovered: () => setState(() => _bossCovered = s.id),
            onDone: () => setState(() => _bossDone = s.id),
          ),
        ),
    ]);
  }

  Widget _page(Palette p, BattleState s, int n, List<Widget> body) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Column(
          children: [
            Row(
              children: [
                CircleBtn(icon: Icons.close_rounded, size: 44, label: '離開對戰', onTap: widget.onLeave),
                Expanded(
                  child: Text(
                    '第 $n / ${s.rounds} 題',
                    textAlign: TextAlign.center,
                    style: ts(F.headline, w: w6, c: p.ink),
                  ),
                ),
                const SizedBox(width: 44),
              ],
            ),
            const SizedBox(height: 12),
            _scoreboard(p, s),
            const SizedBox(height: 14),
            ...body,
          ],
        ),
      ),
    );
  }

  Widget _bar(Palette p, double? ends, BattleState s) =>
      _TimeBar(palette: p, ends: ends, now: () => _m.serverNow, length: s.roundMs.toDouble());

  Widget _scoreboard(Palette p, BattleState s) {
    final o = s.opponent;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _side(p, s.you, false, false)),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
            child: Text(
              'VS',
              style: ts(F.cap, w: w7, c: p.ter),
            ),
          ),
          Expanded(
            child: o == null
                ? const SizedBox.shrink()
                : _side(p, o, true, s.opponentAnswered && s.last?.n != s.round, landing: _bossPlaying(s)),
          ),
        ],
      ),
    );
  }

  /// landing：隱藏電腦的名字和段位還在飛過來，先藏著（對手那邊也標出位置給開場動畫）
  Widget _side(Palette p, BattleSide x, bool end, bool done, {bool landing = false}) => Column(
    crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
    children: [
      Opacity(
        key: end ? _spots[_Spot.name] : null,
        opacity: landing ? 0 : 1,
        child: Text(
          x.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ts(F.cap, w: w6, c: p.ink),
        ),
      ),
      TweenAnimationBuilder<double>(
        tween: Tween(end: x.score.toDouble()),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (_, v, _) => Text('${v.round()}', style: ts(30, w: w7, c: p.ink, h: 1.2)),
      ),
      Opacity(
        key: end ? _spots[_Spot.tier] : null,
        opacity: landing ? 0 : 1,
        child: Text(
          done ? '已作答' : '${x.tierText}・${x.rating}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: ts(F.cap, c: done ? p.accent : p.sec),
        ),
      ),
    ],
  );

  Widget _question(Palette p, BattleState s, BattleQuestion q, BattleLast? last) {
    final mine = last != null ? last.pick : _m.picks[q.n];
    final canTap = last == null && mine == null && q.n == s.round;
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StaggerIn(
                key: ValueKey('prompt${q.n}'),
                index: 0,
                child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      q.prompt,
                      maxLines: 1,
                      style: ts(q.toZh ? 40 : 32, w: w7, c: p.ink),
                    ),
                  ),
                  if (q.pos.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(q.pos, semanticsLabel: '詞性 ${q.pos}', style: ts(F.sub, w: w6, c: p.sec)),
                  ],
                ]),
              ),
              ),
              for (final (i, o) in q.options.indexed)
                _StaggerIn(
                  key: ValueKey('option${q.n}-$i'),
                  index: i + 1,
                  child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AnswerOption(
                    letter: String.fromCharCode(65 + i),
                    text: o,
                    state: last != null
                        ? (i == last.answer ? AnswerState.right : (i == mine ? AnswerState.wrong : AnswerState.used))
                        : (mine == null || i == mine ? AnswerState.idle : AnswerState.used),
                    onTap: canTap ? () => _m.answer(i) : null,
                  ),
                ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Result extends StatefulWidget {
  const _Result({required this.model});
  final BattleModel model;
  @override
  State<_Result> createState() => _ResultState();
}

class _ResultState extends State<_Result> {
  bool _saved = false;

  List<Word> _saveMissed(List<BattleWord> missed) {
    final words = [
      for (final w in missed)
        if (Dict.lookup(w.term) case final e?)
          if (AppStore.shared.add(e) case final x?) x,
    ];
    setState(() => _saved = true);
    return words;
  }

  static String _signed(int v) => v > 0 ? '+$v' : (v < 0 ? '−${-v}' : '0');

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = widget.model.state;
    final r = s?.result;
    if (s == null || r == null) return const SizedBox.shrink();
    final missed = r.words.where((w) => !w.right).toList();
    final title = r.reason == 'abandoned'
        ? '對戰中斷'
        : switch (r.outcome) {
            'win' => '獲勝',
            'loss' => '落敗',
            _ => '平手',
          };
    final rating = s.rated ? '積分 ${s.you.rating}（${_signed(r.delta)}）・${s.you.tierText}' : (s.note ?? '這場不計分');
    final o = s.opponent;
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                  decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
                  child: Column(
                    children: [
                      _PopIn(
                        child: Column(children: [
                          if (r.outcome == 'win' && r.reason != 'abandoned') Icon(Icons.emoji_events_rounded, size: 44, color: p.accent),
                          Text(title, style: ts(36, w: w7, c: p.ink)),
                        ]),
                      ),
                      if (r.reason == 'left') Text(r.outcome == 'win' ? '對手離開了' : '你離開了這場對戰', style: ts(F.sub, c: p.sec)),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${s.you.score}',
                              style: ts(40, w: w7, c: p.accent),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Text(':', style: ts(F.title2, c: p.ter)),
                            ),
                            Text(
                              '${s.opponent?.score ?? 0}',
                              style: ts(40, w: w7, c: p.ink),
                            ),
                          ],
                        ),
                      ),
                      if (o != null)
                        _PlayerMenu(
                          model: widget.model,
                          pid: o.pid,
                          name: o.name,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(o.name, style: ts(F.cap, c: p.sec)),
                              if (o.pid != null) ...[
                                const SizedBox(width: 4),
                                Icon(Icons.more_horiz_rounded, size: 16, color: p.sec),
                              ],
                            ]),
                          ),
                        ),
                      const SizedBox(height: 6),
                      Text(
                        rating,
                        style: ts(F.sub, w: w6, c: p.ink),
                      ),
                    ],
                  ),
                ),
                if (s.rated && r.breakdown.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: Text('這局的積分', style: ts(F.sub, c: p.sec)),
                  ),
                  Container(
                    decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
                    child: Column(
                      children: [
                        for (final (label, v) in r.breakdown) RowTile(title: label, value: _signed(v)),
                        RowTile(
                          titleWidget: Text('合計', style: ts(F.body, w: w7, c: p.ink)),
                          trailing: Text(_signed(r.delta), style: ts(F.body, w: w7, c: p.ink)),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                          child: _TierProgress(rating: s.you.rating, from: r.tierFrom, next: r.tierNext, nextName: r.nextName),
                        ),
                      ],
                    ),
                  ),
                ],
                if (r.words.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: Text('這場的單字', style: ts(F.sub, c: p.sec)),
                  ),
                  Container(
                    decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
                    child: Column(
                      children: [
                        for (final w in r.words)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            child: Row(
                              children: [
                                Icon(
                                  w.right ? Icons.check_circle_rounded : Icons.cancel_rounded,
                                  size: 20,
                                  color: w.right ? p.hsnuSky : p.hsnuMagenta,
                                  semanticLabel: w.right ? '答對' : '答錯',
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    w.term,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ts(F.headline, w: w6, c: p.ink),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    w.zh,
                                    textAlign: TextAlign.end,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ts(F.sub, c: p.sec),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Column(
              children: [
                if (missed.isNotEmpty) ...[
                  Row(children: [
                    Expanded(
                      child: PillButton(
                        label: '只練答錯的字',
                        width: double.infinity,
                        onTap: () {
                          // 先加進我的單字，練習的進度才會留下來
                          final words = _saveMissed(missed);
                          if (words.isNotEmpty) unawaited(startStudy(context, '答錯的字', words));
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: PillButton(
                        label: _saved ? '已加入單字' : '加入我的單字',
                        width: double.infinity,
                        onTap: _saved ? null : () => _saveMissed(missed),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 10),
                ],
                if (r.canRematch) ...[
                  if (r.rematch == 'theirs') ...[
                    Text('朋友想再來一場', style: ts(F.sub, w: w6, c: p.accent)),
                    const SizedBox(height: 8),
                  ],
                  Row(children: [
                    Expanded(child: PillButton(label: '完成', width: double.infinity, onTap: () => unawaited(widget.model.leave()))),
                    const SizedBox(width: 10),
                    Expanded(child: PrimaryButton(label: '再來一場', width: double.infinity, onTap: () => unawaited(widget.model.rematch()))),
                  ]),
                ] else
                  PrimaryButton(label: '完成', width: double.infinity, onTap: () => unawaited(widget.model.leave())),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// MARK: 動畫

/// 第一題前，兩邊玩家從左右滑進來，中間是 VS
class _Intro extends StatefulWidget {
  const _Intro({required this.you, required this.opponent, this.avatarKey, this.hideAvatar = false});
  final BattleSide you;
  final BattleSide? opponent;

  /// 對手頭像的位置（隱藏電腦開場的頭像落在這裡）；還在飛過來時先藏著
  final GlobalKey? avatarKey;
  final bool hideAvatar;
  @override
  State<_Intro> createState() => _IntroState();
}

class _IntroState extends State<_Intro> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..forward();

  @override
  void initState() {
    super.initState();
    if (AppSettings.shared.haptics) unawaited(HapticFeedback.heavyImpact());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final a = CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
    Widget card(BattleSide x, bool mine) => Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
        child: Column(children: [
          Opacity(
            key: mine ? null : widget.avatarKey,
            opacity: !mine && widget.hideAvatar ? 0 : 1,
            child: Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: mine ? p.accent : p.sec.withValues(alpha: .35), shape: BoxShape.circle),
              child: Text(x.name.isEmpty ? '?' : x.name.characters.first, style: ts(24, w: w7, c: mine ? p.onAccent : p.ink)),
            ),
          ),
          const SizedBox(height: 6),
          Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, w: w6, c: p.ink)),
          Text('${x.tierText}・${x.rating}', maxLines: 1, style: ts(F.cap, c: p.sec)),
        ]),
      ),
    );
    final o = widget.opponent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: AnimatedBuilder(
        animation: a,
        builder: (_, _) {
          final v = still ? 1.0 : a.value;
          return Row(children: [
            Expanded(child: Transform.translate(offset: Offset(-260 * (1 - v), 0), child: Row(children: [card(widget.you, true)]))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Opacity(
                opacity: still ? 1 : _c.value,
                child: Transform.scale(scale: .2 + .8 * v, child: Text('VS', style: ts(28, w: FontWeight.w900, c: p.accent))),
              ),
            ),
            if (o != null) Expanded(child: Transform.translate(offset: Offset(260 * (1 - v), 0), child: Row(children: [card(o, false)]))),
          ]);
        },
      ),
    );
  }
}

/// 隱藏電腦開場交棒給頁面的三個位置：倒數畫面對手卡片的頭像，上方記分卡的名字和段位
enum _Spot { avatar, name, tier }

/// 隱藏電腦的開場，用 App 自己的顏色：主色的色塊帶著波浪邊緣從下往上流過整個畫面（前面有一層淡的），
/// 對手卡片一塊一塊升上來，台詞用膠囊跳出來。接著色塊繼續往上流走，頭像、名字、段位同時滑到
/// 頁面上各自的位置（target），開場就接在倒數畫面上結束
class _BossTakeover extends StatefulWidget {
  const _BossTakeover({
    super.key,
    required this.boss,
    required this.line,
    required this.late,
    required this.target,
    required this.onCovered,
    required this.onDone,
  });
  final BattleSide boss;
  final String line;

  /// 進來時離開始不到五秒（例如重新連上），就不播
  final bool late;
  final Rect? Function(_Spot) target;

  /// 色塊蓋滿整個畫面了
  final VoidCallback onCovered;
  final VoidCallback onDone;
  @override
  State<_BossTakeover> createState() => _BossTakeoverState();
}

class _BossTakeoverState extends State<_BossTakeover> with SingleTickerProviderStateMixin {
  static const _flowIn = .7, _partsAt = .5, _chipAt = 1.25, _outAt = 2.9, _flowOut = .8, _glide = .85;
  static const _total = _outAt + _glide;
  late final AnimationController _c = AnimationController(vsync: this, duration: Duration(milliseconds: (_total * 1000).round()));
  final _rests = {for (final k in _Spot.values) k: GlobalKey()};

  /// 三塊在卡片裡的位置（全螢幕座標）
  final _restRects = <_Spot, Rect>{};

  /// 滑行開始那一刻定下的起點和終點（全螢幕座標）
  Map<_Spot, (Rect, Rect)>? _paths;
  bool _buzzed = false, _covered = false;

  double get _t => _c.value * _total;

  /// 只在開場剛出現時判斷一次（播的過程中剩下的時間一直在變少）
  late final bool _late = widget.late;

  @override
  void initState() {
    super.initState();
    if (_late) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onCovered();
        widget.onDone();
      });
      return;
    }
    _c.addListener(() {
      if (!_covered && _t >= _flowIn) {
        _covered = true;
        widget.onCovered();
      }
      if (!_buzzed && _t >= _chipAt) {
        _buzzed = true;
        if (AppSettings.shared.haptics) unawaited(HapticFeedback.mediumImpact());
      }
      if (_paths == null && _t >= _outAt) _measure();
    });
    _c.forward().whenComplete(() {
      if (mounted) widget.onDone();
    });
  }

  void _recordRests() {
    if (!mounted) return;
    for (final k in _Spot.values) {
      final box = _rests[k]!.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize && box.attached) _restRects[k] = box.localToGlobal(Offset.zero) & box.size;
    }
  }

  void _measure() {
    final paths = <_Spot, (Rect, Rect)>{};
    for (final k in _Spot.values) {
      final from = _restRects[k], to = widget.target(k);
      if (from != null && to != null && from.height > 0) paths[k] = (from, to);
    }
    _paths = paths;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  static double _clamp(double x) => x.clamp(0.0, 1.0);
  static double _smooth(double x) {
    final v = _clamp(x);
    return v < .5 ? 4 * v * v * v : 1 - math.pow(-2 * v + 2, 3) / 2;
  }

  static double _lerp(double a, double b, double p) => a + (b - a) * p;

  /// 卡片第 i 塊升到定位的進度：一塊接一塊，間隔 0.09 秒
  double _part(double t, int i) => _smooth((t - _partsAt - .09 * i) / .5);

  Widget _rise(double p, Widget child) => Opacity(opacity: p, child: Transform.translate(offset: Offset(0, 26 * (1 - p)), child: child));

  // 會滑行的三塊。p 從 0（在卡片裡）到 1（落到頁面上），顏色一路從色塊上的換成頁面上的
  Widget _avatar(Palette p, double k) => Container(
    width: 112,
    height: 112,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: Color.lerp(p.onAccent, p.sec.withValues(alpha: .35), k), shape: BoxShape.circle),
    child: Text(
      widget.boss.name.isEmpty ? '?' : widget.boss.name.characters.first,
      style: ts(50, w: w7, c: Color.lerp(p.accent, p.ink, k)),
    ),
  );

  Widget _name(Palette p, double k) => Text(widget.boss.name, style: ts(44, w: w7, c: Color.lerp(p.onAccent, p.ink, k)));

  Widget _tier(Palette p, double k) => Text(
    '${widget.boss.tierText}・${widget.boss.rating}',
    style: ts(F.headline, w: w6, c: Color.lerp(p.onAccent.withValues(alpha: .8), p.sec, k)),
  );

  @override
  Widget build(BuildContext context) {
    if (_late) return const SizedBox.shrink();
    final p = Palette.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, box) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _t, h = box.maxHeight;
          final pin = _smooth(t / _flowIn), pout = _smooth((t - _outAt) / _flowOut), glide = _smooth((t - _outAt) / _glide);
          final gliding = t >= _outAt;
          final wave = still ? 0.0 : math.sin(math.pi * pin) + math.sin(math.pi * pout);
          // 進場時色塊的上緣往上掃，出場時換下緣往上掃
          final front = _FlowSheet(top: _lerp(h + 60, -80, pin), bottom: _lerp(h + 60, -80, pout), wave: 34 * wave, phase: t * 5);
          final back = _FlowSheet(
            top: _lerp(h + 60, -80, _smooth((t + .12) / _flowIn)),
            bottom: _lerp(h + 60, -80, _smooth((t - _outAt - .14) / _flowOut)),
            wave: 46 * wave,
            phase: t * 4 + 1.7,
          );
          final ring = _clamp((t - _partsAt - .15) / .9);
          final chip = _clamp((t - _chipAt) / .45);
          final pop = 1 - math.exp(-6 * chip) * math.cos(9 * chip);
          Widget rest(_Spot k, Widget child) => Opacity(key: _rests[k], opacity: gliding ? 0 : 1, child: child);
          // 卡片還在原位時，每一格記下三塊的位置，滑行就從最後記到的地方出發
          if (!gliding) WidgetsBinding.instance.addPostFrameCallback((_) => _recordRests());
          final card = Column(mainAxisSize: MainAxisSize.min, children: [
            _rise(_part(t, 0) * (1 - pout), Text('隱 藏 對 手', style: ts(F.foot, w: w6, c: p.onAccent.withValues(alpha: .75)))),
            const SizedBox(height: 32),
            _rise(
              _part(t, 1),
              Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
                Transform.scale(
                  scale: 1 + .8 * ring,
                  child: Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: p.onAccent.withValues(alpha: .5 * (1 - ring)), width: 2),
                    ),
                  ),
                ),
                rest(_Spot.avatar, _avatar(p, 0)),
              ]),
            ),
            const SizedBox(height: 26),
            _rise(_part(t, 2), rest(_Spot.name, _name(p, 0))),
            const SizedBox(height: 10),
            _rise(_part(t, 3), rest(_Spot.tier, _tier(p, 0))),
            const SizedBox(height: 52),
            Opacity(
              opacity: _clamp((t - _chipAt) / .15) * (1 - pout),
              child: Transform.scale(
                scale: still ? 1 : .6 + .4 * pop,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                  decoration: BoxDecoration(color: p.onAccent, borderRadius: BorderRadius.circular(999)),
                  child: Text('「${widget.line}」', style: ts(F.title3, w: w7, c: p.accent)),
                ),
              ),
            ),
          ]);
          final me = context.findRenderObject() as RenderBox?;
          final origin = me != null && me.hasSize ? me.localToGlobal(Offset.zero) : Offset.zero;
          Widget fly(_Spot k, Widget child) {
            final path = _paths?[k];
            if (path == null) return const SizedBox.shrink();
            final (from, to) = path;
            final scale = _lerp(1, to.height / from.height, glide);
            final c = Offset.lerp(from.center, to.center, glide)! - origin;
            return Positioned(
              left: c.dx - from.width / 2,
              top: c.dy - from.height / 2,
              width: from.width,
              height: from.height,
              child: Transform.scale(scale: scale, child: OverflowBox(maxWidth: double.infinity, child: child)),
            );
          }

          return Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(child: CustomPaint(painter: _FlowPainter(back, p.accent.withValues(alpha: .4)))),
            Positioned.fill(child: CustomPaint(painter: _FlowPainter(front, p.accent))),
            Positioned.fill(child: ClipPath(clipper: _FlowClipper(front), child: Center(child: card))),
            if (gliding) ...[
              fly(_Spot.avatar, _avatar(p, glide)),
              fly(_Spot.name, _name(p, glide)),
              fly(_Spot.tier, _tier(p, glide)),
            ],
          ]);
        },
      ),
    );
  }
}

/// 整個寬度上，夾在兩條波浪邊緣中間的帶狀色塊
class _FlowSheet {
  const _FlowSheet({required this.top, required this.bottom, required this.wave, required this.phase});
  final double top, bottom, wave, phase;

  Path path(Size size) {
    double y(double base, double x, double shift) {
      final u = x / math.max(1, size.width) * 2 * math.pi;
      return base + wave * (math.sin(u * 1.2 + phase + shift) * .65 + math.sin(u * 2.6 - phase * 1.3 + shift) * .35);
    }

    final xs = [for (var x = 0.0; x < size.width; x += 6) x, size.width];
    final p = Path()..moveTo(0, y(top, 0, 0));
    for (final x in xs) {
      p.lineTo(x, y(top, x, 0));
    }
    for (final x in xs.reversed) {
      p.lineTo(x, math.max(y(top, x, 0), y(bottom, x, 2.1)));
    }
    return p..close();
  }
}

class _FlowPainter extends CustomPainter {
  _FlowPainter(this.sheet, this.color);
  final _FlowSheet sheet;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(sheet.path(size), Paint()..color = color);
  @override
  bool shouldRepaint(_FlowPainter old) => true;
}

class _FlowClipper extends CustomClipper<Path> {
  _FlowClipper(this.sheet);
  final _FlowSheet sheet;
  @override
  Path getClip(Size size) => sheet.path(size);
  @override
  bool shouldReclip(_FlowClipper old) => true;
}

/// 新題目出現時，題目和選項一個接一個往上滑進來
class _StaggerIn extends StatefulWidget {
  const _StaggerIn({super.key, required this.index, required this.child});
  final int index;
  final Widget child;
  @override
  State<_StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<_StaggerIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration(milliseconds: 50 * widget.index), () {
      if (mounted) unawaited(_c.forward());
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final a = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return AnimatedBuilder(
      animation: a,
      builder: (_, child) => Opacity(
        opacity: a.value,
        child: Transform.translate(offset: Offset(0, still ? 0 : 18 * (1 - a.value)), child: child),
      ),
      child: widget.child,
    );
  }
}

/// 彈一下出現
class _PopIn extends StatefulWidget {
  const _PopIn({super.key, required this.child});
  final Widget child;
  @override
  State<_PopIn> createState() => _PopInState();
}

class _PopInState extends State<_PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 450))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final a = CurvedAnimation(parent: _c, curve: Curves.elasticOut);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: _c.value.clamp(0, 1),
        child: Transform.scale(scale: still ? 1 : .4 + .6 * a.value, child: child),
      ),
      child: widget.child,
    );
  }
}

// MARK: 段位、檢舉和賽季排行

/// 目前在這個段位走到哪裡，離下一段還差幾分
class _TierProgress extends StatelessWidget {
  const _TierProgress({required this.rating, this.from, this.next, this.nextName});
  final int rating;
  final int? from, next;
  final String? nextName;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final f = from, n = next;
    if (f == null) return const SizedBox.shrink();
    if (n == null || n <= f) return Text('已經是最高段位', style: ts(F.cap, c: p.sec));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: ((rating - f) / (n - f)).clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: p.accent.withValues(alpha: .14),
          color: p.accent,
        ),
      ),
      const SizedBox(height: 6),
      Text('離${nextName ?? '下一段'}還差 ${math.max(0, n - rating)} 分', style: ts(F.cap, c: p.sec)),
    ]);
  }
}

/// 長按暱稱：檢舉暱稱（四種原因，送出後再問要不要封鎖）或封鎖這位玩家
class _PlayerMenu extends StatelessWidget {
  const _PlayerMenu({required this.model, required this.pid, required this.name, required this.child});
  final BattleModel model;
  final String? pid;
  final String name;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final id = pid;
    if (id == null || id == model.me?.pid) return child;
    return Tap(onLongPress: () => _menu(context, id), onTap: () => _menu(context, id), dim: false, child: child);
  }

  void _menu(BuildContext context, String id) => showAlert(
    context,
    name,
    actions: [
      AlertAction('檢舉暱稱', onTap: () => _report(context, id)),
      AlertAction('封鎖這位玩家', destructive: true, onTap: () => unawaited(_block(context, id))),
      const AlertAction('取消'),
    ],
  );

  void _report(BuildContext context, String id) => showAlert(
    context,
    '檢舉「$name」這個暱稱',
    message: '選一個原因',
    actions: [
      for (final (code, label) in BattleModel.reportReasons)
        AlertAction(label, onTap: () async {
          final e = await model.report(id, code);
          if (!context.mounted) return;
          if (e != null) {
            unawaited(showAlert(context, e));
            return;
          }
          unawaited(showAlert(
            context,
            '謝謝，我們會處理',
            message: '要不要一併封鎖這位玩家？',
            actions: [
              const AlertAction('不用'),
              AlertAction('一併封鎖', destructive: true, onTap: () => unawaited(_block(context, id))),
            ],
          ));
        }),
      const AlertAction('取消'),
    ],
  );

  Future<void> _block(BuildContext context, String id) async {
    final e = await model.block(id);
    if (!context.mounted) return;
    unawaited(showAlert(context, e ?? '已封鎖', message: e == null ? '之後不會再配到對方，排行榜上也會顯示成匿名玩家。' : null));
  }
}

/// 上賽季前 20 名和本賽季的預估排名
class BattleBoardPage extends StatefulWidget {
  const BattleBoardPage({super.key, required this.model});
  final BattleModel model;
  @override
  State<BattleBoardPage> createState() => _BattleBoardPageState();
}

class _BattleBoardPageState extends State<BattleBoardPage> {
  Map<String, dynamic>? _b;
  String? _failed;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final b = await widget.model.board();
      if (mounted) {
        setState(() {
          _b = b;
          _failed = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _failed = BattleModel._clean(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final b = _b;
    if (b == null) {
      return NavPage(title: '賽季排行', slivers: [
        Sec(children: [
          if (_failed != null)
            RowTile(title: '讀不到排行，再試一次', subtitle: _failed, titleColor: p.accent, onTap: () => unawaited(_load()))
          else
            const SizedBox(height: 96, child: Center(child: CircularProgressIndicator())),
        ]),
      ]);
    }
    final minGames = b['min_games'] as int? ?? 60;
    final liveMin = b['live_min_games'] as int? ?? 10;
    return NavPage(title: '賽季排行', slivers: [
      Sec(
        header: '${b['season']} 即時排名',
        footer: '本賽季打滿 $liveMin 場排名賽就會上榜，名次隨時更新。勝率含電腦局。長按暱稱可以檢舉或封鎖。',
        children: _rows(p, b['current'] as Map<String, dynamic>?, liveMin, '還沒有人打滿 $liveMin 場排名賽'),
      ),
      Sec(
        header: '${b['previous']} 最終排名',
        footer: '上賽季打滿 $minGames 場排名賽才會列入。',
        children: b['has_previous'] != true
            ? [RowTile(title: '第一季，還沒有排名', titleColor: p.sec)]
            : _rows(p, b['last'] as Map<String, dynamic>?, minGames, '上賽季沒有人打滿 $minGames 場'),
      ),
    ]);
  }

  List<Widget> _rows(Palette p, Map<String, dynamic>? season, int min, String empty) {
    final top = [for (final r in (season?['top'] as List? ?? const [])) r as Map<String, dynamic>];
    final me = season?['me'] as Map<String, dynamic>?;
    return [
      if (top.isEmpty) RowTile(title: empty, titleColor: p.sec),
      for (final r in top) _row(p, r, min: min),
      if (me != null && !top.any((r) => r['me'] == true)) _row(p, me, mine: true, min: min),
    ];
  }

  Widget _row(Palette p, Map<String, dynamic> r, {bool mine = false, required int min}) {
    final rank = r['rank'] as int?;
    final pid = mine ? null : r['pid'] as String?;
    final name = mine ? (widget.model.me?.name ?? '你') : (r['name'] as String? ?? '匿名玩家');
    final self = mine || r['me'] == true;
    final rate = ((r['win_rate'] as num) * 100).round();
    return _PlayerMenu(
      model: widget.model,
      pid: pid,
      name: name,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          SizedBox(
            width: 30,
            child: Text(rank?.toString() ?? '–', style: ts(F.headline, w: w7, c: rank != null && rank <= 3 ? p.accent : p.ink)),
          ),
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: self ? p.accent : p.sec.withValues(alpha: .3), shape: BoxShape.circle),
            child: Text(
              pid == null && !self ? '?' : (name.isEmpty ? '?' : name.characters.first),
              style: ts(F.sub, w: w7, c: self ? p.onAccent : p.ink),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, w: w6, c: p.ink)),
              Text(mine && rank == null ? '場數不足（${r['games'] ?? 0} / $min 場）' : '${r['tier_name']}・勝率 $rate%', style: ts(F.cap, c: p.sec)),
            ]),
          ),
          Text('${r['rating']}', style: ts(F.headline, w: w7, c: p.ink)),
        ]),
      ),
    );
  }
}

/// 設定 › 單字對戰：不顯示在排行榜、已封鎖的玩家
class BattleSettingsPage extends StatefulWidget {
  const BattleSettingsPage({super.key});
  @override
  State<BattleSettingsPage> createState() => _BattleSettingsPageState();
}

class _BattleSettingsPageState extends State<BattleSettingsPage> {
  bool _hidden = false, _loaded = false;
  List<Map<String, dynamic>>? _blocked;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final level = BattleModel().level;
    try {
      final me = await Cloud.shared.rpc('battle_me', {'p_level': level}, const Duration(seconds: 10)) as Map<String, dynamic>;
      final b = await Cloud.shared.rpc('battle_blocked', const {}, const Duration(seconds: 10)) as List;
      if (!mounted) return;
      setState(() {
        _hidden = me['hidden'] as bool? ?? false;
        _loaded = true;
        _blocked = [for (final x in b) x as Map<String, dynamic>];
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = BattleModel._clean(e);
          _blocked ??= [];
        });
      }
    }
  }

  Future<void> _setHidden(bool v) async {
    setState(() => _hidden = v);
    try {
      await Cloud.shared.rpc('battle_set_hidden', {'p_hidden': v}, const Duration(seconds: 10));
    } catch (e) {
      if (mounted) {
        setState(() {
          _hidden = !v;
          _error = BattleModel._clean(e);
        });
      }
    }
  }

  Future<void> _unblock(Map<String, dynamic> b) async {
    setState(() => _blocked?.remove(b));
    try {
      await Cloud.shared.rpc('battle_unblock', {'p_id': b['id']}, const Duration(seconds: 10));
    } catch (e) {
      if (mounted) setState(() => _error = BattleModel._clean(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final blocked = _blocked;
    return NavPage(title: '單字對戰', slivers: [
      Sec(
        footer: '開啟後，其他人在排行榜上看到的是「匿名玩家」，名次照算。',
        children: [SwitchRow(title: '不顯示在排行榜', value: _hidden, onChanged: _loaded ? (v) => unawaited(_setHidden(v)) : (_) {})],
      ),
      Sec(
        header: '已封鎖的玩家',
        footer: '封鎖後不會再配到對方，排行榜上對方會顯示成匿名玩家。最多封鎖 200 人。${_error != null ? '\n$_error' : ''}',
        children: [
          if (blocked == null)
            const SizedBox(height: 64, child: Center(child: CircularProgressIndicator()))
          else if (blocked.isEmpty)
            RowTile(title: '沒有封鎖任何玩家', titleColor: p.sec)
          else
            for (final b in blocked)
              RowTile(
                title: b['name'] as String? ?? '玩家',
                trailing: Tap(
                  onTap: () => unawaited(_unblock(b)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                    child: Text('解除封鎖', style: ts(F.sub, w: w6, c: p.accent)),
                  ),
                ),
              ),
        ],
      ),
    ]);
  }
}
