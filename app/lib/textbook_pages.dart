// 課文書架的畫面：書架、書（課的清單）、閱讀、點字小卡片、這課的生字。排版照 iOS 版 TextbookViews.swift。

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:material_ui/material_ui.dart';

import 'cloud.dart';
import 'dictionary.dart';
import 'pro.dart';
import 'services.dart';
import 'sheets.dart';
import 'store.dart';
import 'study_flow.dart';
import 'textbook.dart';
import 'theme.dart';
import 'widgets.dart';
import 'word_quota.dart';

Shelf get _shelf => Shelf.shared;

void _paywall(BuildContext c) => unawaited(presentFull(c, const ProPaywall()));

// MARK: 書架

class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});
  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  @override
  void initState() {
    super.initState();
    unawaited(_shelf.load().then((_) => _shelf.sync(quiet: true)));
  }

  void _add() => _shelf.canAddBook ? _editBook(context, null) : _paywall(context);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _shelf,
        builder: (context, _) {
          final p = Palette.of(context);
          final books = _shelf.liveBooks;
          return NavPage(
            title: '課文書架',
            safeTop: false,
            actions: [
              MenuBtn(
                label: '更多',
                entries: () => [
                  MenuEntry('保留原圖', checked: _shelf.keepImages, onTap: () => unawaited(_shelf.setKeepImages(!_shelf.keepImages))),
                  if (Cloud.shared.signedIn) MenuEntry('立即同步', icon: Icons.sync_rounded, onTap: () => unawaited(_shelf.sync())),
                ],
                child: const CircleBtn(icon: Icons.more_horiz_rounded, size: 40),
              ),
              BarIcon(icon: Icons.add_rounded, label: '新增書', onTap: _add),
            ],
            slivers: [
              if (_shelf.syncMessage != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: CardBox(padding: 12, child: Text(_shelf.syncMessage!, style: ts(F.foot, c: p.sec))),
                  ),
                ),
              if (books.isEmpty)
                SliverToBoxAdapter(
                  child: Column(children: [
                    const EmptyState('書架還是空的', icon: Icons.auto_stories_outlined, message: '拍下課本、講義或補充閱讀，整理成可以點字查詢的電子書。'),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: PrimaryButton(label: '新增第一本書', onTap: _add)),
                  ]),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 200, mainAxisSpacing: 18, crossAxisSpacing: 14, childAspectRatio: 0.55),
                    delegate: SliverChildBuilderDelegate((c, i) => _BookCover(books[i]), childCount: books.length),
                  ),
                ),
              SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 0), child: _footer(p))),
            ],
          );
        },
      );

  Widget _footer(Palette p) {
    final lines = <String>[
      if (!_shelf.isPro) '免費版可以試用 1 課（最多 3 頁），閱讀和點字查詢都能用；更多課要升級 Pro。',
      if (_shelf.isPro && _shelf.pageCount >= Shelf.warnPages)
        '已用 ${_shelf.pageCount} / ${Shelf.proPages} 頁，快到上限了。可以關掉「保留原圖」，或刪掉舊課。'
      else if (_shelf.isPro && _shelf.pageCount > 0)
        '已用 ${_shelf.pageCount} / ${Shelf.proPages} 頁',
      '掃錯的字用字典比對找出來，每個都要你確認才會改。',
      Cloud.shared.signedIn ? (_shelf.keepImages ? '文字和原圖會同步到你的其他裝置。' : '只同步文字，原圖留在這支手機。') : '登入後就能在其他裝置閱讀。',
      '課文有著作權，書架只給自己看，不能分享或匯出。',
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l, style: ts(F.foot, c: p.sec))),
    ]);
  }
}

