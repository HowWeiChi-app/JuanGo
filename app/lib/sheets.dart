// 到處都會用到的底部頁面：確認單字、加入清單、編輯單字、學習紀錄、匯入檔案。

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'dictionary.dart';
import 'models.dart';
import 'store.dart';
import 'theme.dart';
import 'widgets.dart';
import 'words_tab.dart';

AppStore get _store => AppStore.shared;

// MARK: 確認單字

Future<void> showWordConfirm(BuildContext c, String term, {WordList? destination, ValueChanged<Word>? onAdded}) =>
    presentSheet(c, (_) => WordConfirmSheet(term: term, destination: destination, onAdded: onAdded), height: 500);

class WordConfirmSheet extends StatefulWidget {
  const WordConfirmSheet({super.key, required this.term, this.destination, this.onAdded});
  final String term;
  final WordList? destination;
  final ValueChanged<Word>? onAdded;
  @override
  State<WordConfirmSheet> createState() => _WordConfirmSheetState();
}

class _WordConfirmSheetState extends State<WordConfirmSheet> {
  late DictEntry entry;
  late List<String> chosen;
  Word? saved;

  @override
  void initState() {
    super.initState();
    saved = _store.word(widget.term);
    final d = saved == null ? Dict.lookup(widget.term) : null;
    if (saved != null) {
      entry = saved!.toEntry();
      chosen = List.of(saved!.meanings);
    } else if (d != null) {
      entry = d;
      chosen = List.of(d.zh);
    } else {
      // 字典沒有的字：iOS 版會用 AI 翻譯，Android 版先讓使用者自己填
      entry = DictEntry.custom(widget.term, '');
      chosen = [];
    }
  }

  void _add() {
    final w = _store.add(entry, meanings: chosen, list: widget.destination);
    saved = w;
    widget.onAdded?.call(w);
    Navigator.of(context).pop();
  }

  void _unsave(Word w) {
    final removed = w.lists.isEmpty && !w.favorite;
    _store.removeFromMyWords(w);
    setState(() => saved = removed ? null : w);
  }

  Widget _meaning(Palette p) {
    final style = ts(F.title3, w: w6, c: p.sec);
    if (entry.pos.isNotEmpty && entry.zh.length <= 1 && chosen.isNotEmpty) {
      return Text('${entry.pos} ${chosen.first}', textAlign: TextAlign.center, style: style);
    }
    if (entry.zh.length > 1) {
      final current = chosen.isEmpty ? entry.zh.first : chosen.first;
      return MenuBtn(
        entries: () => [
          for (final m in entry.zh)
            MenuEntry(m, checked: current == m, onTap: () {
              setState(() => chosen = [m, ...entry.zh.where((z) => z != m)]);
            }),
          MenuEntry('選擇多個意思…', onTap: _edit),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(current, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
          const SizedBox(width: 4),
          Icon(Icons.unfold_more_rounded, size: 18, color: p.sec),
        ]),
      );
    }
    return Text(chosen.isEmpty ? '找不到解釋，可以自己編輯' : chosen.first, textAlign: TextAlign.center, style: style);
  }

  void _edit() => showEditWord(context, entry, chosen, (e, m) => setState(() {
        entry = e;
        chosen = m;
      }));

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = saved;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 22, 22, 22 + MediaQuery.paddingOf(context).bottom),
      child: Column(children: [
        Row(children: [
          Expanded(child: Text('確認單字', style: ts(F.headline, w: w6))),
          CircleBtn(icon: Icons.close_rounded, label: '關閉', onTap: () => Navigator.of(context).pop()),
        ]),
        const SizedBox(height: 18),
        FitText(entry.w, alignment: Alignment.center, style: ts(40, w: w6)),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (entry.ipa.isNotEmpty) Flexible(child: Text('/${entry.ipa}/', style: ts(F.body, c: p.sec))),
          const SizedBox(width: 10),
          SpeakButton(entry.w, size: 20),
        ]),
        const SizedBox(height: 14),
        _meaning(p),
        const Spacer(),
        if (s != null && s.inMyWords)
          PillButton(label: '取消加入', onTap: () => _unsave(s))
        else
          PrimaryButton(label: widget.destination != null ? '加入「${widget.destination!.name}」' : '加入我的單字', onTap: _add),
        const SizedBox(height: 12),
        PillButton(
          label: '加入其他清單',
          icon: Icons.create_new_folder_outlined,
          onTap: () => showAddToList(context, (list) {
            final w = _store.add(entry, meanings: chosen, list: list, myWords: list == null || (s?.inMyWords ?? false));
            setState(() => saved = w);
          }),
        ),
        const SizedBox(height: 12),
        PillButton(label: '編輯詳細資料', icon: Icons.edit_note_rounded, fg: p.sec, onTap: _edit),
      ]),
    );
  }
}

