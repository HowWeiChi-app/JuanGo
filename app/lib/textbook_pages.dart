// 課文書架的畫面：書架、書（課的清單）、閱讀、單字表頁、點字小卡片、這課的生字。排版和文字照 iOS 版 TextbookViews.swift。
// Android 做不到的不放：Apple Intelligence 的修正和找文法（說明也不顯示）、「翻譯這段」、字典沒有的字自動翻譯。

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud.dart';
import 'dictionary.dart';
import 'models.dart';
import 'pro.dart';
import 'services.dart';
import 'sheets.dart';
import 'store.dart';
import 'study_flow.dart';
import 'textbook.dart';
import 'textbook_structure.dart';
import 'theme.dart';
import 'widgets.dart';
import 'word_quota.dart';

Shelf get _shelf => Shelf.shared;

void _paywall(BuildContext c) => unawaited(presentFull(c, const ProPaywall()));

/// 單字表的種類和文法句子的顏色：課文、圖例和清單都用同一套
class TBStyle {
  static Color color(Palette p, String kind) => switch (kind) {
        'general' => p.hsnuSky,
        'phrase' => p.hsnuMagenta,
        'grammar' => p.knowInk,
        _ => p.accent,
      };

  static Color grammarFill(Palette p) => p.knowInk.withValues(alpha: .13);
}

// MARK: 書架