class _BookCover extends StatelessWidget {
  const _BookCover(this.book);
  final TBBook book;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lessons = _shelf.lessonsIn(book.id);
    final last = lessons.isEmpty ? null : lessons.reduce((a, b) => a.updatedAt.isAfter(b.updatedAt) ? a : b);
    return Tap(
      label: book.title,
      onTap: () => pushPage(context, BookPage(bookId: book.id)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AspectRatio(
          aspectRatio: 3 / 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: Container(
              color: p.accent.withValues(alpha: .18),
              alignment: Alignment.center,
              child: FutureBuilder<File?>(
                future: _shelf.cover(book.id),
                builder: (c, s) => s.data != null
                    ? Image.file(s.data!, fit: BoxFit.cover, width: double.infinity, height: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(book.title, textAlign: TextAlign.center, style: ts(F.title3, w: w7, c: p.accent)),
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.headline, w: w6)),
        Text([?book.subject, '${lessons.length} 課'].join('・'), style: ts(F.cap, c: p.sec)),
        if (last != null)
          Text('讀到 ${last.title} 第 ${last.lastReadPage + 1} 頁', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.cap, c: p.sec)),
      ]),
    );
  }
}

/// 新增書，或改書名和科目
void _editBook(BuildContext c, String? bookId) => unawaited(presentSheet(c, (_) => _BookEditor(bookId), height: 330));

class _BookEditor extends StatefulWidget {
  const _BookEditor(this.bookId);
  final String? bookId;
  @override
  State<_BookEditor> createState() => _BookEditorState();
}

class _BookEditorState extends State<_BookEditor> {
  late final _title = TextEditingController(text: _shelf.book(widget.bookId ?? '')?.title ?? '');
  late final _subject = TextEditingController(text: _shelf.book(widget.bookId ?? '')?.subject ?? '');

  @override
  void dispose() {
    _title.dispose();
    _subject.dispose();
    super.dispose();
  }

  void _save() {
    final t = _title.text.trim(), s = _subject.text.trim();
    if (t.isEmpty) return;
    if (widget.bookId == null) {
      _shelf.addBook(t, s);
    } else {
      _shelf.updateBook(widget.bookId!, t, s);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    InputDecoration deco(String hint) => InputDecoration(
          hintText: hint,
          hintStyle: ts(F.body, c: p.ter),
          filled: true,
          fillColor: p.card,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide.none),
        );
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(widget.bookId == null ? '新增書' : '編輯書', style: ts(F.headline, w: w6))),
          BarText('儲存', onTap: _save),
        ]),
        const SizedBox(height: 14),
        TextField(controller: _title, autofocus: true, style: ts(F.body, c: p.ink), decoration: deco('書名，例如「龍騰 B3」'),
            onChanged: (_) => setState(() {})),
        const SizedBox(height: 10),
        TextField(controller: _subject, style: ts(F.body, c: p.ink), decoration: deco('科目（可以不填）')),
        const SizedBox(height: 10),
        Text('建好以後在書裡新增一課，再拍照或從相簿匯入課文。', style: ts(F.foot, c: p.sec)),
      ]),
    );
  }
}

// MARK: 書（課的清單）

class BookPage extends StatelessWidget {
  const BookPage({super.key, required this.bookId});
  final String bookId;

  void _newLesson(BuildContext c, int count) {
    if (!_shelf.canAddLesson) return _paywall(c);
    unawaited(promptText(c, '新增一課',
        hint: '例如 Lesson 3',
        initial: '第 ${count + 1} 課',
        confirm: '新增',
        valid: (t) => t.trim().isNotEmpty,
        onDone: (t) => pushPage(c, LessonReaderPage(lessonId: _shelf.addLesson(bookId, t.trim()).id))));
  }

