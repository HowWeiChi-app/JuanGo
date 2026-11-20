// 單字對戰：五回合即時對戰。答案、時間和分數都由 supabase/battle.sql 決定，App 只顯示狀態和送出點選。
// 排版照 iOS 版 Battle.swift。

import 'dart:async';
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
import 'settings.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';

class BattleSide {
  BattleSide(Map<String, dynamic> j)
    : name = j['name'] as String,
      rating = j['rating'] as int,
      tier = j['tier'] as int,
      score = j['score'] as int? ?? 0;
  final String name;
  final int rating, tier, score;
}

class BattlePlayer extends BattleSide {
  BattlePlayer(super.j) : wins = j['wins'] as int, losses = j['losses'] as int, draws = j['draws'] as int;
  final int wins, losses, draws;
}

class BattleQuestion {
  BattleQuestion(Map<String, dynamic> j)
    : n = j['n'] as int,
      toZh = j['to_zh'] as bool,
      prompt = j['prompt'] as String,
      options = (j['options'] as List).cast<String>();
  final int n;
  final bool toZh;
  final String prompt;
  final List<String> options;
}

class BattleLast {
  BattleLast(Map<String, dynamic> j)
    : n = j['n'] as int,
      answer = j['answer'] as int,
      pick = j['pick'] as int?,
      points = j['points'] as int,
      opponentPoints = j['opponent_points'] as int;
  final int n, answer, points, opponentPoints;
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
      words = [for (final w in j['words'] as List) BattleWord(w as Map<String, dynamic>)];
  final String outcome, reason;
  final int delta;
  final List<BattleWord> words;
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
      result = j['result'] == null ? null : BattleOutcome(j['result'] as Map<String, dynamic>);
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

enum BattlePhase { home, searching, room, playing, finished }

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