/// 課文書架：掃描的課本，像電子書一樣讀。Pro 功能；免費帳號可以試用 1 課（最多 3 頁）
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
              if (Cloud.shared.signedIn)
                MenuBtn(
                  label: '更多',
                  entries: () => [MenuEntry('立即同步', icon: Icons.sync_rounded, onTap: () => unawaited(_shelf.sync()))],
                  child: const CircleBtn(icon: Icons.more_horiz_rounded, size: 40),
                ),
              BarIcon(icon: Icons.add_rounded, label: '新增書', onTap: _add),
            ],
            slivers: [
              if (_shelf.syncMessage != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: CardBox(
                      padding: 12,
                      radius: Radii.md,
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.cloud_off_rounded, size: 18, color: p.sec),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_shelf.syncMessage!, style: ts(F.foot, c: p.sec))),
                      ]),
                    ),
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
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 200, mainAxisSpacing: 18, crossAxisSpacing: 14, childAspectRatio: 0.55),
                    delegate: SliverChildBuilderDelegate((c, i) => _BookCover(books[i]), childCount: books.length),
                  ),
                ),
              SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 24), child: _footer(p))),
            ],
          );
        },
      );

  Widget _footer(Palette p) {
    final lines = <(String, Color?)>[
      if (!_shelf.isPro)
        ('免費版可以試用 1 課（最多 3 頁），閱讀和點字查詢都能用；更多課要升級 Pro。', null)
      else if (_shelf.pageCount >= Shelf.warnPages)
        ('已用 ${_shelf.pageCount} / ${Shelf.proPages} 頁，快到上限了。可以刪掉讀完的舊課。', p.againInk)
      else if (_shelf.pageCount > 0)
        ('已用 ${_shelf.pageCount} / ${Shelf.proPages} 頁', null),
      ('照片只用來辨識，存下來的是整理好的電子版，不保留原圖。', null),
      (Cloud.shared.signedIn ? '電子版會同步到你的其他裝置。' : '登入後就能在其他裝置閱讀。', null),
      ('課文有著作權，書架只給自己看，不能分享或匯出。', null),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (text, color) in lines)
        Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text, style: ts(F.foot, c: color ?? p.sec))),
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
          child: Container(
            decoration: BoxDecoration(color: p.accent.withValues(alpha: .18), borderRadius: BorderRadius.circular(Radii.md)),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(12),
            child: Text(book.title, textAlign: TextAlign.center, style: ts(F.title3, w: w7, c: p.accent)),
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
          CircleBtn(icon: Icons.close_rounded, label: '取消', onTap: () => Navigator.of(context).pop()),
          Expanded(child: Text(widget.bookId == null ? '新增書' : '編輯書', textAlign: TextAlign.center, style: ts(F.headline, w: w6))),
          BarText('儲存', onTap: _title.text.trim().isEmpty ? null : _save),
        ]),
        const SizedBox(height: 14),
        TextField(
            controller: _title,
            autofocus: true,
            style: ts(F.body, c: p.ink),
            decoration: deco('書名，例如「龍騰 B3」'),
            onChanged: (_) => setState(() {})),
        const SizedBox(height: 10),
        TextField(controller: _subject, style: ts(F.body, c: p.ink), decoration: deco('科目（可以不填）')),
        const SizedBox(height: 10),
        Text('建好以後在書裡新增一課，再拍照或匯入課文。', style: ts(F.foot, c: p.sec)),
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
        message: '標題之後也可以改。',
        initial: '第 ${count + 1} 課',
        confirm: '新增',
        valid: (t) => t.trim().isNotEmpty,
        onDone: (t) => pushPage(c, LessonReaderPage(lessonId: _shelf.addLesson(bookId, t.trim()).id))));
  }

  void _rename(BuildContext c, TBLesson l) => unawaited(promptText(c, '重新命名',
      hint: '例如 Lesson 3',
      message: '標題之後也可以改。',
      initial: l.title,
      confirm: '儲存',
      valid: (t) => t.trim().isNotEmpty,
      onDone: (t) => _shelf.renameLesson(l.id, t.trim())));

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
              Sec(footer: _shelf.isPro ? null : '免費版可以建 1 課（最多 3 頁）。', children: [
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
                        child: RowTile(title: l.title, titleStyle: ts(F.headline, w: w6), subtitle: _subtitle(l), chevron: true),
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
  bool _levels = false;
  double _scale = 1.15;
  (int, int)? _progress;

  @override
  void initState() {
    super.initState();
    final n = _shelf.pagesIn(widget.lessonId).length;
    _index = min(_shelf.lesson(widget.lessonId)?.lastReadPage ?? 0, max(0, n - 1));
    _pager = PageController(initialPage: _index);
    unawaited(_shelf.markGrammar(widget.lessonId));
    // 字級和大考顏色是整個書架共用的設定，跟 iOS 的 textbook.scale／textbook.levels 一樣
    unawaited(SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _scale = prefs.getDouble('textbook.scale') ?? _scale;
        _levels = prefs.getBool('textbook.levels') ?? _levels;
      });
    }));
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _setScale(double v) {
    setState(() => _scale = v);
    unawaited(SharedPreferences.getInstance().then((p) => p.setDouble('textbook.scale', v)));
  }

  void _setLevels(bool v) {
    setState(() => _levels = v);
    unawaited(SharedPreferences.getInstance().then((p) => p.setBool('textbook.levels', v)));
  }

  /// 還有頁數才打開匯入
  void _start(Future<void> Function() open) => _shelf.pagesLeft > 0 ? unawaited(open()) : _paywall(context);

  /// 拍照：ML Kit 文件掃描，自動裁切、拉正，一次可以拍好幾頁
  Future<void> _camera() async {
    final scanner = DocumentScanner(
        options: DocumentScannerOptions(pageLimit: min(_shelf.pagesLeft, 20), isGalleryImport: false, documentFormats: const {DocumentFormat.jpeg}));
    try {
      final r = await scanner.scanDocument();
      await _add(r.images ?? const <String>[]);
    } catch (_) {
      // 使用者按取消也會丟例外，不用提示
    } finally {
      await scanner.close();
    }
  }

  Future<void> _photos() async {
    final r = await FilePicker.pickFiles(type: FileType.image);
    await _add([for (final f in r.take(20)) ?f.path]);
  }

  /// PDF 每頁畫成長邊約 2000 px 的圖片（最多 30 頁），跟 iOS 的 PDFPages 一樣
  Future<void> _files() async {
    final r = await FilePicker.pickFiles(
        type: FileType.custom, allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png', 'webp', 'heic']);
    final paths = <String>[];
    for (final f in r) {
      final path = f.path;
      if (path == null) continue;
      if (path.toLowerCase().endsWith('.pdf')) {
        paths.addAll(await _pdfPages(path));
      } else {
        paths.add(path);
      }
    }
    await _add(paths);
  }

  static Future<List<String>> _pdfPages(String path) async {
    final out = <String>[];
    try {
      final doc = await PdfDocument.openFile(path);
      try {
        final dir = (await getTemporaryDirectory()).path;
        for (var i = 1; i <= min(doc.pagesCount, 30); i++) {
          final page = await doc.getPage(i);
          try {
            final k = 2000 / max(max(page.width, page.height), 1);
            final image = await page.render(
                width: page.width * k, height: page.height * k, format: PdfPageImageFormat.jpeg, backgroundColor: '#FFFFFF', quality: 90);
            if (image == null) continue;
            final f = File('$dir/textbook_pdf_${DateTime.now().microsecondsSinceEpoch}_$i.jpg');
            await f.writeAsBytes(image.bytes, flush: true);
            out.add(f.path);
          } finally {
            await page.close();
          }
        }
      } finally {
        await doc.close();
      }
    } catch (_) {}
    return out;
  }

  Future<void> _add(List<String> paths) async {
    if (paths.isEmpty || !mounted) return;
    final before = _shelf.pagesIn(widget.lessonId).length;
    final added = await PageImporter.add(paths, widget.lessonId, (d, t) {
      if (mounted) setState(() => _progress = (d, t));
    });
    if (!mounted) return;
    setState(() => _progress = null);
    if (added > 0) {
      setState(() => _index = before);
      WidgetsBinding.instance.addPostFrameCallback((_) => _pager.hasClients ? _pager.jumpToPage(before) : null);
    }
    if (added < paths.length && mounted) {
      _shelf.isPro ? await showAlert(context, '已經到 ${Shelf.proPages} 頁的上限，只加入了 $added 頁。') : _paywall(context);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _shelf,
        builder: (context, _) {
          final p = Palette.of(context);
          final pages = _shelf.pagesIn(widget.lessonId);
          if (_index > pages.length) _index = pages.length;
          final body = pages.isEmpty
              ? ListView(padding: const EdgeInsets.symmetric(horizontal: 24), children: [
                  const EmptyState('這課還沒有頁面',
                      icon: Icons.document_scanner_outlined, message: '課文和單字表都拍進來。一次可以拍好幾頁，App 會自動裁切、拉正，整理成電子版。'),
                  PrimaryButton(label: '拍照', icon: Icons.document_scanner_rounded, onTap: () => _start(_camera)),
                  const SizedBox(height: 10),
                  PillButton(label: '從相簿選照片', icon: Icons.photo_library_rounded, onTap: () => _start(_photos)),
                  const SizedBox(height: 10),
                  PillButton(label: '匯入 PDF 或圖片檔', icon: Icons.description_rounded, onTap: () => _start(_files)),
                ])
              : PageView.builder(
                  controller: _pager,
                  itemCount: pages.length + 1,
                  onPageChanged: (i) {
                    setState(() => _index = i);
                    if (i < pages.length) _shelf.setLastRead(widget.lessonId, i);
                  },
                  itemBuilder: (c, i) => i < pages.length
                      ? _PageReader(pageId: pages[i].id, lessonId: widget.lessonId, scale: _scale, levels: _levels)
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
                    const MenuEntry('字級', header: true),
                    MenuEntry('放大字', icon: Icons.text_increase_rounded, onTap: () => _setScale(min(2.0, _scale + .1))),
                    MenuEntry('縮小字', icon: Icons.text_decrease_rounded, onTap: () => _setScale(max(.8, _scale - .1))),
                    MenuEntry('顯示大考等級顏色', checked: _levels, onTap: () => _setLevels(!_levels)),
                    const MenuEntry('新增頁面', header: true),
                    MenuEntry('拍照', icon: Icons.document_scanner_rounded, onTap: () => _start(_camera)),
                    MenuEntry('從相簿選照片', icon: Icons.photo_library_rounded, onTap: () => _start(_photos)),
                    MenuEntry('匯入 PDF 或圖片檔', icon: Icons.description_rounded, onTap: () => _start(_files)),
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
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 60),
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
              ),
          ]);
        },
      );

  Widget _bottomBar(Palette p, List<TBPage> pages) {
    final onPage = _index < pages.length;
    final pending = onPage ? pages[_index].pending.length : 0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
        child: Row(children: [
          Text(onPage ? '第 ${_index + 1} / ${pages.length} 頁${pages[_index].content.isVocab ? '・單字表' : ''}' : '這課的生字',
              style: ts(F.foot, w: w6, c: p.sec)),
          const Spacer(),
          if (pending > 0) PillButton(label: '全部接受 $pending 個修正', height: 36, onTap: () => _shelf.acceptAll(pages[_index].id)),
        ]),
      ),
    );
  }
}

