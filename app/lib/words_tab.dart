// 字庫：全部單字、清單、內建字庫，以及單字頁。排版照 iOS 版 WordsTab。

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import 'cloud.dart';
import 'dictionary.dart';
import 'exam.dart';
import 'models.dart';
import 'services.dart';
import 'settings.dart';
import 'sheets.dart';
import 'store.dart';
import 'study_flow.dart';
import 'theme.dart';
import 'widgets.dart';
import 'word_quota.dart';
import 'word_report.dart';

AppStore get _store => AppStore.shared;

enum WordSort {
  newest('最新加入'),
  oldest('最早加入'),
  alpha('A → Z'),
  level('熟練度'),
  due('下次複習');

  const WordSort(this.label);
  final String label;
}

Future<void> shareJson(Map<String, dynamic> data) async {
  final file = await _store.writeShareFile(data);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'application/json')]));
}

class WordsTab extends StatefulWidget {
  const WordsTab({super.key});
  @override
  State<WordsTab> createState() => _WordsTabState();
}

class _WordsTabState extends State<WordsTab> {
  final _search = TextEditingController();
  int _segment = 0;
  WordSort _sort = WordSort.newest;
  bool _selecting = false;
  final _selection = <String>{};

  String get _q => _search.text;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Word> _filtered() {
    var ws = _store.wordList;
    if (_q.isNotEmpty) {
      // 打的每個字都要出現，順序不拘："keep alive" 找得到 "keep sth alive"
      final parts = _q.replaceAll('’', "'").toLowerCase().split(' ').where((s) => s.isNotEmpty).toList();
      ws = ws.where((w) {
        final term = w.term.replaceAll('’', "'").toLowerCase();
        return parts.every((p) => term.contains(p) || w.meanings.any((m) => m.contains(p)));
      }).toList();
    }
    int byTerm(Word a, Word b) => a.term.toLowerCase().compareTo(b.term.toLowerCase());
    final far = DateTime(1970);
    ws.sort(switch (_sort) {
      WordSort.newest => (a, b) => b.addedAt.compareTo(a.addedAt),
      WordSort.oldest => (a, b) => a.addedAt.compareTo(b.addedAt),
      WordSort.alpha => byTerm,
      WordSort.level => (a, b) => a.srsLevel != b.srsLevel ? a.srsLevel - b.srsLevel : byTerm(a, b),
      WordSort.due => (a, b) {
          if (a.isNew != b.isNew) return a.isNew ? 1 : -1;
          final c = (a.dueDate ?? far).compareTo(b.dueDate ?? far);
          return c != 0 ? c : byTerm(a, b);
        },
    });
    return ws;
  }

  String _dayLabel(DateTime d) {
    final today = startOfDay(DateTime.now());
    if (d == today) return '今天';
    if (d == addDays(today, -1)) return '昨天';
    return monthDay(d);
  }

  void _toggleSel(Word w) => setState(() => _selection.contains(w.term) ? _selection.remove(w.term) : _selection.add(w.term));

  List<Word> get _selected => _selection.map(_store.word).whereType<Word>().toList();

  void _endSelection() => setState(() {
        _selecting = false;
        _selection.clear();
      });