  void _rename(BuildContext c, TBLesson l) => unawaited(promptText(c, '重新命名',
      hint: '課名', initial: l.title, confirm: '儲存', valid: (t) => t.trim().isNotEmpty, onDone: (t) => _shelf.renameLesson(l.id, t.trim())));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _shelf,
        builder: (context, _) {
          final p = Palette.of(context);
          final lessons = _shelf.lessonsIn(bookId);
          return NavPage(
            title: _shelf.book(bookId)?.title ?? '',
            safeTop: false,
            actions: [
              MenuBtn(
                label: '更多',
                entries: () => [
                  MenuEntry('編輯書名', icon: Icons.edit_rounded, onTap: () => _editBook(context, bookId)),
                  MenuEntry('刪除這本書', icon: Icons.delete_rounded, destructive: true,
                      onTap: () => confirmAction(context, '刪除「${_shelf.book(bookId)?.title ?? ''}」？',
                          message: '所有裝置上的這本書都會刪掉，無法復原。', label: '刪除這本書和所有課', onConfirm: () {
                        _shelf.deleteBook(bookId);
                        Navigator.of(context).maybePop();
                      })),
                ],
                child: const CircleBtn(icon: Icons.more_horiz_rounded, size: 40),
              ),
            ],
            slivers: [
              SliverToBoxAdapter(
                child: Sec(footer: _shelf.isPro ? null : '免費版可以建 1 課（最多 3 頁）。', children: [
                  for (final l in lessons)
                    SwipeRow(
                      actions: [SwipeAction('刪除', Icons.delete_rounded, p.destructive, () => _shelf.deleteLesson(l.id))],
                      child: Builder(
                        builder: (c) => Tap(
                          dim: false,
                          onTap: () => pushPage(context, LessonReaderPage(lessonId: l.id)),
                          onLongPress: () => showAppMenu(c, [
                            MenuEntry('重新命名', icon: Icons.edit_rounded, onTap: () => _rename(context, l)),
                            MenuEntry('刪除', icon: Icons.delete_rounded, destructive: true, onTap: () => _shelf.deleteLesson(l.id)),
                          ]),
                          child: RowTile(title: l.title, subtitle: _subtitle(l), chevron: true),
                        ),
                      ),
                    ),
                  RowTile(
                    leading: Icon(_shelf.canAddLesson ? Icons.add_rounded : Icons.lock_rounded, size: 22, color: p.accent),
                    title: '新增一課',
                    titleColor: p.accent,
                    onTap: () => _newLesson(context, lessons.length),
                  ),
                ]),
              ),
            ],
          );
        },
      );

  String _subtitle(TBLesson l) {
    final n = _shelf.pagesIn(l.id).length;
    return n == 0 ? '還沒有頁面' : '$n 頁・讀到第 ${min(l.lastReadPage, n - 1) + 1} 頁';
  }
}

// MARK: 閱讀一課

class LessonReaderPage extends StatefulWidget {
  const LessonReaderPage({super.key, required this.lessonId});
  final String lessonId;
  @override
  State<LessonReaderPage> createState() => _LessonReaderPageState();
}

class _LessonReaderPageState extends State<LessonReaderPage> {
  late final PageController _pager;
  int _index = 0;
  bool _showImage = false;
  bool _levels = false;
  double _scale = 1.15;
  (int, int)? _progress;

