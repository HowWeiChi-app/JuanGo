// 單字對戰：五回合即時對戰。答案、時間和分數都由 supabase/battle.sql 決定，App 只顯示狀態和送出點選。
// 排版照 iOS 版 Battle.swift。

import 'dart:async';

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'account_page.dart';
import 'cloud.dart';
import 'dictionary.dart';
import 'exam.dart' show AnswerOption, AnswerState;
import 'models.dart';
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
  BattleModel({String? level, this.resultDelay = const Duration(seconds: 3), this.pollEvery = const Duration(milliseconds: 500)})
    : level = int.tryParse(level ?? AppSettings.shared.level) ?? 3;

  final int level;
  final Duration resultDelay, pollEvery;

  BattlePhase phase = BattlePhase.home;
  BattlePlayer? me;
  bool meFailed = false;
  BattleState? state;
  BattleQuestion? current, previous;
  final Map<int, int> picks = {};
  String? code, error;
  int waited = 0;

  double _clockOffset = 0, _bestTrip = double.infinity;
  int _run = 0; // 每次換畫面就加一，舊的輪詢看到不同的值就停
  bool _demo = false, _closed = false;

  Cloud get _cloud => Cloud.shared;
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
      final j = await _cloud.rpc('battle_set_name', {'p_name': name, 'p_level': level}) as Map<String, dynamic>;
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
      final j = await _cloud.rpc('battle_me', {'p_level': level}) as Map<String, dynamic>;
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
        final t = await _cloud.rpc('battle_find', {'p_level': level}) as Map<String, dynamic>;
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
      final t = await _cloud.rpc('battle_create_room', {'p_level': level}) as Map<String, dynamic>;
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
      final t = await _cloud.rpc('battle_join', {'p_code': roomCode, 'p_level': level}) as Map<String, dynamic>;
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
        final j = await _cloud.rpc('battle_state', {'p_match': id}) as Map<String, dynamic>;
        failures = 0;
        final s = BattleState(j);
        _apply(s, sent, run);
        if (s.status == 'finished') return;
      } catch (e) {
        if (++failures >= 16) return _fail(run, e);
      }
      await _wait(pollEvery);
    }
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
        await _cloud.rpc('battle_quit', {'p_match': id});
      } else if (searching) {
        await _cloud.rpc('battle_cancel_find');
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
      'opponent': {'name': '電腦石虎', 'rating': 668, 'tier': 4, 'score': result ? 332 : 170},
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
  late final BattleModel _m = widget.model ?? BattleModel();

  @override
  void initState() {
    super.initState();
    Cloud.shared.addListener(_signedInChanged);
    unawaited(_m.load());
  }

  void _signedInChanged() {
    if (_m.phase == BattlePhase.home) unawaited(_m.load());
  }

  @override
  void dispose() {
    Cloud.shared.removeListener(_signedInChanged);
    _m.dispose();
    super.dispose();
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
  Widget build(BuildContext context) => ListenableBuilder(
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
                footer: '優先配對積分相近的真人，等 15 秒沒有真人就和電腦對戰。5 回合，每題 10 秒，答對越快分數越高，最後一題 1.5 倍。',
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

class _Searching extends StatelessWidget {
  const _Searching({required this.model});
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
            const SizedBox(height: 20),
            Text(
              '正在尋找對手',
              style: ts(F.title3, w: w6, c: p.ink),
            ),
            const SizedBox(height: 8),
            Text('已等待 ${model.waited} 秒，15 秒內沒有真人會改配電腦', style: ts(F.sub, c: p.sec)),
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
        Text(
          l.points > 0 ? '+${l.points}' : (l.pick == null ? '時間到' : '答錯了'),
          style: ts(F.title2, w: w7, c: l.points > 0 ? p.hsnuSky : p.hsnuMagenta),
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
        Text(
          '$left',
          style: ts(72, w: w7, c: p.ink),
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
      Text(
        '${x.score}',
        style: ts(30, w: w7, c: p.ink, h: 1.2),
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
              Padding(
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
              for (final (i, o) in q.options.indexed)
                Padding(
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
                      Text(
                        title,
                        style: ts(36, w: w7, c: p.ink),
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