  Widget _row(Palette p, Word w) {
    final on = _selection.contains(w.term);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(children: [
        if (_selecting) ...[
          Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined, size: 23, color: on ? p.accent : p.sec),
          const SizedBox(width: 10),
        ],
        Column(children: [
          for (var k = 5; k >= 1; k--)
            Container(
              width: 4,
              height: 5,
              margin: const EdgeInsets.symmetric(vertical: 1),
              decoration: BoxDecoration(color: k <= w.srsLevel ? p.accent : p.sec.withValues(alpha: .18), borderRadius: BorderRadius.circular(1)),
            ),
        ]),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(w.term, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.headline, w: w7)),
            if (AppSettings.shared.listShowMeaning) ...[
              const SizedBox(height: 2),
              Text(w.meaningLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, c: p.sec)),
            ],
          ]),
        ),
        if (w.favorite) ...[Icon(Icons.favorite_rounded, size: 13, color: p.accent, semanticLabel: '喜歡'), const SizedBox(width: 8)],
        Text(
          _sort == WordSort.due && !w.isNew ? (w.dueDate == null ? '已到期' : dueText(w.dueDate!)) : levelName(w.srsLevel),
          style: ts(F.cap, w: w6, c: p.sec),
        ),
      ]),
    );
    final tap = Tap(dim: false, onTap: _selecting ? () => _toggleSel(w) : () => pushPage(context, WordDetailPage(word: w)), child: content);
    if (_selecting) return tap;
    return SwipeRow(
      key: ValueKey(w.term),
      actions: [
        SwipeAction(w.favorite ? '取消喜歡' : '喜歡', Icons.favorite_rounded, p.accent, () => _store.toggleFavorite(w)),
        SwipeAction('刪除', Icons.delete_rounded, p.destructive, () => _store.remove(w)),
      ],
      child: tap,
    );
  }

  List<Widget> _allWords(Palette p) {
    if (_store.words.isEmpty) {
      return const [
        SliverToBoxAdapter(child: EmptyState('還沒有單字', icon: Icons.menu_book_outlined, message: '到「新增」或「探索」收集第一個單字吧。')),
      ];
    }
    final ws = _filtered();
    if (ws.isEmpty) {
      return [SliverToBoxAdapter(child: EmptyState('沒有「$_q」', icon: Icons.search_rounded, message: '到「新增」可以查字典裡的字。'))];
    }
    if (_sort != WordSort.newest && _sort != WordSort.oldest) {
      return [Sec(count: ws.length, builder: (_, i) => _row(p, ws[i]))];
    }
    final byDay = <DateTime, List<Word>>{};
    for (final w in ws) {
      (byDay[startOfDay(w.addedAt)] ??= []).add(w);
    }
    return [
      for (final e in byDay.entries) Sec(header: _dayLabel(e.key), count: e.value.length, builder: (_, i) => _row(p, e.value[i])),
    ];
  }

  bool _matches(String name) {
    final q = _q.trim().toLowerCase();
    return q.isEmpty || name.toLowerCase().contains(q);
  }

  Widget _listLabel(Palette p, String name, IconData icon, int n, VoidCallback onTap) => RowTile(
        leading: Icon(icon, size: 22, color: p.accent),
        title: name,
        value: '$n',
        chevron: true,
        onTap: onTap,
      );

  void _open(ListRoute r) => pushPage(context, ListWordsPage(route: r));

  List<Widget> _myLists(Palette p) {
    final lists = _store.lists.where((l) => _matches(l.name)).toList();
    return [
      if (_q.isEmpty)
        Sec(children: [
          RowTile(
            leading: Icon(Icons.add_circle_rounded, size: 23, color: p.accent),
            title: '建立新清單',
            titleStyle: ts(F.headline, w: w6, c: p.accent),
            onTap: () => promptText(context, '建立新清單', hint: '清單名稱', confirm: '建立', valid: _store.isNewListName, onDone: _store.createList),
          ),
        ]),
      Sec(children: [
        if (_matches('我的單字'))
          _listLabel(p, '我的單字', Icons.folder_rounded, _store.words.where((w) => w.inMyWords).length, () => _open(const ListRoute.myWords())),
        if (_matches('喜歡'))
          _listLabel(p, '喜歡', Icons.favorite_rounded, _store.words.where((w) => w.favorite).length, () => _open(const ListRoute.favorites())),
        for (final l in lists)
          SwipeRow(
            key: ValueKey(l.id),
            actions: [SwipeAction('刪除', Icons.delete_rounded, p.destructive, () => _store.deleteList(l))],
            child: _listLabel(p, l.name, Icons.folder_outlined, _store.wordsIn(l).length, () => _open(ListRoute.custom(l))),
          ),
      ]),
    ];
  }

  List<Widget> _decks(Palette p) {
    final have = _store.words.where((w) => w.inMyWords).map((w) => w.term).toSet();
    Widget link(Deck d) {
      final all = Dict.entriesOfDeck(d);
      final added = have.isEmpty ? 0 : all.where((e) => have.contains(e.w)).length;
      return RowTile(
        titleWidget: Text(d.label, style: ts(F.headline, w: w6)),
        subtitle: '${all.length} 個單字${added > 0 ? '・已加入 $added' : ''}・${d.subtitle}',
        chevron: true,
        onTap: () => _open(ListRoute.deck(d)),
      );
    }

    final exam = Deck.examDecks.where((d) => _matches(d.label)).toList();
    final test = Deck.testDecks.where((d) => _matches(d.label)).toList();
    final lvs = examLevels.where((l) => _matches(levelLabel(l))).toList();
    return [
      if (exam.isNotEmpty) Sec(header: '大考詞彙', children: exam.map(link).toList()),
      if (test.isNotEmpty) Sec(header: '國中小・檢定考試', children: test.map(link).toList()),
      if (lvs.isNotEmpty)
        Sec(header: '依等級', children: [
          for (final lv in lvs)
            _listLabel(p, levelLabel(lv), Icons.bar_chart_rounded, Dict.entriesOfLevel(lv).length, () => _open(ListRoute.level(lv))),
        ]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: appData,
      builder: (context, _) {
        final n = _selection.length;
        return Stack(children: [
          LargePage(
            title: '字庫',
            search: SearchBox(controller: _search, hint: '搜尋英文或中文', onChanged: (_) => setState(() {})),
            actions: [
              if (_segment == 0) ...[
                MenuBtn(
                  label: '排序',
                  entries: () => [
                    for (final s in WordSort.values) MenuEntry(s.label, checked: s == _sort, onTap: () => setState(() => _sort = s)),
                  ],
                  child: const AbsorbPointer(child: BarIcon(icon: Icons.swap_vert_rounded)),
                ),
                BarIcon(
                  icon: _selecting ? Icons.check_rounded : Icons.checklist_rounded,
                  label: _selecting ? '完成' : '選取',
                  onTap: () => setState(() {
                    _selecting = !_selecting;
                    _selection.clear();
                  }),
                ),
              ],
            ],
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                  child: Segmented<int>(
                    items: [(0, '全部 ${_store.words.length}'), (1, '清單'), (2, '內建字庫')],
                    value: _segment,
                    onChanged: (v) => setState(() => _segment = v),
                  ),
                ),
              ),
              ...switch (_segment) { 0 => _allWords(p), 1 => _myLists(p), _ => _decks(p) },
            ],
          ),
          if (_selecting && n > 0)
            Positioned(
              left: 16,
              right: 16,
              bottom: BottomInset.of(context),
              child: Row(children: [
                Expanded(
                  child: PillButton(
                    label: '加入清單',
                    icon: Icons.create_new_folder_rounded,
                    fill: p.card,
                    fg: p.accent,
                    onTap: () => showAddToList(context, (list) {
                      for (final w in _selected) {
                        if (!WordQuota.admit(w)) break;
                        list != null ? w.lists.add(list.id) : w.inMyWords = true;
                      }
                      _store.save();
                      _endSelection();
                    }),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PillButton(
                    label: '刪除 $n 個',
                    icon: Icons.delete_rounded,
                    fill: p.card,
                    fg: p.destructive,
                    onTap: () => confirmAction(
                      context,
                      '刪除 $n 個單字？',
                      message: '這些字的學習進度會一起刪除；每天的練習紀錄會保留。',
                      label: '刪除',
                      onConfirm: () {
                        _store.removeAll(_selected);
                        _endSelection();
                      },
                    ),
                  ),
                ),
              ]),
            ),
        ]);
      },
    );
  }
}