  @override
  void initState() {
    super.initState();
    final n = _shelf.pagesIn(widget.lessonId).length;
    _index = min(_shelf.lesson(widget.lessonId)?.lastReadPage ?? 0, max(0, n - 1));
    _pager = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  /// ML Kit 文件掃描：拍照（自動裁切、拉正、一次好幾頁），也可以從相簿匯入
  Future<void> _scan() async {
    final left = _shelf.pagesLeft;
    if (left <= 0) return _paywall(context);
    final scanner = DocumentScanner(
        options: DocumentScannerOptions(pageLimit: min(left, 20), isGalleryImport: true, documentFormats: const {DocumentFormat.jpeg}));
    try {
      final r = await scanner.scanDocument();
      final paths = r.images ?? const <String>[];
      if (paths.isEmpty) return;
      final before = _shelf.pagesIn(widget.lessonId).length;
      final added = await PageImporter.add(paths, widget.lessonId, (d, t) => setState(() => _progress = (d, t)));
      if (!mounted) return;
      setState(() => _progress = null);
      if (added > 0) {
        _index = before;
        WidgetsBinding.instance.addPostFrameCallback((_) => _pager.hasClients ? _pager.jumpToPage(before) : null);
      }
      if (added < paths.length && mounted) {
        _shelf.isPro ? await showAlert(context, '已經到 ${Shelf.proPages} 頁的上限，只加入了 $added 頁。') : _paywall(context);
      }
    } catch (e) {
      if (mounted) setState(() => _progress = null);
      // 使用者按取消也會丟例外，不用提示
    } finally {
      await scanner.close();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _shelf,
        builder: (context, _) {
          final p = Palette.of(context);
          final pages = _shelf.pagesIn(widget.lessonId);
          final body = pages.isEmpty
              ? ListView(children: [
                  const EmptyState('這課還沒有頁面', icon: Icons.document_scanner_outlined, message: '一次可以拍好幾頁，App 會自動裁切、拉正；也可以從相簿匯入。'),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: PrimaryButton(label: '拍照或從相簿匯入', icon: Icons.document_scanner_rounded, onTap: _scan)),
                ])
              : PageView.builder(
                  controller: _pager,
                  itemCount: pages.length + 1,
                  onPageChanged: (i) {
                    setState(() => _index = i);
                    if (i < pages.length) _shelf.setLastRead(widget.lessonId, i);
                  },
                  itemBuilder: (c, i) => i < pages.length
                      ? _PageReader(pageId: pages[i].id, showImage: _showImage, scale: _scale, levels: _levels)
                      : _LessonWords(lessonId: widget.lessonId),
                );
          return Stack(children: [
            NavPage(
              title: _shelf.lesson(widget.lessonId)?.title ?? '',
              safeTop: false,
              actions: [
                MenuBtn(
                  label: '更多',
                  entries: () => [
                    MenuEntry('文字', checked: !_showImage, onTap: () => setState(() => _showImage = false)),
                    MenuEntry('原圖', checked: _showImage, onTap: () => setState(() => _showImage = true)),
                    MenuEntry('放大字', icon: Icons.text_increase_rounded, onTap: () => setState(() => _scale = min(2, _scale + .1))),
                    MenuEntry('縮小字', icon: Icons.text_decrease_rounded, onTap: () => setState(() => _scale = max(.8, _scale - .1))),
                    MenuEntry('顯示大考等級顏色', checked: _levels, onTap: () => setState(() => _levels = !_levels)),
                    MenuEntry('新增頁面', icon: Icons.document_scanner_rounded, onTap: _scan),
                    MenuEntry('重新命名這課', icon: Icons.edit_rounded,
                        onTap: () => promptText(context, '重新命名',
                            hint: '課名',
                            initial: _shelf.lesson(widget.lessonId)?.title ?? '',
                            confirm: '儲存',
                            valid: (t) => t.trim().isNotEmpty,
                            onDone: (t) => _shelf.renameLesson(widget.lessonId, t.trim()))),
                    if (_index < pages.length)
                      MenuEntry('刪除這一頁', icon: Icons.delete_rounded, destructive: true, onTap: () {
                        _shelf.deletePage(pages[_index].id);
                        setState(() => _index = max(0, _index - 1));
                      }),
                  ],
                  child: const CircleBtn(icon: Icons.more_horiz_rounded, size: 40),
                ),
              ],
              slivers: [SliverFillRemaining(hasScrollBody: true, child: body)],
              bottom: pages.isEmpty ? null : _bottomBar(p, pages),
            ),
            if (_progress != null)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black26,
                  child: Center(
                    child: CardBox(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text('正在整理第 ${_progress!.$1} / ${_progress!.$2} 頁…', style: ts(F.body)),
                      ]),
                    ),
                  ),
                ),
              ),
          ]);
        },
      );

  Widget _bottomBar(Palette p, List<TBPage> pages) {
    final pending = _index < pages.length ? pages[_index].pending.length : 0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
        child: Row(children: [
          Text(_index < pages.length ? '第 ${_index + 1} / ${pages.length} 頁' : '這課的生字', style: ts(F.foot, w: w6, c: p.sec)),
          const Spacer(),
          if (pending > 0) PillButton(label: '全部接受 $pending 個修正', height: 36, onTap: () => _shelf.acceptAll(pages[_index].id)),
        ]),
      ),
    );
  }
}

// MARK: 一頁

class _PageReader extends StatefulWidget {
  const _PageReader({required this.pageId, required this.showImage, required this.scale, required this.levels});
  final String pageId;
  final bool showImage, levels;
  final double scale;
  @override
  State<_PageReader> createState() => _PageReaderState();
}