// MARK: 加入清單

Future<void> showAddToList(BuildContext c, ValueChanged<WordList?> onPick) =>
    presentSheet(c, (_) => _AddToListSheet(onPick));

class _AddToListSheet extends StatefulWidget {
  const _AddToListSheet(this.onPick);
  final ValueChanged<WordList?> onPick;
  @override
  State<_AddToListSheet> createState() => _AddToListSheetState();
}

class _AddToListSheetState extends State<_AddToListSheet> {
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(WordList? l) {
    Navigator.of(context).pop();
    widget.onPick(l);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final q = _search.text.toLowerCase();
        final lists = _store.lists.where((l) => q.isEmpty || l.name.toLowerCase().contains(q)).toList();
        return NavPage(
          title: '加入其他清單',
          close: true,
          safeTop: false,
          search: SearchBox(controller: _search, hint: '搜尋清單', onChanged: (_) => setState(() {})),
          slivers: [
            Sec(children: [
              RowTile(
                leading: Icon(Icons.add_circle_rounded, color: p.accent, size: 23),
                title: '建立新清單',
                titleStyle: ts(F.headline, w: w6, c: p.accent),
                onTap: () => promptText(context, '建立新清單',
                    hint: '清單名稱', confirm: '建立', valid: _store.isNewListName, onDone: _store.createList),
              ),
            ]),
            Sec(count: lists.length + 1, builder: (c, i) {
              if (i == 0) {
                return RowTile(leading: Icon(Icons.folder_rounded, color: p.accent, size: 22), title: '我的單字', onTap: () => _pick(null));
              }
              final l = lists[i - 1];
              return SwipeRow(
                actions: [SwipeAction('刪除', Icons.delete_rounded, p.destructive, () => _store.deleteList(l))],
                child: RowTile(
                  leading: Icon(Icons.folder_outlined, color: p.accent, size: 22),
                  title: l.name,
                  value: '${_store.wordsIn(l).length}',
                  onTap: () => _pick(l),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

// MARK: 編輯單字

Future<void> showEditWord(BuildContext c, DictEntry entry, List<String> selected, void Function(DictEntry, List<String>) onSave) =>
    presentSheet(c, (_) => _EditWordSheet(entry, selected, onSave));

class _EditWordSheet extends StatefulWidget {
  const _EditWordSheet(this.entry, this.selected, this.onSave);
  final DictEntry entry;
  final List<String> selected;
  final void Function(DictEntry, List<String>) onSave;
  @override
  State<_EditWordSheet> createState() => _EditWordSheetState();
}

class _EditWordSheetState extends State<_EditWordSheet> {
  late final _w = TextEditingController(text: widget.entry.w);
  late final _pos = TextEditingController(text: widget.entry.pos);
  late final _ipa = TextEditingController(text: widget.entry.ipa);
  late final _def = TextEditingController(text: widget.entry.def);
  late final _ex = TextEditingController(text: widget.entry.ex);
  late final _exZh = TextEditingController(text: widget.entry.exZh);
  final _custom = TextEditingController();
  late final _zh = List.of(widget.entry.zh);
  late final _selected = List.of(widget.selected);

  @override
  void dispose() {
    for (final c in [_w, _pos, _ipa, _def, _ex, _exZh, _custom]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(TextEditingController c, String hint, {TextStyle? style, int? lines = 1}) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: TextField(
        controller: c,
        minLines: 1,
        maxLines: lines,
        autocorrect: false,
        onChanged: (_) => setState(() {}),
        style: style ?? ts(F.body, c: p.ink),
        decoration: InputDecoration(isCollapsed: true, border: InputBorder.none, hintText: hint, hintStyle: ts(F.body, c: p.ter)),
      ),
    );
  }

  void _addCustom() {
    final m = _custom.text.trim();
    if (m.isEmpty) return;
    setState(() {
      _zh.add(m);
      _selected.add(m);
      _custom.clear();
    });
  }

  void _done() {
    final e = DictEntry(
      w: _w.text.trim().toLowerCase(),
      ipa: _ipa.text.trim(),
      pos: _pos.text.trim(),
      zh: _zh,
      def: _def.text.trim(),
      ex: _ex.text.trim(),
      exZh: _exZh.text.trim(),
      lv: widget.entry.lv,
    );
    widget.onSave(e, _selected.isEmpty ? _zh.take(1).toList() : _selected);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return NavPage(
      title: '確認單字',
      safeTop: false,
      leading: BarText('取消', bold: false, onTap: () => Navigator.of(context).pop()),
      actions: [BarText('完成', onTap: _w.text.trim().isEmpty ? null : _done)],
      slivers: [
        Sec(header: '單字', children: [_field(_w, '單字', style: ts(F.title3, w: w7, c: p.ink))]),
        Sec(header: '選擇要保留的意思', children: [
          for (final (i, m) in _zh.indexed)
            RowTile(
              leading: Icon(
                _selected.contains(m) ? Icons.check_circle_rounded : Icons.circle_outlined,
                size: 23,
                color: _selected.contains(m) ? p.accent : p.sec,
              ),
              titleWidget: Text(m, style: ts(F.headline, w: w6)),
              subtitle: entry.pos.isEmpty ? null : entry.pos,
              trailing: i == 0 ? Text('最常用', style: ts(F.cap, c: p.sec)) : null,
              onTap: () => setState(() => _selected.contains(m) ? _selected.remove(m) : _selected.add(m)),
            ),
          Row(children: [
            Expanded(child: _field(_custom, '新增自己的意思')),
            Tap(
              label: '新增這個意思',
              onTap: _custom.text.trim().isEmpty ? null : _addCustom,
              child: Padding(padding: const EdgeInsets.only(right: 12), child: Icon(Icons.add_circle_rounded, size: 26, color: p.accent)),
            ),
          ]),
        ]),
        Sec(header: '詞性與音標', children: [_field(_pos, '詞性（例如 n. / v. / adj.）'), _field(_ipa, '音標')]),
        Sec(header: '英文解釋', children: [_field(_def, 'Definition', lines: null)]),
        Sec(header: '例句', children: [_field(_ex, 'English example', lines: null), _field(_exZh, '中文翻譯', lines: null)]),
      ],
    );
  }

  DictEntry get entry => widget.entry;
}

// MARK: 單字頁（底部頁面版）

Future<void> showWordDetail(BuildContext c, Word w) =>
    presentSheet(c, (_) => WordDetailPage(word: w, inSheet: true));

// MARK: 學習紀錄

Future<void> showHistory(BuildContext c, List<ReviewLog> logs) => presentSheet(c, (_) => _HistorySheet(logs));

class _HistorySheet extends StatelessWidget {
  const _HistorySheet(this.logs);

  /// 由新到舊
  final List<ReviewLog> logs;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final groups = <DateTime, List<ReviewLog>>{};
    for (final l in logs.take(500)) {
      (groups[startOfDay(l.date)] ??= []).add(l);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    Color ink(int r) => [p.againInk, p.unsureInk, p.knowInk][r];
    return NavPage(
      title: '學習紀錄',
      safeTop: false,
      close: true,
      slivers: [
        if (logs.isEmpty) const SliverToBoxAdapter(child: EmptyState('還沒有學習紀錄', icon: Icons.schedule_rounded)),
        for (final d in days)
          Sec(header: monthDayWeek(d), children: [
            for (final l in groups[d]!)
              Builder(builder: (c) {
                final w = _store.word(l.term);
                return RowTile(
                  titleWidget: Row(children: [
                    Flexible(child: Text(l.term, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.headline, w: w6))),
                    if (l.wasNew) ...[const SizedBox(width: 6), Text('新字', style: ts(F.cap2, w: w7, c: p.accent))],
                  ]),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (l.result >= 0 && l.result <= 2) Text(Grade.values[l.result].label, style: ts(F.sub, w: w6, c: ink(l.result))),
                    const SizedBox(width: 8),
                    Text(hourMinute(l.date), style: ts(F.cap, c: p.sec)),
                  ]),
                  chevron: w != null,
                  onTap: w == null ? null : () => showWordDetail(c, w),
                );
              }),
          ]),
      ],
    );
  }
}

// MARK: 匯入

/// 文字或檔案裡找到的單字
class Candidates {
  Candidates(String text, {required bool fromFile}) {
    final seen = <String>{};
    final nonLetters = RegExp(r'[^\p{L}]+', unicode: true);
    final ascii = RegExp(r'^[a-z]+$');
    for (final line in const LineSplitter().convert(text)) {
      if (fromFile && (line.contains(',') || line.contains('\t'))) {
        final parts = line.split(RegExp('[,\t]'));
        final term = parts.first.trim().toLowerCase();
        final meaning = parts.skip(1).join(' ').trim();
        if (term.isEmpty || !seen.add(term)) continue;
        final e = Dict.lookup(term);
        e != null ? known.add(e) : unknown.add((term, meaning));
        continue;
      }
      for (final token in line.split(nonLetters)) {
        final t = token.toLowerCase();
        if (t.length < 3 || !ascii.hasMatch(t) || stopwords.contains(t) || !seen.add(t)) continue;
        final e = Dict.lookup(t);
        if (e == null) {
          unknown.add((t, ''));
        } else if (!known.contains(e)) {
          known.add(e);
        }
      }
    }
  }

  final known = <DictEntry>[];
  final unknown = <(String, String)>[];

  static const stopwords = {
    'the', 'and', 'for', 'are', 'was', 'were', 'with', 'that', 'this', 'from', 'have', 'has',
    'you', 'your', 'his', 'her', 'its', 'our', 'their', 'they', 'them', 'she', 'him', 'but', 'not', 'all', 'can', 'will',
    'would', 'should', 'could', 'into', 'about', 'there', 'here', 'what', 'when', 'where', 'which', 'who', 'how', 'than',
    'then', 'also', 'very', 'just', 'been', 'being', 'had', 'did', 'does', 'out', 'one', 'two', 'some', 'any', 'more',
    'many', 'much', 'every', 'make',
  };
}

Future<void> showCandidates(BuildContext c, Candidates cands, {WordList? destination, ValueChanged<int>? onDone}) =>
    presentSheet(c, (_) => _CandidatesSheet(cands, destination, onDone));

class _CandidatesSheet extends StatefulWidget {
  const _CandidatesSheet(this.cands, this.destination, this.onDone);
  final Candidates cands;
  final WordList? destination;
  final ValueChanged<int>? onDone;
  @override
  State<_CandidatesSheet> createState() => _CandidatesSheetState();
}

class _CandidatesSheetState extends State<_CandidatesSheet> {
  late final _selected = widget.cands.known.map((e) => e.w).toSet();

  Widget _row(Palette p, String term, String meaning, String? level) {
    final on = _selected.contains(term);
    return RowTile(
      leading: Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined, size: 23, color: on ? p.accent : p.sec),
      titleWidget: Row(children: [
        Text(term, style: ts(F.headline, w: w6)),
        const SizedBox(width: 8),
        Expanded(child: Text(meaning, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.body, c: p.sec))),
      ]),
      trailing: level == null ? null : Text(level, style: ts(F.cap, w: w7, c: p.sec)),
      onTap: () => setState(() => on ? _selected.remove(term) : _selected.add(term)),
    );
  }

  void _add() {
    var n = 0;
    for (final e in widget.cands.known) {
      if (_selected.contains(e.w)) {
        _store.add(e, list: widget.destination);
        n += 1;
      }
    }
    for (final (term, meaning) in widget.cands.unknown) {
      if (_selected.contains(term)) {
        _store.add(DictEntry.custom(term, meaning), list: widget.destination);
        n += 1;
      }
    }
    widget.onDone?.call(n);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = widget.cands;
    final allKnown = _selected.length == c.known.length;
    return NavPage(
      title: '選擇要加入的字',
      safeTop: false,
      leading: BarText('取消', bold: false, onTap: () => Navigator.of(context).pop()),
      actions: [BarText('加入 ${_selected.length} 個', onTap: _selected.isEmpty ? null : _add)],
      bottom: c.known.isEmpty
          ? null
          : Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 12 + MediaQuery.paddingOf(context).bottom),
              child: PillButton(
                label: allKnown ? '全不選' : '選取字典字',
                height: 44,
                onTap: () => setState(() {
                  _selected
                    ..clear()
                    ..addAll(allKnown ? const [] : c.known.map((e) => e.w));
                }),
              ),
            ),
      slivers: [
        if (c.known.isEmpty && c.unknown.isEmpty)
          const SliverToBoxAdapter(child: EmptyState('沒有找到英文單字', icon: Icons.document_scanner_outlined, message: '換一份內容再試一次。')),
        if (c.known.isNotEmpty)
          Sec(header: '字典裡有的單字', count: c.known.length, builder: (_, i) {
            final e = c.known[i];
            return _row(p, e.w, e.zh.isEmpty ? '' : e.zh.first, levelLabel(e.lv));
          }),
        if (c.unknown.isNotEmpty)
          Sec(header: '其他字', count: c.unknown.length, builder: (_, i) => _row(p, c.unknown[i].$1, c.unknown[i].$2, null)),
      ],
    );
  }
}

/// 確認要不要把備份或清單檔加進來
Future<void> confirmImport(BuildContext c, BackupFile f, ValueChanged<String> onDone) => confirmAction(
      c,
      f.title,
      message: '${f.summary}。\n會合併到這台裝置，不會刪除現有資料。',
      label: f.isBackup ? '還原' : '加入',
      destructive: false,
      onConfirm: () => onDone(_store.restore(f)),
    );

/// 選檔案並讀成文字；取消時回傳 null
Future<(String name, String text)?> pickTextFile({List<String> extensions = const ['txt', 'csv', 'json']}) async {
  final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: extensions);
  if (files.isEmpty) return null;
  final path = files.single.path;
  if (path == null) return null;
  return (files.single.name, await File(path).readAsString());
}