enum RouteKind { myWords, favorites, custom, deck, level }

class ListRoute {
  const ListRoute.myWords() : this._(RouteKind.myWords);
  const ListRoute.favorites() : this._(RouteKind.favorites);
  const ListRoute.custom(WordList l) : this._(RouteKind.custom, list: l);
  const ListRoute.deck(Deck d) : this._(RouteKind.deck, deck: d);
  const ListRoute.level(String lv) : this._(RouteKind.level, level: lv);
  const ListRoute._(this.kind, {this.list, this.deck, this.level});
  final RouteKind kind;
  final WordList? list;
  final Deck? deck;
  final String? level;
}

class ListWordsPage extends StatefulWidget {
  const ListWordsPage({super.key, required this.route});
  final ListRoute route;
  @override
  State<ListWordsPage> createState() => _ListWordsPageState();
}

class _ListWordsPageState extends State<ListWordsPage> {
  final _query = TextEditingController();
  bool _onlyNew = false;

  ListRoute get r => widget.route;
  bool get _isDeck => r.kind == RouteKind.deck || r.kind == RouteKind.level;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _sharing = false;

  /// 同一個清單每次分享都用同一個代碼
  String get _shareKey => '${r.kind.name}:${r.list?.id ?? r.deck?.name ?? r.level ?? ''}';