class _PageReaderState extends State<_PageReader> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  static Color _levelColor(Palette p, String? lv) => switch (int.tryParse(lv ?? '')) {
        1 || 2 => p.knowInk,
        3 || 4 => p.hsnuSky,
        5 || 6 => p.hsnuMagenta,
        _ => p.ink,
      };

  /// 長按一段：聽其中一句
  void _sentences(TBPage page, int pi) => unawaited(showAppMenu(context, [
        for (final s in page.content.paragraphs[pi].sentences.indexed)
          MenuEntry('聽：${_short(page.sentence(pi, s.$1))}', icon: Icons.volume_up_rounded, onTap: () => Speech.say(page.sentence(pi, s.$1))),
      ]));

  static String _short(String s) => s.length > 28 ? '${s.substring(0, 28)}…' : s;

  @override
  Widget build(BuildContext context) {
    final page = _shelf.page(widget.pageId);
    if (page == null) return const SizedBox.shrink();
    if (widget.showImage) return _PageImage(page: page);
    _clear();
    final p = Palette.of(context);
    final saved = AppStore.shared.words.where((w) => w.inMyWords).map((w) => w.term).toSet();
    final size = F.body * widget.scale;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
      children: [
        if (page.content.isEmpty) Text('這頁沒有辨識到英文。可以切換成「原圖」看看照片。', style: ts(F.body, c: p.sec)),
        for (final (pi, para) in page.content.paragraphs.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Builder(
              builder: (c) => GestureDetector(
                onLongPress: () => _sentences(page, pi),
                child: Text.rich(TextSpan(style: ts(size, c: p.ink, h: 1.55), children: [
                  for (final (si, sen) in para.sentences.indexed)
                    for (final (wi, word) in sen.words.indexed) ...[
                      if (si > 0 || wi > 0) const TextSpan(text: ' '),
                      _span(p, page, (p: pi, s: si, w: wi), word, saved),
                    ],
                ])),
              ),
            ),
          ),
      ],
    );
  }

  TextSpan _span(Palette p, TBPage page, TBPos pos, TBWord word, Set<String> saved) {
    final fix = page.correction(pos);
    final text = TBText.apply(fix, word.t);
    final core = page.shown(pos);
    if (!core.contains(RegExp('[A-Za-z]'))) return TextSpan(text: text);
    final entry = Dict.lookup(core);
    final r = TapGestureRecognizer()..onTap = () => _openWord(page.id, pos);
    _recognizers.add(r);
    final pending = fix?.isPending == true;
    return TextSpan(
      text: text,
      recognizer: r,
      style: TextStyle(
        color: widget.levels ? _levelColor(p, entry?.lv) : p.ink,
        backgroundColor: saved.contains(entry?.w ?? core.toLowerCase()) ? p.accent.withValues(alpha: .16) : null,
        decoration: pending ? TextDecoration.underline : null,
        decorationStyle: TextDecorationStyle.dashed,
        decorationColor: p.orange,
        decorationThickness: 2,
      ),
    );
  }

  void _openWord(String pageId, TBPos pos) =>
      unawaited(presentSheet(context, (_) => _WordCard(pageId: pageId, pos: pos), height: 520).then((_) {
        if (mounted) setState(() {});
      }));
}