/// 選日期：年、月、日三個滾輪，從今年到三年後
Future<void> showDateWheel(BuildContext c, String title, DateTime initial, ValueChanged<DateTime> onDone) {
  final now = DateTime.now();
  final first = now.year;
  final year = FixedExtentScrollController(initialItem: (initial.year - first).clamp(0, 3));
  final month = FixedExtentScrollController(initialItem: initial.month - 1);
  final day = FixedExtentScrollController(initialItem: initial.day - 1);
  return presentSheet(c, height: 340, (ctx) {
    final p = Palette.of(ctx);
    Widget wheel(FixedExtentScrollController ctrl, List<String> items, String label) => Expanded(
          child: Semantics(
            label: label,
            child: ListWheelScrollView(
              controller: ctrl,
              itemExtent: 44,
              physics: const FixedExtentScrollPhysics(),
              perspective: .004,
              children: [for (final t in items) Center(child: Text(t, style: ts(F.title2, w: w6)))],
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
      child: Column(children: [
        Text(title, style: ts(F.title3, w: w7)),
        const SizedBox(height: 12),
        Expanded(
          child: Stack(alignment: Alignment.center, children: [
            Container(height: 44, decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(Radii.md))),
            Row(children: [
              wheel(year, [for (var y = first; y <= first + 3; y++) '$y年'], '年'),
              wheel(month, [for (var m = 1; m <= 12; m++) '$m月'], '月'),
              wheel(day, [for (var d = 1; d <= 31; d++) '$d日'], '日'),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        PrimaryButton(
          label: '完成',
          width: double.infinity,
          onTap: () {
            final y = first + year.selectedItem, m = month.selectedItem + 1;
            // 2 月 30 日這類不存在的日子改成那個月的最後一天；早於今天就用今天
            final last = DateTime(y, m + 1, 0).day;
            var d = DateTime(y, m, min(day.selectedItem + 1, last));
            if (d.isBefore(startOfDay(now))) d = startOfDay(now);
            onDone(d);
            Navigator.of(ctx).pop();
          },
        ),
      ]),
    );
  }).whenComplete(() {
    year.dispose();
    month.dispose();
    day.dispose();
  });
}

/// 選時間：Material 內建的時鐘是英文介面，這裡用兩個滾輪，文字和字體都跟著 App
Future<void> showTimeWheel(BuildContext c, int minutes, ValueChanged<int> onDone) {
  final hour = FixedExtentScrollController(initialItem: minutes ~/ 60);
  final minute = FixedExtentScrollController(initialItem: minutes % 60);
  return presentSheet(c, height: 340, (ctx) {
    final p = Palette.of(ctx);
    Widget wheel(FixedExtentScrollController ctrl, int count, String label) => Expanded(
          child: Semantics(
            label: label,
            child: ListWheelScrollView.useDelegate(
              controller: ctrl,
              itemExtent: 44,
              physics: const FixedExtentScrollPhysics(),
              perspective: .004,
              childDelegate: ListWheelChildLoopingListDelegate(children: [
                for (var i = 0; i < count; i++) Center(child: Text(i.toString().padLeft(2, '0'), style: ts(F.title2, w: w6))),
              ]),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
      child: Column(children: [
        Text('提醒時間', style: ts(F.title3, w: w7)),
        const SizedBox(height: 12),
        Expanded(
          child: Stack(alignment: Alignment.center, children: [
            Container(height: 44, decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(Radii.md))),
            Row(children: [
              wheel(hour, 24, '小時'),
              Text(':', style: ts(F.title2, w: w7)),
              wheel(minute, 60, '分鐘'),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        PrimaryButton(
          label: '完成',
          width: double.infinity,
          onTap: () {
            onDone((hour.selectedItem % 24) * 60 + minute.selectedItem % 60);
            Navigator.of(ctx).pop();
          },
        ),
      ]),
    );
  }).whenComplete(() {
    hour.dispose();
    minute.dispose();
  });
}