  Future<void> _shareCode(List<Word> words) async {
    if (!Cloud.shared.signedIn) {
      showAlert(context, '分享清單', message: '要先到「設定 › 帳號登入」登入，才能產生分享代碼。也可以改用「分享成檔案」。');
      return;
    }
    if (_sharing) return;
    setState(() => _sharing = true);
    final title = _title;
    try {
      final code = Cloud.pretty(await Cloud.shared.share(_store.listFile(title, words), _shareKey));
      if (!mounted) return;
      showAlert(
        context,
        '已建立分享代碼',
        message: '分享代碼：$code\n別人在「新增 › 輸入分享代碼」輸入就能加入這個清單（${words.length} 個字）。代碼 72 小時後失效，再分享一次會更新內容並重新計算 72 小時。',
        actions: [
          AlertAction('拷貝代碼', onTap: () => Clipboard.setData(ClipboardData(text: code))),
          AlertAction('傳給朋友', onTap: () => SharePlus.instance.share(ShareParams(text: '用 JuanGo 輸入分享代碼 $code，加入我的單字清單「$title」'))),
          const AlertAction('好', bold: true),
        ],
      );
    } catch (e) {
      if (mounted) showAlert(context, '$e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  String get _title => switch (r.kind) {
        RouteKind.myWords => '我的單字',
        RouteKind.favorites => '喜歡',
        RouteKind.custom => r.list!.name,
        RouteKind.deck => r.deck!.label,
        RouteKind.level => '大考詞彙${levelLabel(r.level!)}',
      };

  List<DictEntry> _entries() {
    final all = r.kind == RouteKind.deck ? Dict.entriesOfDeck(r.deck!) : Dict.entriesOfLevel(r.level!);
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((e) => e.w.toLowerCase().startsWith(q) || e.zh.any((z) => z.contains(q))).toList();
  }

  List<Word> _routeWords() => switch (r.kind) {
        RouteKind.myWords => _store.words.where((w) => w.inMyWords).toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt)),
        RouteKind.favorites => _store.words.where((w) => w.favorite).toList(),
        RouteKind.custom => _store.wordsIn(r.list!)..sort((a, b) => a.term.compareTo(b.term)),
        _ => const [],
      };

  void _removeFromRoute(Word w) {
    switch (r.kind) {
      case RouteKind.myWords:
        w.inMyWords = false;
      case RouteKind.favorites:
        w.favorite = false;
      case RouteKind.custom:
        w.lists.remove(r.list!.id);
      default:
        break;
    }
    _store.save();
  }