/// 照片，有修正建議的字用虛線框起來
class _PageImage extends StatelessWidget {
  const _PageImage({required this.page});
  final TBPage page;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FutureBuilder<File?>(
      future: _shelf.loadImage(page),
      builder: (c, s) {
        if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
        if (s.data == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Text(page.imagePath == null ? '這頁沒有保留原圖。' : '原圖還沒下載，登入後再試一次。', style: ts(F.body, c: p.sec)),
            ),
          );
        }
        return InteractiveViewer(
          maxScale: 4,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: Stack(children: [
                Image.file(s.data!),
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (c, box) => Stack(children: [
                      for (final fix in page.pending)
                        if (page.content.word(fix.pos)?.box case final b? when b.length == 4)
                          Positioned(
                            left: b[0] * box.maxWidth - 2,
                            top: b[1] * box.maxHeight - 2,
                            width: b[2] * box.maxWidth + 4,
                            height: b[3] * box.maxHeight + 4,
                            child: DecoratedBox(decoration: BoxDecoration(border: Border.all(color: p.orange, width: 1.5))),
                          ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

// MARK: 點字的小卡片

class _WordCard extends StatefulWidget {
  const _WordCard({required this.pageId, required this.pos});
  final String pageId;
  final TBPos pos;
  @override
  State<_WordCard> createState() => _WordCardState();
}

class _WordCardState extends State<_WordCard> {
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final page = _shelf.page(widget.pageId);
    if (page == null) return const SizedBox.shrink();
    final shown = page.shown(widget.pos);
    final entry = Dict.lookup(shown);
    final fix = page.correction(widget.pos);
    final saved = AppStore.shared.word(entry?.w ?? shown);
    final lv = int.tryParse(entry?.lv ?? '');
    return ListView(padding: const EdgeInsets.all(22), children: [
      Row(children: [
        Flexible(child: FitText(entry?.w ?? shown, style: ts(34, w: w6))),
        const SizedBox(width: 8),
        SpeakButton(entry?.w ?? shown, size: 22),
        const Spacer(),
        CircleBtn(icon: Icons.close_rounded, label: '關閉', onTap: () => Navigator.of(context).pop()),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (entry != null && entry.ipa.isNotEmpty) Text('/${entry.ipa}/', style: ts(F.sub, c: p.sec)),
        if (lv != null) DetailTag('大考 $lv 級') else if (entry?.tags.contains('toeic') == true) const DetailTag('多益'),
      ]),
      const SizedBox(height: 10),
      if (entry != null && entry.zh.isNotEmpty)
        Text([entry.pos, entry.zh.take(3).join('；')].where((s) => s.isNotEmpty).join(' '), style: ts(F.title3, w: w6, c: p.sec))
      else
        Text('字典裡沒有這個字，加入時可以自己填意思。', style: ts(F.sub, c: p.sec)),
      const SizedBox(height: 14),
      if (fix != null && fix.isPending) _suggestion(p, page, fix),
      if (fix != null && fix.status == 'accepted')
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('原本辨識成「${fix.original}」，已改成「${fix.suggestion}」（${fix.sourceName}）', style: ts(F.foot, c: p.sec)),
        ),
      if (saved?.inMyWords == true)
        Row(children: [
          Icon(Icons.check_circle_rounded, color: p.knowInk, size: 20),
          const SizedBox(width: 6),
          Text('已在我的單字', style: ts(F.sub, w: w6, c: p.knowInk)),
        ])
      else
        PrimaryButton(
          label: '加入我的單字',
          onTap: () {
            if (entry != null && entry.zh.isNotEmpty) {
              AppStore.shared.add(entry);
              setState(() {});
            } else {
              unawaited(showWordConfirm(context, shown.toLowerCase(), onAdded: (_) => setState(() {})));
            }
          },
        ),
      const SizedBox(height: 10),
      PillButton(
        label: '修改辨識結果',
        icon: Icons.edit_rounded,
        fg: p.sec,
        onTap: () => promptText(context, '修改辨識結果',
            hint: '正確的字',
            initial: shown,
            confirm: '儲存',
            valid: (t) => t.trim().isNotEmpty,
            onDone: (t) {
              final w = page.content.word(widget.pos);
              if (w == null) return;
              _shelf.setCorrection(page.id, TBCorrection(
                  p: widget.pos.p, s: widget.pos.s, w: widget.pos.w, original: w.core, suggestion: t.trim(), source: 'manual', status: 'accepted'));
              setState(() {});
            }),
      ),
    ]);
  }

  Widget _suggestion(Palette p, TBPage page, TBCorrection fix) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: p.orange.withValues(alpha: .12), borderRadius: BorderRadius.circular(Radii.md)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('原本：${fix.original} → 建議：${fix.suggestion}', style: ts(F.headline, w: w6)),
          const SizedBox(height: 4),
          Text('由${fix.sourceName}找出，可能是掃錯的字', style: ts(F.cap, c: p.sec)),
          const SizedBox(height: 8),
          _Crop(page: page, pos: fix.pos),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: PrimaryButton(label: '接受', height: 42, onTap: () {
                _shelf.setCorrection(page.id, fix..status = 'accepted');
                setState(() {});
              }),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PillButton(label: '保留原文', height: 42, onTap: () {
                _shelf.setCorrection(page.id, fix..status = 'rejected');
                setState(() {});
              }),
            ),
          ]),
        ]),
      );
}

/// 原圖裡這個字的那一塊（左右各留兩個字高、上下留一點）
class _Crop extends StatelessWidget {
  const _Crop({required this.page, required this.pos});
  final TBPage page;
  final TBPos pos;