// MARK: 一頁

class _PageReader extends StatefulWidget {
  const _PageReader({required this.pageId, required this.lessonId, required this.scale, required this.levels});
  final String pageId, lessonId;
  final bool levels;
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

  double get _fontSize => F.body * widget.scale;

  /// 長按一段：聽其中一句
  void _sentences(BuildContext c, TBPage page, int pi) => unawaited(showAppMenu(c, [
        for (var s = 0; s < page.content.paragraphs[pi].sentences.length; s++)
          if (page.sentence(pi, s) case final text)
            MenuEntry('聽：${text.length > 28 ? '${text.substring(0, 28)}…' : text}',
                icon: Icons.volume_up_rounded, onTap: () => Speech.say(text)),
      ]));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: AppStore.shared,
        builder: (context, _) {
          final page = _shelf.page(widget.pageId);
          if (page == null) return const SizedBox.shrink();
          final saved = AppStore.shared.words.where((w) => w.inMyWords).map((w) => w.term).toSet();
          return ListView(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
            children: [
              if (page.content.isVocab)
                _VocabPageView(page: page, fontSize: _fontSize, saved: saved)
              else
                ..._textPage(Palette.of(context), page, saved),
            ],
          );
        },
      );

  List<Widget> _textPage(Palette p, TBPage page, Set<String> saved) {
    _clear();
    final index = _shelf.index(widget.lessonId);
    final found = index.marks(page);
    final marks = page.content.marks ?? const <TBMark>[];
    final grammar = {for (final m in marks) '${m.p}-${m.s}'};
    return [
      if (page.content.isEmpty) Text('這頁沒有辨識到英文。可以刪掉這頁再拍一次。', style: ts(F.body, c: p.sec)),
      _legend(p, found.kinds.values.toSet(), found.phrase.isNotEmpty, marks.isNotEmpty),
      for (final (pi, para) in page.content.paragraphs.indexed)
        Padding(
          padding: EdgeInsets.only(bottom: 18, top: para.style == 'subtitle' && pi > 0 ? 6 : 0),
          child: Builder(
            builder: (c) => GestureDetector(
              onLongPress: () => _sentences(c, page, pi),
              child: Semantics(header: para.style != null, child: _paragraph(p, page, pi, saved, found, grammar)),
            ),
          ),
        ),
      if (marks.isNotEmpty) _grammarList(p, page, marks, index),
    ];
  }

  /// 這頁用到的顏色是什麼意思
  Widget _legend(Palette p, Set<String> kinds, bool phrase, bool grammar) {
    final items = [
      for (final k in const ['word', 'general'])
        if (kinds.contains(k)) (k, LessonIndex.kindName(k)),
      if (phrase) ('phrase', '片語'),
      if (grammar) ('grammar', '文法重點'),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Semantics(
        container: true,
        child: Wrap(spacing: 12, runSpacing: 6, children: [
          for (final (kind, name) in items)
            Row(mainAxisSize: MainAxisSize.min, children: [
              switch (kind) {
                'phrase' => Container(width: 14, height: 2, color: TBStyle.color(p, kind)),
                'grammar' => Container(
                    width: 14, height: 12, decoration: BoxDecoration(color: TBStyle.grammarFill(p), borderRadius: BorderRadius.circular(3))),
                _ => Container(width: 8, height: 8, decoration: BoxDecoration(color: TBStyle.color(p, kind), shape: BoxShape.circle)),
              },
              const SizedBox(width: 5),
              Text(name, style: ts(F.cap, c: p.sec)),
            ]),
        ]),
      ),
    );
  }

  Widget _paragraph(Palette p, TBPage page, int pi, Set<String> saved,
      ({Map<TBPos, String> kinds, Set<TBPos> phrase}) found, Set<String> grammar) {
    final para = page.content.paragraphs[pi];
    final style = para.style;
    final size = style == 'title' ? _fontSize * 1.55 : style == 'subtitle' ? _fontSize * 1.25 : _fontSize;
    final weight = style == 'title' ? w7 : style == 'subtitle' ? w6 : null;
    final isBody = style == null;
    final fill = TBStyle.grammarFill(p);
    final spans = <InlineSpan>[];
    for (final (si, sen) in para.sentences.indexed) {
      final marked = grammar.contains('$pi-$si');
      for (final (wi, word) in sen.words.indexed) {
        if (si > 0 || wi > 0) spans.add(TextSpan(text: ' ', style: TextStyle(backgroundColor: marked && wi > 0 ? fill : null)));
        spans.add(_span(p, page, (p: pi, s: si, w: wi), word, saved, found, marked: marked, isBody: isBody, fill: fill));
      }
    }
    return Text.rich(TextSpan(style: ts(size, w: weight, c: p.ink, h: isBody ? 1.55 : 1.25), children: spans));
  }

  TextSpan _span(Palette p, TBPage page, TBPos pos, TBWord word, Set<String> saved,
      ({Map<TBPos, String> kinds, Set<TBPos> phrase}) found,
      {required bool marked, required bool isBody, required Color fill}) {
    final fix = page.correction(pos);
    final text = TBText.apply(fix, word.t);
    final core = page.shown(pos);
    final bold = word.isBold && isBody ? w7 : null;
    if (!core.contains(RegExp(r'\p{L}', unicode: true))) {
      return TextSpan(text: text, style: TextStyle(fontWeight: bold, backgroundColor: marked ? fill : null));
    }
    final entry = Dict.lookup(core);
    final term = entry?.w ?? core.toLowerCase();
    final kind = found.kinds[pos];
    final r = TapGestureRecognizer()..onTap = () => _openWord(page.id, pos);
    _recognizers.add(r);
    final pending = fix?.isPending == true;
    final inPhrase = found.phrase.contains(pos);
    return TextSpan(
      text: text,
      recognizer: r,
      style: TextStyle(
        color: kind != null ? TBStyle.color(p, kind) : widget.levels ? _levelColor(p, entry?.lv) : p.ink,
        fontWeight: kind == 'word' && isBody ? w7 : bold,
        backgroundColor: saved.contains(term) ? p.accent.withValues(alpha: .16) : marked ? fill : null,
        decoration: pending || inPhrase ? TextDecoration.underline : null,
        decorationStyle: pending ? TextDecorationStyle.dashed : TextDecorationStyle.solid,
        decorationColor: pending ? p.orange : TBStyle.color(p, 'phrase'),
        decorationThickness: 2,
      ),
    );
  }

  /// 這頁的文法重點：每個標出來的句子和它用到的文法
  Widget _grammarList(Palette p, TBPage page, List<TBMark> marks, LessonIndex index) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('這頁的文法重點', style: ts(F.headline, w: w6)),
          const SizedBox(height: 10),
          for (final m in marks)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: TBStyle.grammarFill(p), borderRadius: BorderRadius.circular(Radii.md)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.g, style: ts(F.sub, w: w6, c: TBStyle.color(p, 'grammar'))),
                const SizedBox(height: 5),
                Text(page.sentence(m.p, m.s), style: ts(F.sub, c: p.ink)),
                if (m.why != null && m.why!.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text('用到：${m.why}', style: ts(F.cap, c: p.sec)),
                ],
                if (index.grammar.where((g) => g.title == m.g).firstOrNull?.note case final note?) ...[
                  const SizedBox(height: 5),
                  Text(note, maxLines: 4, overflow: TextOverflow.ellipsis, style: ts(F.cap, c: p.sec)),
                ],
              ]),
            ),
          // iPhone 用 Apple Intelligence 找過的頁面同步過來時，照實說是怎麼找出來的
          Text(page.content.checkedBy == 'ai' ? '由 Apple Intelligence 對照這課單字表的文法重點找出。' : '依這課單字表文法重點的句型找出。',
              style: ts(F.cap, c: p.sec)),
        ]),
      );

  void _openWord(String pageId, TBPos pos) => unawaited(
      presentSheet(context, (_) => _WordCard(pageId: pageId, lessonId: widget.lessonId, pos: pos), height: 520).then((_) {
        if (mounted) setState(() {});
      }));
}