  Widget _entryRow(Palette p, DictEntry e) {
    final saved = _store.word(e.w) != null;
    return RowTile(
      titleWidget: Text(e.w, style: ts(F.headline, w: w6)),
      subtitle: '${e.pos} ${e.zh.join('・')}',
      subtitleLines: 2,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(levelLabel(e.lv), style: ts(F.cap, w: w7, c: p.sec)),
        const SizedBox(width: 8),
        Tap(
          label: saved ? '已加入我的單字' : '加入我的單字',
          dim: false,
          onTap: () {
            if (!saved) _store.add(e);
          },
          child: Icon(saved ? Icons.check_circle_rounded : Icons.add_circle_rounded, size: 26, color: saved ? p.knowInk : p.accent),
        ),
      ]),
      onTap: () => showWordConfirm(context, e.w),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: appData,
      builder: (context, _) {
        final words = _isDeck ? const <Word>[] : _routeWords();
        var entries = _isDeck ? _entries() : const <DictEntry>[];
        if (_onlyNew) entries = entries.where((e) => _store.word(e.w) == null).toList();
        return NavPage(
          title: _title,
          search: _isDeck ? SearchBox(controller: _query, hint: '搜尋英文或中文', onChanged: (_) => setState(() {})) : null,
          actions: [
            if (_isDeck)
              BarIcon(
                icon: _onlyNew ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
                label: _onlyNew ? '顯示全部' : '只看未加入',
                onTap: () => setState(() => _onlyNew = !_onlyNew),
              ),
            if (words.isNotEmpty) ...[
              BarIcon(icon: Icons.play_arrow_rounded, label: '練習', onTap: () => startStudy(context, _title, List.of(words)..shuffle())),
              Builder(
                builder: (bc) => BarIcon(
                  icon: Icons.ios_share_rounded,
                  label: '分享清單',
                  onTap: () => showAppMenu(bc, [
                    MenuEntry('產生分享代碼', icon: Icons.key_rounded, onTap: () => _shareCode(words)),
                    MenuEntry('分享成檔案', icon: Icons.description_outlined, onTap: () => shareJson(_store.listFile(_title, words))),
                  ]),
                ),
              ),
            ],
          ],
          slivers: _isDeck
              ? [
                  if (entries.isEmpty && _onlyNew)
                    SliverToBoxAdapter(
                      child: EmptyState(_query.text.isEmpty ? '這個字庫的字都加入了' : '沒有未加入的字', icon: Icons.check_circle_outline_rounded),
                    ),
                  if (entries.isNotEmpty) Sec(count: entries.length, builder: (_, i) => _entryRow(p, entries[i])),
                ]
              : [
                  if (r.kind == RouteKind.myWords && QuotaBanner.showing)
                    const SliverPadding(padding: EdgeInsets.fromLTRB(16, 8, 16, 8), sliver: SliverToBoxAdapter(child: QuotaBanner())),
                  if (words.isEmpty) const SliverToBoxAdapter(child: EmptyState('清單是空的', icon: Icons.inbox_outlined)),
                  if (words.isNotEmpty)
                    Sec(
                      header: r.kind == RouteKind.myWords ? WordQuota.usage(WordQuota.used(), unlimited: WordQuota.unlimited) : null,
                      count: words.length,
                      builder: (c, i) {
                        final w = words[i];
                        return SwipeRow(
                          key: ValueKey(w.term),
                          actions: [SwipeAction('移出清單', Icons.remove_circle_rounded, p.destructive, () => _removeFromRoute(w))],
                          child: RowTile(
                            titleWidget: Text(w.term, style: ts(F.headline, w: w6)),
                            subtitle: w.meaningLine,
                            chevron: true,
                            onTap: () => pushPage(context, WordDetailPage(word: w)),
                          ),
                        );
                      },
                    ),
                ],
        );
      },
    );
  }
}

// MARK: 單字頁

class WordDetailPage extends StatefulWidget {
  const WordDetailPage({super.key, required this.word, this.inSheet = false});
  final Word word;
  final bool inSheet;
  @override
  State<WordDetailPage> createState() => _WordDetailPageState();
}

class _WordDetailPageState extends State<WordDetailPage> {
  bool _showTranslation = true;

  /// 打開時選一次；每次重畫都換的話，字詞會在手指底下跳掉
  late final List<DictEntry> _related = () {
    final pool = Dict.entriesOfLevel(w.cefr).where((e) => e.w != w.term && _store.word(e.w) == null).toList()..shuffle(rng);
    return pool.take(4).toList();
  }();

  Word get w => widget.word;

