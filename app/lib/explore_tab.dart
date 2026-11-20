// 探索：一次一張字卡，左右滑換字，點兩下收藏。排版照 iOS 版 ExploreTab。

import 'package:material_ui/material_ui.dart';

import 'demo.dart';
import 'dictionary.dart';
import 'exam.dart';
import 'models.dart';
import 'services.dart';
import 'settings.dart';
import 'sheets.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';

class ExploreTab extends StatefulWidget {
  const ExploreTab({super.key});
  @override
  State<ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends State<ExploreTab> {
  AppStore get _store => AppStore.shared;
  AppSettings get _settings => AppSettings.shared;

  Deck _deck = Deck.recommended;
  final _levels = <String>{};
  String? _pos;
  List<DictEntry> _feed = const [];
  int _index = 0, _tipStep = 0;
  PageController? _pages;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 左右各露出一點旁邊的卡片：邊距 28、卡片間隔 12
    final w = MediaQuery.sizeOf(context).width;
    _pages ??= PageController(viewportFraction: (w - 44) / w);
  }

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  void _rebuild() {
    var pool = Dict.entriesOfDeck(_deck);
    if (_levels.isNotEmpty) pool = pool.where((e) => _levels.contains(e.lv)).toList();
    if (_pos != null) pool = pool.where((e) => e.posTags.contains(_pos)).toList();
    List<DictEntry> mixed(Iterable<DictEntry> e) => e.toList()..shuffle();
    if (_deck == Deck.recommended && _levels.isEmpty) {
      final found = examLevels.indexOf(_settings.level);
      final i = found < 0 ? 2 : found;
      final near = examLevels.sublist((i - 1).clamp(0, 5), (i + 2).clamp(0, 6)).toSet();
      final saved = _store.words.map((w) => w.term).toSet();
      _feed = [
        ...mixed(pool.where((e) => near.contains(e.lv) && !saved.contains(e.w))),
        ...mixed(pool.where((e) => !near.contains(e.lv))),
      ];
    } else {
      // 還沒收藏的排前面：探索就是為了找新字
      bool mine(DictEntry e) => _store.word(e.w)?.inMyWords ?? false;
      _feed = [...mixed(pool.where((e) => !mine(e))), ...mixed(pool.where(mine))];
    }
    if (demoOn) {
      final i = _feed.indexWhere((e) => e.w == demoFirstWord);
      if (i > 0) _feed.insert(0, _feed.removeAt(i));
    }
    _index = 0;
    if (_pages?.hasClients ?? false) _pages!.jumpToPage(0);
    if (_feed.isNotEmpty) _speak(_feed.first);
  }

  void _speak(DictEntry e) {
    if (_settings.autoSpeak) Speech.say(e.w);
  }

  void _update(VoidCallback change) {
    setState(() {
      change();
      _rebuild();
    });
  }

  void _toggle(DictEntry e) {
    final w = _store.word(e.w);
    if (w != null && w.inMyWords) {
      _store.removeFromMyWords(w);
    } else {
      if (_store.add(e) == null) return;
      Feedback2.success();
      if (_tipStep == 1) _settings.update((s) => s.exploreTipsDone = true);
    }
  }

  List<MenuEntry> _deckEntries() => [
        for (final d in Deck.values)
          MenuEntry(
            d.label,
            subtitle: '${Dict.entriesOfDeck(d).length} 個單字・${d.subtitle}',
            checked: d == _deck,
            onTap: () => _update(() => _deck = d),
          ),
      ];

  void _openFilter(BuildContext c) {
    const pos = [('n.', '名詞'), ('v.', '動詞'), ('adj.', '形容詞'), ('adv.', '副詞')];
    showAppMenu(c, [
      MenuEntry('等級', icon: Icons.chevron_right_rounded, onTap: () {
        showAppMenu(c, [
          for (final lv in examLevels)
            MenuEntry(levelLabel(lv), checked: _levels.contains(lv), onTap: () {
              _update(() => _levels.contains(lv) ? _levels.remove(lv) : _levels.add(lv));
            }),
        ]);
      }),
      MenuEntry('詞性', icon: Icons.chevron_right_rounded, onTap: () {
        showAppMenu(c, [
          for (final (v, name) in pos)
            MenuEntry(name, checked: _pos == v, onTap: () => _update(() => _pos = _pos == v ? null : v)),
        ]);
      }),
      if (_levels.isNotEmpty || _pos != null)
        MenuEntry('清除篩選', onTap: () {
          _update(() {
            _levels.clear();
            _pos = null;
          });
        }),
    ]);
  }