  Future<ui.Image?> _load() async {
    final f = await _shelf.loadImage(page);
    if (f == null) return null;
    final codec = await ui.instantiateImageCodec(await f.readAsBytes());
    return (await codec.getNextFrame()).image;
  }

  @override
  Widget build(BuildContext context) {
    final b = page.content.word(pos)?.box;
    if (b == null || b.length != 4) return const SizedBox.shrink();
    return FutureBuilder<ui.Image?>(
      future: _load(),
      builder: (c, s) {
        final image = s.data;
        if (image == null) return const SizedBox.shrink();
        final w = image.width.toDouble(), h = image.height.toDouble();
        final src = Rect.fromLTWH((b[0] - b[3] * 2) * w, (b[1] - b[3] * .4) * h, (b[2] + b[3] * 4) * w, b[3] * 1.8 * h)
            .intersect(Rect.fromLTWH(0, 0, w, h));
        if (src.isEmpty) return const SizedBox.shrink();
        return ClipRRect(
          borderRadius: BorderRadius.circular(Radii.sm),
          child: AspectRatio(aspectRatio: src.width / src.height, child: CustomPaint(painter: _CropPainter(image, src))),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.src);
  final ui.Image image;
  final Rect src;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
  @override
  bool shouldRepaint(_CropPainter old) => old.image != image || old.src != src;
}

// MARK: 這課的生字

class _LessonWords extends StatelessWidget {
  const _LessonWords({required this.lessonId});
  final String lessonId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: AppStore.shared,
        builder: (context, _) {
          final p = Palette.of(context);
          final saved = AppStore.shared.words.where((w) => w.inMyWords).map((w) => w.term).toSet();
          final all = _shelf.vocabulary(lessonId);
          final fresh = all.where((e) => !saved.contains(e.w)).toList();
          void addAll(bool study) => addWithinQuota(context, fresh, () {
                final words = [for (final e in fresh) ?AppStore.shared.add(e)];
                if (study && words.isNotEmpty) {
                  unawaited(startStudy(context, _shelf.lesson(lessonId)?.title ?? '這課的生字', words));
                }
              });
          return ListView(padding: const EdgeInsets.only(top: 4, bottom: 24), children: [
            Sec(header: '這課的生字', footer: '這課出現、還不在「我的單字」裡的大考字和多益字。', children: [
              if (fresh.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(all.isEmpty ? '這課還沒有大考或多益單字。' : '這課的大考和多益單字都在「我的單字」裡了。', style: ts(F.sub, c: p.sec)),
                ),
              for (final e in fresh)
                RowTile(
                  titleWidget: Row(children: [
                    Text(e.w, style: ts(F.headline, w: w6)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(e.zh.first, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, c: p.sec))),
                  ]),
                  value: int.tryParse(e.lv) != null ? '${e.lv} 級' : '多益',
                  onTap: () => showWordConfirm(context, e.w),
                ),
            ]),
            if (fresh.isNotEmpty)
              Sec(children: [
                RowTile(
                    leading: Icon(Icons.add_circle_outline_rounded, size: 22, color: p.accent),
                    title: '全部加入（${fresh.length} 個）',
                    titleColor: p.accent,
                    onTap: () => addAll(false)),
                RowTile(
                    leading: Icon(Icons.play_circle_outline_rounded, size: 22, color: p.accent),
                    title: '加入並開始練習',
                    titleColor: p.accent,
                    onTap: () => addAll(true)),
              ]),
          ]);
        },
      );
}

/// 新增頁的入口：「課文書架」那一列（不是 Pro 的話顯示小鎖頭）
class BookshelfRow extends StatelessWidget {
  const BookshelfRow({super.key});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return RowTile(
      leading: Icon(Icons.auto_stories_outlined, size: 22, color: p.accent),
      title: '課文書架',
      trailing: ProStore.shared.has(ProFeature.textbook)
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_rounded, size: 14, color: p.sec),
              const SizedBox(width: 3),
              Text('Pro', style: ts(F.cap, w: w6, c: p.sec)),
            ]),
      chevron: true,
      onTap: () => pushPage(context, const BookshelfPage()),
    );
  }
}