  @override
  void initState() {
    super.initState();
    if (AppSettings.shared.detailAutoSpeak) Speech.say(w.term);
  }

  List<String>? get _dictMeanings {
    final d = Dict.lookup(w.term);
    if (d == null || d.w.toLowerCase() != w.term.toLowerCase() || d.zh.isEmpty) return null;
    if (d.zh.length == w.meanings.length && List.generate(d.zh.length, (i) => d.zh[i] == w.meanings[i]).every((b) => b)) return null;
    return d.zh;
  }

  void _edit() {
    final merged = {...w.meanings, ...(Dict.lookup(w.term)?.zh ?? const <String>[])}.toList();
    int rank(String m) {
      final i = w.meanings.indexOf(m);
      return i < 0 ? 99 : i;
    }

    merged.sort((a, b) => rank(a) - rank(b));
    final entry = DictEntry(w: w.term, ipa: w.ipa, pos: w.pos, zh: merged, def: w.definition, ex: w.example, exZh: w.exampleZh, lv: w.cefr);
    showEditWord(context, entry, w.meanings, (e, m) {
      w
        ..ipa = e.ipa
        ..pos = e.pos
        ..meanings = m
        ..definition = e.def
        ..example = e.ex
        ..exampleZh = e.exZh;
      _store.save();
    });
  }

  List<MenuEntry> _more() {
    final dict = _dictMeanings;
    return [
      MenuEntry('編輯詳細資料', icon: Icons.edit_note_rounded, onTap: _edit),
      if (dict != null)
        MenuEntry('改用字典的解釋', icon: Icons.menu_book_outlined, onTap: () {
          confirmAction(
            context,
            '改用字典的解釋？',
            message: '目前：${w.meanings.join('、')}\n字典：${dict.join('、')}',
            label: '改用',
            destructive: false,
            onConfirm: () {
              w.meanings = List.of(dict);
              _store.save();
            },
          );
        }),
      MenuEntry('重設學習進度', icon: Icons.replay_rounded, onTap: () {
        confirmAction(
          context,
          '重設「${w.term}」的學習進度？',
          message: '這個字會回到「未學」，之後當作新字重新練習。',
          label: '重設',
          onConfirm: () {
            w
              ..srsLevel = 0
              ..dueDate = null
              ..reviewCount = 0;
            _store.save();
          },
        );
      }),
      MenuEntry('回報問題', icon: Icons.feedback_outlined, onTap: () => showWordReport(context, w)),
      MenuEntry('刪除單字', icon: Icons.delete_rounded, destructive: true, onTap: () {
        confirmAction(
          context,
          '刪除「${w.term}」？',
          message: '這個字的學習進度會一起刪除；每天的練習紀錄會保留。',
          label: '刪除',
          onConfirm: () {
            Navigator.of(context).pop();
            _store.remove(w);
          },
        );
      }),
    ];
  }