/// 單字表頁整理成清單：生字、一般生字、片語，再來是文法重點
class _VocabPageView extends StatelessWidget {
  const _VocabPageView({required this.page, required this.fontSize, required this.saved});
  final TBPage page;
  final double fontSize;
  final Set<String> saved;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final entries = page.content.entries ?? const <TBEntry>[];
    final grammar = page.content.grammar ?? const <TBGrammar>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('單字表', style: ts(fontSize * 1.55, w: w7)),
      const SizedBox(height: 22),
      for (final kind in const ['word', 'general', 'phrase'])
        if (entries.where((e) => e.kind == kind).toList() case final list when list.isNotEmpty) ...[
          Semantics(
            header: true,
            child: Text(LessonIndex.kindName(kind), style: ts(F.title3, w: w7, c: TBStyle.color(p, kind))),
          ),
          const SizedBox(height: 6),
          for (final e in list) ...[
            Tap(dim: false, onTap: () => showWordConfirm(context, e.t), child: _row(p, e)),
            Container(height: .5, color: p.separator),
          ],
          const SizedBox(height: 22),
        ],
      if (grammar.isNotEmpty) ...[
        Semantics(header: true, child: Text('文法重點', style: ts(F.title3, w: w7, c: TBStyle.color(p, 'grammar')))),
        const SizedBox(height: 10),
        for (final (i, g) in grammar.indexed)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: TBStyle.grammarFill(p), borderRadius: BorderRadius.circular(Radii.md)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${i + 1}. ${g.title}', style: ts(fontSize, w: w6)),
              if (g.note != null) ...[
                const SizedBox(height: 4),
                Text(g.note!, style: ts(F.sub, c: p.sec)),
              ],
            ]),
          ),
        Text('課文裡用到這些文法的句子會標出來。', style: ts(F.cap, c: p.sec)),
      ],
      if (entries.isEmpty && grammar.isEmpty) Text('這頁沒有辨識到單字。', style: ts(F.body, c: p.sec)),
    ]);
  }

  Widget _row(Palette p, TBEntry e) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(e.t, style: ts(fontSize, w: w6, c: p.ink)),
          if (e.pos != null) ...[
            const SizedBox(width: 8),
            Text(e.pos!, style: ts(F.sub, c: p.sec).copyWith(fontStyle: FontStyle.italic)),
          ],
          const SizedBox(width: 8),
          Expanded(child: Text(e.meaning, textAlign: TextAlign.end, style: ts(F.sub, c: p.sec))),
          if (saved.contains(Dict.lookup(e.t)?.w ?? e.t)) ...[
            const SizedBox(width: 8),
            Semantics(label: '已在我的單字', child: Icon(Icons.check_circle_rounded, size: 17, color: p.knowInk)),
          ],
        ]),
      );
}