  Widget _tipBanner(Palette p) => Container(
        margin: const EdgeInsets.fromLTRB(18, 6, 18, 6),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(Radii.lg)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_tipStep == 0 ? '往左滑，看下一張' : '點兩下卡片，收進我的單字', style: ts(F.sub, w: w7, c: p.onAccent)),
              const SizedBox(height: 2),
              Text('${_tipStep + 1} / 2・自己試一次就到下一步', style: ts(F.cap, c: p.onAccent.withValues(alpha: .7))),
            ]),
          ),
          PillButton(
            label: _tipStep == 0 ? '略過' : '完成',
            height: 36,
            fill: p.onAccent.withValues(alpha: .25),
            fg: p.onAccent,
            onTap: () => _settings.update((s) => s.exploreTipsDone = true),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final filtered = _levels.isNotEmpty || _pos != null;
    return ListenableBuilder(
      listenable: appData,
      builder: (context, _) => ColoredBox(
        color: p.bg,
        child: Column(children: [
          SizedBox(
            height: top + 52,
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, top + 6, 16, 6),
              child: Stack(alignment: Alignment.center, children: [
                MenuBtn(
                  label: '切換字庫',
                  entries: _deckEntries,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_deck.label, style: ts(F.headline, w: w7)),
                    const SizedBox(width: 4),
                    Icon(Icons.unfold_more_rounded, size: 17, color: p.sec),
                  ]),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    BarIcon(
                      icon: _settings.autoSpeak ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                      label: _settings.autoSpeak ? '關閉自動唸單字' : '開啟自動唸單字',
                      onTap: () => _settings.update((s) => s.muted = !s.muted),
                    ),
                    const SizedBox(width: 8),
                    Builder(
                      builder: (c) => BarIcon(
                        icon: filtered ? Icons.filter_alt_rounded : Icons.filter_list_rounded,
                        label: '篩選',
                        onTap: () => _openFilter(c),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: !_settings.exploreTipsDone && _feed.isNotEmpty ? _tipBanner(p) : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _feed.isEmpty
                ? const Center(child: EmptyState('沒有符合的單字', icon: Icons.filter_alt_off_rounded, message: '調整篩選條件或換一個字庫。'))
                : PageView.builder(
                    controller: _pages,
                    itemCount: _feed.length,
                    onPageChanged: (i) {
                      setState(() {
                        _index = i;
                        if (_tipStep == 0) _tipStep = 1;
                      });
                      _speak(_feed[i]);
                    },
                    itemBuilder: (_, i) {
                      final e = _feed[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: ExploreCard(
                          key: ValueKey(e.w),
                          entry: e,
                          isSaved: _store.word(e.w)?.inMyWords ?? false,
                          onToggle: () => _toggle(e),
                          onList: () => showAddToList(context, (list) {
                            _store.add(e, list: list, myWords: list == null || (_store.word(e.w)?.inMyWords ?? false));
                          }),
                          onLookup: (t) => showWordConfirm(context, t),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 10),
          if (_feed.isNotEmpty) Text('${_index + 1} / ${_feed.length}', style: ts(F.cap, w: w7, c: p.sec)),
          SizedBox(height: BottomInset.of(context) - 4),
        ]),
      ),
    );
  }
}

class ExploreCard extends StatefulWidget {
  const ExploreCard({
    super.key,
    required this.entry,
    required this.isSaved,
    required this.onToggle,
    required this.onList,
    required this.onLookup,
  });
  final DictEntry entry;
  final bool isSaved;
  final VoidCallback onToggle, onList;
  final ValueChanged<String> onLookup;
  @override
  State<ExploreCard> createState() => _ExploreCardState();
}

class _ExploreCardState extends State<ExploreCard> {
  bool _pop = false;

  void _doubleTap() {
    if (!widget.isSaved) widget.onToggle();
    setState(() => _pop = true);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _pop = false);
    });
  }

  Widget _example(Palette p) {
    final e = widget.entry;
    final s = AppSettings.shared;
    return QuoteBlock(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (e.ex.isNotEmpty) ...[
          TappableSentence(sentence: e.ex, highlight: e.w, style: ts(F.body, w: w5), onTap: widget.onLookup),
          if (s.showTranslation && e.exZh.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(e.exZh, style: ts(F.sub, c: p.sec)),
          ],
        ] else if (e.def.isNotEmpty)
          TappableSentence(sentence: e.def, style: ts(F.sub), onTap: widget.onLookup),
        if (e.alt.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text('也寫作：${e.alt.join(', ')}', style: ts(F.cap, c: p.sec)),
        ],
      ]),
    );
  }

  Widget _similar(Palette p) {
    final e = widget.entry;
    final similar = Dict.similar(e.w, e.zh, e.pos);
    if (similar.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('相似字詞', style: ts(F.cap, w: w7, c: p.sec)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in similar)
          Tap(
            label: '${s.w}，${s.zh.isEmpty ? '' : s.zh.first}',
            onTap: () => widget.onLookup(s.w),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: p.accent.withValues(alpha: .08), borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                Text(s.w, style: ts(F.sub, w: w6, c: p.ink)),
                const SizedBox(width: 5),
                Flexible(child: Text(s.zh.isEmpty ? '' : s.zh.first, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.cap, c: p.sec))),
              ]),
            ),
          ),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final e = widget.entry;
    final saved = widget.isSaved;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: _doubleTap,
      child: Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.lg)),
        child: Stack(alignment: Alignment.center, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Wrap(spacing: 8, runSpacing: 6, children: [
                  if (e.lv.isNotEmpty && e.lv != '—') DetailTag(levelLabel(e.lv), filled: true),
                  if (e.pos.isNotEmpty) DetailTag(e.pos),
                  ExamYearsTag(term: e.w),
                ]),
              ),
              if (saved)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.bookmark_rounded, size: 15, color: p.accent),
                  const SizedBox(width: 3),
                  Text('已收藏', style: ts(F.cap, w: w7, c: p.accent)),
                ]),
            ]),
            const SizedBox(height: 14),
            // 內容放不下時（字放大）只有中間捲動，上面的標籤和下面的按鈕不動
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(top: 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(height: 56, width: double.infinity, child: FitText(e.w, style: ts(44, w: w7))),
                  const SizedBox(height: 14),
                  Row(children: [
                    SpeakButton(e.w),
                    const SizedBox(width: 8),
                    if (AppSettings.shared.exploreShowIPA && e.ipa.isNotEmpty)
                      Expanded(child: Text('/${e.ipa}/', style: ts(F.sub, c: p.sec))),
                  ]),
                  const SizedBox(height: 14),
                  Text(e.zh.take(3).join('；'), maxLines: 2, overflow: TextOverflow.ellipsis, style: ts(F.title2, w: w7)),
                  const SizedBox(height: 14),
                  _example(p),
                  const SizedBox(height: 14),
                  _similar(p),
                ]),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              PillButton(icon: Icons.create_new_folder_rounded, semantic: '加入清單', fg: p.accent, height: 52, width: 64, onTap: widget.onList),
              const SizedBox(width: 10),
              Expanded(
                child: PillButton(
                  label: saved ? '從我的單字移除' : '收進我的單字',
                  icon: saved ? Icons.bookmark_remove_rounded : Icons.bookmark_rounded,
                  fill: saved ? null : p.accent,
                  fg: saved ? null : p.onAccent,
                  height: 52,
                  onTap: widget.onToggle,
                ),
              ),
            ]),
          ]),
          IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: _pop ? .9 : 0,
              child: AnimatedScale(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutBack,
                scale: _pop ? 1.1 : .4,
                child: Icon(Icons.bookmark_rounded, size: 80, color: p.accent),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