  Widget _title(String t) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t, style: ts(F.sub, w: w7)));

  Widget _wordGrid(Palette p, String title, List<DictEntry> entries) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(title),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in entries)
            Tap(
              dim: false,
              onTap: () => showWordConfirm(context, e.w),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: p.card, borderRadius: BorderRadius.circular(Radii.md)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(e.w, style: ts(F.sub, w: w7)),
                      const SizedBox(height: 1),
                      Text(e.zh.isEmpty ? '' : e.zh.first, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.cap, c: p.sec)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Builder(builder: (_) {
                    final added = _store.word(e.w)?.inMyWords ?? false;
                    return Tap(
                      label: added ? '已加入我的單字' : '加入我的單字',
                      dim: false,
                      onTap: () {
                        if (!added) _store.add(e);
                      },
                      child: Icon(added ? Icons.check_rounded : Icons.add_rounded, size: 18, color: added ? p.sec : p.accent),
                    );
                  }),
                ]),
              ),
            ),
        ]),
      ]);

  Widget _info(Palette p, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(k, style: ts(F.sub)),
          const SizedBox(width: 12),
          Expanded(child: Text(v, textAlign: TextAlign.right, style: ts(F.sub, c: p.sec))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: AppStore.shared,
      builder: (context, _) {
        final lv = cefrToExam[w.cefr] ?? w.cefr;
        final synonyms = Dict.similar(w.term, Dict.lookup(w.term)?.zh ?? w.meanings, w.pos);
        final lists = _store.lists.where((l) => w.lists.contains(l.id)).map((l) => l.name).toList();
        final a = w.addedAt;
        const gap = SizedBox(height: 18);
        return NavPage(
          safeTop: !widget.inSheet,
          close: widget.inSheet,
          actions: [
            BarIcon(
              icon: Icons.create_new_folder_outlined,
              label: '加入清單',
              onTap: () => showAddToList(context, (list) {
                if (!WordQuota.admit(w)) return;
                list != null ? w.lists.add(list.id) : w.inMyWords = true;
                _store.save();
              }),
            ),
            BarIcon(
              icon: w.favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              label: '喜歡',
              onTap: () => _store.toggleFavorite(w),
            ),
            MenuBtn(label: '更多', entries: _more, child: const AbsorbPointer(child: BarIcon(icon: Icons.more_horiz_rounded))),
          ],
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
              sliver: SliverToBoxAdapter(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: double.infinity, child: FitText(w.term, style: ts(42, w: w7))),
                  const SizedBox(height: 10),
                  Row(children: [
                    SpeakButton(w.term),
                    const SizedBox(width: 8),
                    if (w.ipa.isNotEmpty) Expanded(child: Text('/${w.ipa}/', style: ts(F.sub, c: p.sec))),
                  ]),
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    if (w.pos.isNotEmpty) DetailTag(w.pos),
                    if (lv.isNotEmpty && lv != '—') DetailTag(levelLabel(lv)),
                    DetailTag(levelName(w.srsLevel)),
                    ExamYearsTag(term: w.term),
                  ]),
                  Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Container(height: .5, color: p.separator)),
                  for (final (k, m) in w.meanings.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 14, child: Padding(padding: const EdgeInsets.only(top: 4), child: Text('${k + 1}', style: ts(F.cap, w: w7, c: p.accent)))),
                        const SizedBox(width: 10),
                        Expanded(child: Text(m, style: k == 0 ? ts(F.title3, w: w7) : ts(F.body))),
                      ]),
                    ),
                  if (w.example.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      Text('例句', style: ts(F.sub, w: w7)),
                      const SizedBox(width: 6),
                      SpeakButton(w.example, size: 16),
                      const Spacer(),
                      Tap(
                        onTap: () => setState(() => _showTranslation = !_showTranslation),
                        child: Row(children: [
                          Text('翻譯', style: ts(F.cap, w: w7, c: p.sec)),
                          Icon(_showTranslation ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 17, color: p.sec),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    CardBox(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        TappableSentence(
                          sentence: w.example,
                          highlight: w.term,
                          style: ts(F.callout, w: w6),
                          onTap: (t) => showWordConfirm(context, t),
                        ),
                        if (_showTranslation) ...[
                          const SizedBox(height: 6),
                          Text(w.exampleZh, style: ts(F.foot, w: w6, c: p.sec)),
                        ],
                      ]),
                    ),
                    gap,
                  ],
                  if (synonyms.isNotEmpty) ...[_wordGrid(p, '同義字', synonyms), gap],
                  if (_related.isNotEmpty) ...[_wordGrid(p, '相同程度', _related), gap],
                  if (w.definition.isNotEmpty) ...[
                    _title('英文解釋'),
                    CardBox(child: Text(w.definition, style: ts(F.body))),
                    gap,
                  ],
                  _title('學習狀態'),
                  CardBox(
                    child: Column(children: [
                      _info(p, '加入日期', '${a.year}年${a.month}月${a.day}日'),
                      _info(p, '複習次數', '${w.reviewCount}'),
                      if (w.dueDate != null) _info(p, '下次複習', dueText(w.dueDate!)),
                      if (lists.isNotEmpty) _info(p, '清單', lists.join('、')),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}