  /// 改對戰名稱。成功回傳 null，失敗回傳要顯示的原因
  Future<String?> rename(String name) async {
    final old = me;
    if (_demo && old != null) {
      _set(() => me = BattlePlayer({'name': name, 'rating': old.rating, 'tier': old.tier, 'wins': old.wins, 'losses': old.losses, 'draws': old.draws}));
      return null;
    }
    try {
      final j = await _rpc('battle_set_name', {'p_name': name, 'p_level': level}) as Map<String, dynamic>;
      _set(() => me = BattlePlayer(j));
      return null;
    } catch (e) {
      return '$e'.replaceFirst(RegExp(r'（\d+）$'), '');
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
    if (q != null && q.n != current?.n) {
      previous = current;
      current = q;
    }
    state = s;
    if (s.status == 'playing') {
      phase = BattlePhase.playing;
    } else if (s.status == 'finished' && s.result != null && phase != BattlePhase.finished) {
      if (phase == BattlePhase.room) {
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
    };
    final now = _local;
    me = BattlePlayer({'name': '勇敢的水獺08', 'rating': 640, 'tier': 4, 'wins': 7, 'losses': 4, 'draws': 1});
    if (step == 'home') return;
    if (step == 'search') {
      phase = BattlePhase.searching;
      waited = 6;
      searchStarted = DateTime.now().subtract(const Duration(seconds: 6));
      return;
    }
    if (step == 'room') {
      phase = BattlePhase.room;
      code = 'K7Q3P9';
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
      'you': {'name': '勇敢的水獺08', 'rating': 640, 'tier': 4, 'score': result ? 405 : 188},
      'opponent': {'name': '柚子', 'rating': 668, 'tier': 4, 'score': result ? 332 : 170},
      'starts': reveal ? now + 60000 : now - 3200,
      'ends': reveal ? now + 70000 : now + 600000,
      'opponent_answered': true,
      if (!reveal) 'question': q,
      if (reveal) 'last': {'n': 3, 'answer': 0, 'pick': 0, 'points': 84, 'opponent_points': 0},
      if (result)
        'result': {
          'outcome': 'win',
          'reason': 'score',
          'delta': 18,
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
    unawaited(_m.load());
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
    final canJoin = _clean.length == 6;
    return NavPage(
      title: '單字對戰',
      close: true,
      slivers: Cloud.shared.signedIn || me != null
          ? [
              Sec(
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
                                      levelLabel('${me.tier}'),
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
                                Text('${me.wins} 勝　${me.losses} 敗　${me.draws} 和', style: ts(F.sub, c: p.sec)),
                              ],
                            ),
                    ),
                ],
              ),
              Sec(
                footer: '配對積分相近的對手。5 回合，每題 10 秒，答對越快分數越高，最後一題 1.5 倍。',
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: PrimaryButton(label: '開始配對', icon: Icons.bolt_rounded, onTap: () => unawaited(m.find())),
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
                              if (_clean.length == 6) unawaited(m.join(_clean));
                            },
                            style: ts(F.body, c: p.ink),
                            decoration: InputDecoration(
                              hintText: '輸入 6 碼房間代碼',
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
    // 伺服器每秒把範圍放寬 50，8 秒後誰都可以
    final range = r != null && sec < 8 ? '積分 ${(r - 100 - 50 * sec).clamp(0, 99999)}–${r + 100 + 50 * sec}' : '擴大到所有玩家';
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
        (96 + 150 * f) / 2,
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
  const _TimeBar({required this.palette, required this.ends, required this.now});
  final Palette palette;
  final double? ends;
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
    final left = ends == null ? 0.0 : ((ends - widget.now()) / 10000).clamp(0.0, 1.0);
    return Semantics(
      label: '剩餘 ${(left * 10).ceil()} 秒',
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
        _bar(p, null),
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
        _bar(p, ends),
        Expanded(child: _question(p, s, q, null)),
        Text(timeUp ? '時間到' : (_m.picks.containsKey(q.n) ? '等對手作答' : ' '), style: ts(F.sub, c: p.sec)),
      ];
    } else {
      final left = (((starts ?? now) - now) / 1000).ceil().clamp(1, 9);
      body = [
        const Spacer(),
        if (s.round == 1 && s.last == null) _Intro(you: s.you, opponent: s.opponent),
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
        const Spacer(),
      ];
    }

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
                    n == 5 ? '最後一題 ×1.5' : '第 $n / 5 題',
                    textAlign: TextAlign.center,
                    style: ts(F.headline, w: w6, c: n == 5 ? p.accent : p.ink),
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

  Widget _bar(Palette p, double? ends) => _TimeBar(palette: p, ends: ends, now: () => _m.serverNow);

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
          Expanded(child: o == null ? const SizedBox.shrink() : _side(p, o, true, s.opponentAnswered && s.last?.n != s.round)),
        ],
      ),
    );
  }

  Widget _side(Palette p, BattleSide x, bool end, bool done) => Column(
    crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
    children: [
      Text(
        x.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ts(F.cap, w: w6, c: p.ink),
      ),
      TweenAnimationBuilder<double>(
        tween: Tween(end: x.score.toDouble()),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (_, v, _) => Text('${v.round()}', style: ts(30, w: w7, c: p.ink, h: 1.2)),
      ),
      Text(
        done ? '已作答' : '${levelLabel('${x.tier}')}・${x.rating}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: ts(F.cap, c: done ? p.accent : p.sec),
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
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    q.prompt,
                    maxLines: 1,
                    style: ts(q.toZh ? 40 : 32, w: w7, c: p.ink),
                  ),
                ),
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

  void _saveMissed(List<BattleWord> missed) {
    for (final w in missed) {
      final e = Dict.lookup(w.term);
      if (e != null) AppStore.shared.add(e);
    }
    setState(() => _saved = true);
  }

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
    final rating = s.rated ? '積分 ${s.you.rating}（${r.delta >= 0 ? '+' : ''}${r.delta}）・${levelLabel('${s.you.tier}')}' : '這場不計分';
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
                      Text(s.opponent?.name ?? '', style: ts(F.cap, c: p.sec)),
                      const SizedBox(height: 6),
                      Text(
                        rating,
                        style: ts(F.sub, w: w6, c: p.ink),
                      ),
                    ],
                  ),
                ),
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
                  PillButton(label: _saved ? '已加入我的單字' : '把答錯的字加入我的單字', width: double.infinity, onTap: _saved ? null : () => _saveMissed(missed)),
                  const SizedBox(height: 10),
                ],
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
  const _Intro({required this.you, required this.opponent});
  final BattleSide you;
  final BattleSide? opponent;
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
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: mine ? p.accent : p.sec.withValues(alpha: .35), shape: BoxShape.circle),
            child: Text(x.name.isEmpty ? '?' : x.name.characters.first, style: ts(24, w: w7, c: mine ? p.onAccent : p.ink)),
          ),
          const SizedBox(height: 6),
          Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, w: w6, c: p.ink)),
          Text('${levelLabel('${x.tier}')}・${x.rating}', maxLines: 1, style: ts(F.cap, c: p.sec)),
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