// MARK: 點字的小卡片

/// 點一個字跳出的小卡片：意思、音標、等級、念出來、加入我的單字，有修正建議的話也在這裡
class _WordCard extends StatefulWidget {
  const _WordCard({required this.pageId, required this.lessonId, required this.pos});
  final String pageId, lessonId;
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
    final listed = _shelf.index(widget.lessonId).entry(shown);
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
      Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (entry != null && entry.ipa.isNotEmpty) Text('/${entry.ipa}/', style: ts(F.sub, c: p.sec)),
        if (listed != null) DetailTag('這課的${LessonIndex.kindName(listed.kind)}'),
        if (lv != null) DetailTag('大考 $lv 級') else if (entry?.tags.contains('toeic') == true) const DetailTag('多益'),
      ]),
      const SizedBox(height: 14),
      if (listed != null && listed.meaning.isNotEmpty) ...[
        Text([?listed.pos, listed.meaning].join(' '), style: ts(F.title3, w: w6, c: p.sec)),
        const SizedBox(height: 4),
        Text('課本單字表的意思', style: ts(F.cap, c: p.sec)),
        const SizedBox(height: 14),
      ] else if (entry != null && entry.zh.isNotEmpty) ...[
        Text([entry.pos, entry.zh.take(3).join('；')].where((s) => s.isNotEmpty).join(' '), style: ts(F.title3, w: w6, c: p.sec)),
        const SizedBox(height: 14),
      ],
      if (fix != null && fix.isPending) _suggestion(p, page, fix),
      if (fix != null && fix.status == 'accepted')
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text('原本辨識成「${fix.original}」，已改成「${fix.suggestion}」（${fix.sourceName}）', style: ts(F.foot, c: p.sec)),
        ),
      if (saved?.inMyWords == true)
        Row(children: [
          Icon(Icons.check_circle_rounded, color: p.knowInk, size: 20),
          const SizedBox(width: 6),
          Text('已在我的單字', style: ts(F.sub, w: w6, c: p.knowInk)),
        ])
      else
        PrimaryButton(label: '加入我的單字', onTap: () => _add(entry, shown, listed)),
      const SizedBox(height: 14),
      PillButton(
        label: '修改辨識結果',
        icon: Icons.edit_rounded,
        fg: p.sec,
        onTap: () => promptText(context, '修改辨識結果',
            hint: '正確的字',
            message: '只改這一個字，課文的其他地方不會動。',
            initial: shown,
            confirm: '儲存',
            valid: (t) => t.trim().isNotEmpty,
            onDone: (t) {
              final w = page.content.word(widget.pos);
              if (w == null) return;
              _shelf.setCorrection(page.id, TBCorrection(
                  p: widget.pos.p, s: widget.pos.s, w: widget.pos.w, original: w.core, suggestion: t.trim(), source: 'manual', status: 'accepted'));
              if (mounted) setState(() {});
            }),
      ),
    ]);
  }

  /// 課本單字表有這個字的話，用單字表上的意思加入
  void _add(DictEntry? entry, String shown, TBEntry? listed) {
    final meanings = listed?.zh == null || listed!.zh!.isEmpty ? null : listed.zh;
    if (entry != null && entry.zh.isNotEmpty) {
      AppStore.shared.add(entry, meanings: meanings);
    } else if (listed != null && meanings != null) {
      AppStore.shared.add(DictEntry.custom(listed.t, meanings.first), meanings: meanings);
    } else {
      unawaited(showWordConfirm(context, shown.toLowerCase(), onAdded: (_) => mounted ? setState(() {}) : null));
      return;
    }
    setState(() {});
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
          Text(page.sentence(widget.pos.p, widget.pos.s), style: ts(F.sub, c: p.sec)),
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
          final all = _shelf.lessonWords(lessonId);
          final fresh = all.where((w) => !saved.contains(w.entry.w)).toList();
          final fromList = all.any((w) => w.kind != 'dict');
          void addAll(bool study) => addWithinQuota(context, [for (final w in fresh) w.entry], () {
                final words = [for (final w in fresh) ?AppStore.shared.add(w.entry, meanings: w.meanings)];
                if (study && words.isNotEmpty) {
                  unawaited(startStudy(context, _shelf.lesson(lessonId)?.title ?? '這課的生字', words));
                }
              });
          return CustomScrollView(slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            if (fresh.isEmpty)
              Sec(headerWidget: Text('這課的生字', style: ts(F.headline, w: w6)), children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(all.isEmpty ? '這課還沒有大考或多益單字。拍下課本的單字表，就會用課本列的生字。' : '這課的生字都在「我的單字」裡了。',
                      style: ts(F.sub, c: p.sec)),
                ),
              ]),
            for (final kind in const ['word', 'general', 'phrase', 'dict'])
              if (fresh.where((w) => w.kind == kind).toList() case final list when list.isNotEmpty)
                Sec(
                  headerWidget: Text(kind == 'dict' ? '這課的生字' : LessonIndex.kindName(kind), style: ts(F.headline, w: w6)),
                  footer: kind == 'dict' ? '這課出現、還不在「我的單字」裡的大考字和多益字。' : null,
                  children: [
                    for (final w in list)
                      RowTile(
                        titleWidget: Row(children: [
                          Text(w.entry.w, style: ts(F.headline, w: w6)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(w.meanings?.firstOrNull ?? w.entry.zh.firstOrNull ?? '',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.sub, c: p.sec)),
                          ),
                        ]),
                        value: int.tryParse(w.entry.lv) != null ? '${w.entry.lv} 級' : w.entry.tags.contains('toeic') ? '多益' : null,
                        onTap: () => showWordConfirm(context, w.entry.w),
                      ),
                  ],
                ),
            if (fresh.isNotEmpty)
              Sec(footer: fromList ? '用課本單字表上的意思加入。' : null, children: [
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
