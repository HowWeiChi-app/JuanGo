// 新增：查字、匯入檔案、貼上單字清單。排版照 iOS 版 ImportTab。
// iOS 的拍照抓單字靠 Apple 的文字辨識，這一版先不放，不留按不了的按鈕。
// 課文書架（拍課文變電子書）用 ML Kit，入口在這頁。

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cloud.dart';
import 'dictionary.dart';
import 'models.dart';
import 'services.dart';
import 'sheets.dart';
import 'store.dart';
import 'textbook_pages.dart';
import 'theme.dart';
import 'widgets.dart';

class AddTab extends StatefulWidget {
  const AddTab({super.key});
  @override
  State<AddTab> createState() => _AddTabState();
}

class _AddTabState extends State<AddTab> {
  AppStore get _store => AppStore.shared;
  final _search = TextEditingController();
  final _focus = FocusNode();
  WordList? _destination;
  String? _toast;
  Timer? _toastTimer;

  String get _query => _search.text.trim();

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    _toastTimer?.cancel();
    super.dispose();
  }

  void _showToast(String text) {
    _toastTimer?.cancel();
    setState(() => _toast = text);
    _toastTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  void _lookup(String term) {
    showWordConfirm(context, term, destination: _destination, onAdded: (_) {
      _search.clear();
      _focus.unfocus();
      _showToast(_destination != null ? '已加入「${_destination!.name}」' : '已加入我的單字');
    });
  }

  void _submit([String? _]) {
    final q = _query;
    if (q.isEmpty) return;
    final first = Dict.suggestions(q);
    _lookup(Dict.hasChinese(q) && first.isNotEmpty ? first.first.w : q.toLowerCase());
  }

  /// 用朋友給的 8 碼代碼拿清單，確認後加入
  void _askCode() => promptText(
        context,
        '輸入分享代碼',
        hint: '例如 K7Q3-P9XM',
        confirm: '查詢',
        valid: (t) => Cloud.pretty(t).length == 9,
        onDone: (t) async {
          try {
            final f = await Cloud.shared.fetch(t);
            if (mounted) await confirmImport(context, f, _showToast);
          } on CloudFailure catch (e) {
            _showToast(e.message);
          }
        },
      );

  Future<void> _importFile() async {
    try {
      final file = await pickTextFile();
      if (file == null || !mounted) return;
      final (name, text) = file;
      if (name.toLowerCase().endsWith('.json')) {
        await confirmImport(context, AppStore.parseFile(text), _showToast);
      } else {
        _openCandidates(text);
      }
    } on FormatException catch (e) {
      _showToast(e.message);
    } catch (_) {
      _showToast('這個檔案讀不出來，請確認是 UTF-8 文字檔');
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (!mounted) return;
    if (text.trim().isEmpty) {
      _showToast('剪貼簿裡沒有文字');
    } else {
      _openCandidates(text);
    }
  }

  void _openCandidates(String text) => showCandidates(
        context,
        Candidates(text, fromFile: true),
        destination: _destination,
        onDone: (n) => _showToast('已加入 $n 個單字'),
      );

  List<Widget> _suggestionSlivers(Palette p) {
    final list = Dict.suggestions(_query);
    return [
      Sec(children: [
        for (final e in list)
          RowTile(
            titleWidget: Row(children: [
              Text(e.w, style: ts(F.headline, w: w6)),
              const SizedBox(width: 8),
              Expanded(child: Text(e.zh.isEmpty ? '' : e.zh.first, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.body, c: p.sec))),
            ]),
            trailing: _store.word(e.w) != null ? Icon(Icons.check_circle_rounded, size: 21, color: p.knowInk) : null,
            onTap: () => _lookup(e.w),
          ),
        if (list.isEmpty || list.first.w != _query.toLowerCase())
          RowTile(
            leading: Icon(Icons.search_rounded, size: 21, color: p.accent),
            title: '查詢「$_query」',
            titleColor: p.accent,
            onTap: _submit,
          ),
      ]),
    ];
  }

  Widget _recentRow(Palette p, Word w) => SwipeRow(
        actions: [SwipeAction('刪除', Icons.delete_rounded, p.destructive, () => _store.remove(w))],
        child: Builder(
          builder: (c) => Tap(
            dim: false,
            onTap: () => showWordDetail(context, w),
            onLongPress: () => showAppMenu(c, [
              MenuEntry('念出來', icon: Icons.volume_up_rounded, onTap: () => Speech.say(w.term)),
              MenuEntry('刪除', icon: Icons.delete_rounded, destructive: true, onTap: () => _store.remove(w)),
            ]),
            child: RowTile(title: w.term, value: w.primaryMeaning),
          ),
        ),
      );

  List<Widget> _mainSlivers(Palette p) {
    final recent = _store.words.where((w) => w.inMyWords).toList()..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final shown = recent.take(60).toList();
    return [
      Sec(footer: '查過的字會存在這裡。', children: [
        MenuBtn(
          label: '存到',
          entries: () => [
            MenuEntry('我的單字', checked: _destination == null, onTap: () => setState(() => _destination = null)),
            for (final l in _store.lists)
              MenuEntry(l.name, checked: _destination?.id == l.id, onTap: () => setState(() => _destination = l)),
          ],
          child: RowTile(
            leading: Icon(Icons.folder_outlined, size: 22, color: p.accent),
            title: '存到',
            value: _destination?.name ?? '我的單字',
            trailing: Icon(Icons.unfold_more_rounded, size: 17, color: p.sec),
          ),
        ),
      ]),
      const Sec(footer: '掃描整篇課文，變成可以點字查詢的電子書。', children: [BookshelfRow()]),
      Sec(header: '其他加入方式', footer: '分享代碼是朋友分享清單時拿到的 8 碼，72 小時內有效，不用登入也能加入。', children: [
        RowTile(
          leading: Icon(Icons.description_outlined, size: 22, color: p.accent),
          title: '匯入檔案（txt、csv、JuanGo 清單）',
          onTap: _importFile,
        ),
        RowTile(
          leading: Icon(Icons.content_paste_rounded, size: 21, color: p.accent),
          title: '貼上單字清單',
          trailing: PillButton(label: '貼上', height: 32, onTap: _paste),
        ),
        RowTile(
          leading: Icon(Icons.download_rounded, size: 22, color: p.accent),
          title: '輸入分享代碼',
          onTap: _askCode,
        ),
      ]),
      if (shown.isEmpty)
        Sec(header: '最近新增', children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('還沒有新增任何字。在上方搜尋，或匯入檔案、貼上單字清單。', style: ts(F.sub, c: p.sec)),
          ),
        ])
      else
        Sec(header: '最近新增', count: shown.length, builder: (_, i) => _recentRow(p, shown[i])),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: AppStore.shared,
      builder: (context, _) {
        // 清單被刪掉時，「存到」回到我的單字
        if (_destination != null && !_store.lists.any((l) => l.id == _destination!.id)) _destination = null;
        return Stack(children: [
          LargePage(
            title: '新增',
            search: SearchBox(
              controller: _search,
              focus: _focus,
              hint: '輸入英文單字或中文意思',
              onChanged: (_) => setState(() {}),
              onSubmit: _submit,
            ),
            slivers: _query.isEmpty ? _mainSlivers(p) : _suggestionSlivers(p),
          ),
          if (_toast != null)
            Positioned(
              left: 20,
              right: 20,
              bottom: BottomInset.of(context),
              child: Toast(text: _toast!, onClose: () => setState(() => _toast = null)),
            ),
        ]);
      },
    );
  }
}
