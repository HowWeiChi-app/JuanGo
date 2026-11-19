// 共用元件。Android 沒有 iOS 的清單、選單與導覽列，這裡做出相同排版的版本，
// 各畫面就能用和 SwiftUI 差不多的結構來寫。

import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import 'models.dart';
import 'services.dart';
import 'settings.dart';
import 'store.dart';
import 'theme.dart';

/// 單字資料或設定改變時都要重畫的畫面用這個
Listenable get appData => Listenable.merge([AppStore.shared, AppSettings.shared]);

/// 頁面底部要留多少空間（分頁裡要避開浮動的分頁列）
class BottomInset extends InheritedWidget {
  const BottomInset({super.key, required this.value, required super.child});
  final double value;
  static double of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<BottomInset>()?.value ?? (24 + MediaQuery.paddingOf(c).bottom);
  @override
  bool updateShouldNotify(BottomInset old) => old.value != value;
}

// MARK: 按鈕

/// 按下會變淡的可點元件；onTap 為 null 時顯示成停用
class Tap extends StatefulWidget {
  const Tap({super.key, required this.child, this.onTap, this.onDoubleTap, this.onLongPress, this.dim = true, this.label});
  final Widget child;
  final VoidCallback? onTap, onDoubleTap, onLongPress;
  final bool dim;
  final String? label;
  @override
  State<Tap> createState() => _TapState();
}

class _TapState extends State<Tap> {
  bool _down = false;
  void _set(bool v) {
    if (mounted && v != _down) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onLongPress: widget.onLongPress,
        child: AnimatedOpacity(
          duration: Duration(milliseconds: _down ? 40 : 160),
          opacity: !enabled && widget.dim ? .4 : (_down ? .55 : 1),
          child: widget.child,
        ),
      ),
    );
  }
}

/// iOS 版的膠囊按鈕：有 fill 是主要動作，沒有是次要動作；高度超過 56 變成圓角方塊
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    this.label,
    this.icon,
    this.child,
    this.fill,
    this.fg,
    this.height = 50,
    this.width,
    this.onTap,
    this.semantic,
  });
  final String? label, semantic;
  final IconData? icon;
  final Widget? child;
  final Color? fill, fg;
  final double height;
  final double? width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = fg ?? p.ink;
    final content = child ??
        Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) Icon(icon, size: 19, color: color),
          if (icon != null && label != null) const SizedBox(width: 6),
          if (label != null)
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(label!, maxLines: 1, style: ts(F.headline, w: w6, c: color)),
              ),
            ),
        ]);
    return Tap(
      onTap: onTap,
      label: semantic ?? label,
      child: Container(
        height: height,
        width: width,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: fill ?? p.ink.withValues(alpha: p.dark ? .13 : .07),
          borderRadius: BorderRadius.circular(height > 56 ? Radii.lg : height / 2),
        ),
        child: DefaultTextStyle.merge(style: TextStyle(color: color), child: IconTheme.merge(data: IconThemeData(color: color), child: content)),
      ),
    );
  }
}

/// 主要動作的膠囊按鈕（主題色）
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, this.icon, this.onTap, this.height = 50, this.width});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final double height;
  final double? width;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PillButton(label: label, icon: icon, fill: p.accent, fg: p.onAccent, height: height, width: width, onTap: onTap);
  }
}

/// 可選的方塊（目標、字體、題型）
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({super.key, required this.selected, required this.child, this.onTap, this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 6)});
  final bool selected;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final fg = selected ? p.onAccent : p.ink;
    return Tap(
      onTap: onTap,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: selected ? p.accent : p.ink.withValues(alpha: p.dark ? .13 : .07),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: DefaultTextStyle.merge(style: TextStyle(color: fg), child: IconTheme.merge(data: IconThemeData(color: fg), child: child)),
      ),
    );
  }
}

/// 圓形圖示按鈕（關閉、返回、更多）
class CircleBtn extends StatelessWidget {
  const CircleBtn({super.key, required this.icon, this.onTap, this.label, this.size = 36, this.color});
  final IconData icon;
  final VoidCallback? onTap;
  final String? label;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Tap(
      onTap: onTap,
      label: label,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: p.ink.withValues(alpha: p.dark ? .13 : .07)),
        child: Icon(icon, size: size * .52, color: color ?? p.ink),
      ),
    );
  }
}

/// 導覽列右上角的圖示按鈕
class BarIcon extends StatelessWidget {
  const BarIcon({super.key, required this.icon, this.onTap, this.label});
  final IconData icon;
  final VoidCallback? onTap;
  final String? label;
  @override
  Widget build(BuildContext context) => CircleBtn(icon: icon, onTap: onTap, label: label, size: 40);
}

class CardBox extends StatelessWidget {
  const CardBox({super.key, required this.child, this.padding = 18, this.radius = Radii.lg});
  final Widget child;
  final double padding, radius;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(color: Palette.of(context).card, borderRadius: BorderRadius.circular(radius)),
        child: child,
      );
}

// MARK: 頁面

class _BarDelegate extends SliverPersistentHeaderDelegate {
  _BarDelegate(this.extent, this.child);
  final double extent;
  final Widget child;
  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;
  @override
  Widget build(BuildContext c, double shrink, bool overlaps) => child;
  @override
  bool shouldRebuild(_BarDelegate old) => true;
}

/// 分頁的主畫面：大標題，往上捲時標題收進導覽列
class LargePage extends StatefulWidget {
  const LargePage({super.key, required this.title, required this.slivers, this.actions = const [], this.search});
  final String title;
  final List<Widget> slivers;
  final List<Widget> actions;
  final Widget? search;
  @override
  State<LargePage> createState() => _LargePageState();
}

class _LargePageState extends State<LargePage> {
  final _scroll = ScrollController();
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_sync);
  }

  void _sync() {
    if (!mounted || !_scroll.hasClients) return;
    final c = _scroll.offset > 36;
    if (c != _collapsed) setState(() => _collapsed = c);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return ColoredBox(
      color: p.bg,
      // 內容變短（例如切到「清單」）時位置會被校正，但不會通知 controller
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
          return false;
        },
        child: CustomScrollView(
        controller: _scroll,
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _BarDelegate(
              top + 52,
              Container(
                color: p.bg,
                padding: EdgeInsets.fromLTRB(16, top + 6, 16, 6),
                child: Stack(alignment: Alignment.center, children: [
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: _collapsed ? 1 : 0,
                    child: Text(widget.title, style: ts(F.headline, w: w6)),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      for (final a in widget.actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(widget.title, style: ts(F.largeTitle, w: w7)),
            ),
          ),
          if (widget.search != null)
            SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: widget.search)),
          ...widget.slivers,
          SliverToBoxAdapter(child: SizedBox(height: BottomInset.of(context))),
        ],
        ),
      ),
    );
  }
}

/// 推進來的頁面或底部頁面：上面一條導覽列，內容可捲動
class NavPage extends StatelessWidget {
  const NavPage({
    super.key,
    this.title,
    this.titleWidget,
    required this.slivers,
    this.actions = const [],
    this.close = false,
    this.leading,
    this.search,
    this.bottom,
    this.safeTop = true,
  });
  final String? title;
  final Widget? titleWidget;
  final List<Widget> slivers;
  final List<Widget> actions;
  final bool close, safeTop;
  final Widget? leading, search, bottom;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final top = safeTop ? MediaQuery.paddingOf(context).top : 0.0;
    final canPop = Navigator.of(context).canPop();
    return Material(
      color: p.bg,
      child: Column(children: [
        Container(
          color: p.bg,
          height: top + 56,
          padding: EdgeInsets.fromLTRB(16, top + 8, 16, 8),
          child: Stack(alignment: Alignment.center, children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 92),
              child: titleWidget ??
                  Text(title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.headline, w: w6)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: leading ??
                  (canPop
                      ? CircleBtn(
                          icon: close ? Icons.close_rounded : Icons.arrow_back_ios_new_rounded,
                          label: close ? '關閉' : '返回',
                          size: 40,
                          onTap: () => Navigator.of(context).maybePop(),
                        )
                      : const SizedBox.shrink()),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final a in actions) Padding(padding: const EdgeInsets.only(left: 8), child: a),
              ]),
            ),
          ]),
        ),
        Expanded(
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              if (search != null)
                SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 14), child: search)),
              ...slivers,
              SliverToBoxAdapter(child: SizedBox(height: bottom != null ? 12 : BottomInset.of(context))),
            ],
          ),
        ),
        ?bottom,
      ]),
    );
  }
}

/// 導覽列右上的文字按鈕（完成、取消）
class BarText extends StatelessWidget {
  const BarText(this.label, {super.key, this.onTap, this.bold = true});
  final String label;
  final VoidCallback? onTap;
  final bool bold;
  @override
  Widget build(BuildContext context) => Tap(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Text(label, style: ts(F.headline, w: bold ? w6 : null, c: Palette.of(context).accent)),
        ),
      );
}

Route<T> slideRoute<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, a, b, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: SlideTransition(
          position: Tween(begin: Offset.zero, end: const Offset(-.25, 0)).animate(CurvedAnimation(parent: b, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );

Future<T?> pushPage<T>(BuildContext c, Widget page) => Navigator.of(c).push<T>(slideRoute(page));

/// 全螢幕蓋上來（練習、考古題）
Future<T?> presentFull<T>(BuildContext c, Widget page) => Navigator.of(c, rootNavigator: true).push<T>(
      PageRouteBuilder<T>(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (ctx, _, _) => Material(color: Palette.of(ctx).bg, child: page),
        transitionsBuilder: (_, a, _, child) => SlideTransition(
          position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );

/// 底部頁面。height 沒給就是接近全螢幕
Future<T?> presentSheet<T>(BuildContext c, Widget Function(BuildContext) builder, {double? height}) {
  final media = MediaQuery.of(c);
  return showModalBottomSheet<T>(
    context: c,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Palette.of(c).bg,
    clipBehavior: Clip.antiAlias,
    constraints: const BoxConstraints(maxWidth: 640),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.section))),
    builder: (ctx) {
      final keyboard = MediaQuery.viewInsetsOf(ctx).bottom;
      final full = media.size.height - media.padding.top - 12;
      return Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(
          height: min(height == null ? full : height + media.padding.bottom, full - keyboard),
          child: MediaQuery.removePadding(context: ctx, removeTop: true, child: builder(ctx)),
        ),
      );
    },
  );
}

// MARK: 分組清單（iOS 的 insetGrouped）

/// 一個分組：可以直接給 children，或給 count + builder（幾千筆的字庫用這個才不會卡）
class Sec extends StatelessWidget {
  const Sec({super.key, this.header, this.footer, this.children, this.count, this.builder, this.headerWidget});
  final String? header, footer;
  final Widget? headerWidget;
  final List<Widget>? children;
  final int? count;
  final Widget Function(BuildContext, int)? builder;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = children?.length ?? count ?? 0;
    return SliverMainAxisGroup(slivers: [
      if (header != null || headerWidget != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 7),
            child: headerWidget ?? Text(header!, style: ts(F.foot, w: w5, c: p.sec)),
          ),
        ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.builder(
          itemCount: n,
          itemBuilder: (c, i) {
            const r = Radius.circular(Radii.section);
            return Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.vertical(top: i == 0 ? r : Radius.zero, bottom: i == n - 1 ? r : Radius.zero),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                children?[i] ?? builder!(c, i),
                if (i < n - 1) Padding(padding: const EdgeInsets.only(left: 16), child: Container(height: .5, color: p.separator)),
              ]),
            );
          },
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(32, footer != null ? 7 : 0, 32, 26),
          child: footer != null ? Text(footer!, style: ts(F.foot, c: p.sec)) : null,
        ),
      ),
    ]);
  }
}

/// 清單的一列：左圖示、標題＋副標、右側內容、箭頭
class RowTile extends StatelessWidget {
  const RowTile({
    super.key,
    this.leading,
    this.title,
    this.titleWidget,
    this.subtitle,
    this.trailing,
    this.value,
    this.chevron = false,
    this.onTap,
    this.titleColor,
    this.titleStyle,
    this.leadingWidth = 28,
    this.subtitleLines = 1,
  });
  final Widget? leading, titleWidget, trailing;
  final String? title, subtitle, value;
  final bool chevron;
  final VoidCallback? onTap;
  final Color? titleColor;
  final TextStyle? titleStyle;
  final double leadingWidth;
  final int subtitleLines;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 50),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(children: [
          if (leading != null) ...[
            SizedBox(width: leadingWidth, child: Center(child: leading)),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              titleWidget ??
                  Text(title ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle ?? ts(F.body, c: titleColor ?? p.ink)),
              if (subtitle != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!, maxLines: subtitleLines, overflow: TextOverflow.ellipsis, style: ts(F.cap, c: p.sec)),
                ),
            ]),
          ),
          if (value != null) ...[
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Text(value!, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.body, c: p.sec)),
            ),
          ],
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          if (chevron) ...[const SizedBox(width: 8), Icon(Icons.chevron_right_rounded, size: 20, color: p.ter)],
        ]),
      ),
    );
    return onTap == null ? row : Tap(onTap: onTap, dim: false, child: row);
  }
}

class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, required this.value, required this.onChanged, this.icon});
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => RowTile(
        title: title,
        leading: icon == null ? null : Icon(icon, size: 21, color: Palette.of(context).accent),
        trailing: Switch(value: value, onChanged: onChanged),
      );
}

class SwipeAction {
  const SwipeAction(this.label, this.icon, this.color, this.onTap);
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
}

/// 往左滑露出動作按鈕（刪除、喜歡）
class SwipeRow extends StatefulWidget {
  const SwipeRow({super.key, required this.actions, required this.child});
  final List<SwipeAction> actions;
  final Widget child;
  @override
  State<SwipeRow> createState() => _SwipeRowState();
}

class _SwipeRowState extends State<SwipeRow> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  double get _width => widget.actions.length * 78.0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragUpdate: (d) => _c.value -= d.primaryDelta! / _width,
      onHorizontalDragEnd: (d) {
        final open = d.primaryVelocity! < -200 || (d.primaryVelocity! < 200 && _c.value > .5);
        _c.animateTo(open ? 1 : 0, curve: Curves.easeOut);
      },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => Stack(children: [
          if (_c.value > 0)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: _width * _c.value,
                  child: Row(children: [
                    for (final a in widget.actions)
                      Expanded(
                        child: Tap(
                          dim: false,
                          onTap: () {
                            _c.value = 0;
                            a.onTap();
                          },
                          child: Container(
                            color: a.color,
                            child: OverflowBox(
                              maxWidth: 78,
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Icon(a.icon, color: Colors.white, size: 20),
                                const SizedBox(height: 3),
                                Text(a.label, maxLines: 1, style: ts(F.cap, w: w6, c: Colors.white)),
                              ]),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          Transform.translate(offset: Offset(-_width * _c.value, 0), child: child),
        ]),
        child: ColoredBox(color: Palette.of(context).card, child: widget.child),
      ),
    );
  }
}

class SearchBox extends StatelessWidget {
  const SearchBox({super.key, required this.controller, required this.hint, this.onChanged, this.onSubmit, this.focus});
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged, onSubmit;
  final FocusNode? focus;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(color: p.ink.withValues(alpha: p.dark ? .13 : .07), borderRadius: BorderRadius.circular(22)),
      child: Row(children: [
        Icon(Icons.search_rounded, size: 21, color: p.sec),
        const SizedBox(width: 6),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focus,
            onChanged: onChanged,
            onSubmitted: onSubmit,
            textInputAction: TextInputAction.search,
            autocorrect: false,
            enableSuggestions: false,
            style: ts(F.body, c: p.ink),
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: ts(F.body, c: p.sec),
            ),
          ),
        ),
        ListenableBuilder(
          listenable: controller,
          builder: (_, _) => controller.text.isEmpty
              ? const SizedBox(width: 8)
              : Tap(
                  label: '清除',
                  onTap: () {
                    controller.clear();
                    onChanged?.call('');
                  },
                  child: Padding(padding: const EdgeInsets.all(8), child: Icon(Icons.cancel_rounded, size: 18, color: p.sec)),
                ),
        ),
      ]),
    );
  }
}

/// iOS 的分段控制
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.items, required this.value, required this.onChanged});
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final index = items.indexWhere((e) => e.$1 == value);
    return Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(18)),
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth / items.length;
        return Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: w * max(0, index),
            top: 0,
            bottom: 0,
            width: w,
            child: Container(
              decoration: BoxDecoration(color: p.dark ? const Color(0xFF636366) : Colors.white, borderRadius: BorderRadius.circular(16)),
            ),
          ),
          Row(children: [
            for (final (v, label) in items)
              Expanded(
                child: Tap(
                  dim: false,
                  onTap: () => onChanged(v),
                  child: Center(child: Text(label, maxLines: 1, style: ts(13, w: v == value ? w6 : w5, c: p.ink))),
                ),
              ),
          ]),
        ]);
      }),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(this.title, {super.key, required this.icon, this.message});
  final String title;
  final IconData icon;
  final String? message;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 46, color: p.sec),
        const SizedBox(height: 12),
        Text(title, textAlign: TextAlign.center, style: ts(F.title3, w: w7)),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(message!, textAlign: TextAlign.center, style: ts(F.sub, c: p.sec)),
        ],
      ]),
    );
  }
}

// MARK: 選單與對話框

class MenuEntry {
  const MenuEntry(this.title, {this.subtitle, this.icon, this.checked = false, this.destructive = false, this.onTap});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool checked, destructive;
  final VoidCallback? onTap;
}

Color menuSurface(Palette p) => p.dark ? const Color(0xFF2C2C2E) : Colors.white;

/// 從按鈕的位置彈出選單。context 要是按鈕自己的
Future<void> showAppMenu(BuildContext context, List<MenuEntry> entries) async {
  final p = Palette.of(context);
  final box = context.findRenderObject() as RenderBox;
  final overlay = Navigator.of(context, rootNavigator: true).overlay!.context.findRenderObject() as RenderBox;
  final rect = Rect.fromPoints(
    box.localToGlobal(Offset(0, box.size.height + 6), ancestor: overlay),
    box.localToGlobal(box.size.bottomRight(const Offset(0, 6)), ancestor: overlay),
  );
  final i = await showMenu<int>(
    context: context,
    useRootNavigator: true,
    position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
    color: menuSurface(p),
    elevation: 8,
    constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
    items: [
      for (final (i, e) in entries.indexed)
        PopupMenuItem<int>(
          value: i,
          height: 46,
          child: Row(children: [
            SizedBox(width: 24, child: e.checked ? Icon(Icons.check_rounded, size: 18, color: p.ink) : null),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(e.title, style: ts(F.body, c: e.destructive ? p.destructive : p.ink)),
                if (e.subtitle != null) Text(e.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: ts(F.cap, c: p.sec)),
              ]),
            ),
            if (e.icon != null) Icon(e.icon, size: 19, color: e.destructive ? p.destructive : p.ink),
          ]),
        ),
    ],
  );
  if (i != null) entries[i].onTap?.call();
}

/// 點了會跳選單的元件
class MenuBtn extends StatelessWidget {
  const MenuBtn({super.key, required this.entries, required this.child, this.label});
  final List<MenuEntry> Function() entries;
  final Widget child;
  final String? label;
  @override
  Widget build(BuildContext context) =>
      Builder(builder: (c) => Tap(label: label, onTap: () => showAppMenu(c, entries()), child: child));
}

class AlertAction {
  const AlertAction(this.label, {this.onTap, this.destructive = false, this.bold = false});
  final String label;
  final VoidCallback? onTap;
  final bool destructive, bold;
}

Future<void> showAlert(BuildContext c, String title, {String? message, List<AlertAction> actions = const [AlertAction('好', bold: true)]}) {
  return showDialog(
    context: c,
    useRootNavigator: true,
    builder: (ctx) => _AlertBox(title: title, message: message, actions: actions),
  );
}

class _AlertBox extends StatelessWidget {
  const _AlertBox({required this.title, this.message, required this.actions});
  final String title;
  final String? message;
  final List<AlertAction> actions;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Dialog(
      backgroundColor: menuSurface(p),
      insetPadding: const EdgeInsets.symmetric(horizontal: 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.section)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, textAlign: TextAlign.center, style: ts(F.headline, w: w6)),
          if (message != null) ...[
            const SizedBox(height: 6),
            Flexible(child: SingleChildScrollView(child: Text(message!, textAlign: TextAlign.center, style: ts(F.foot + 1, c: p.sec)))),
          ],
          const SizedBox(height: 16),
          Row(children: [
            for (final (i, a) in actions.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: PillButton(
                  label: a.label,
                  height: 44,
                  fill: a.bold ? p.accent : null,
                  fg: a.destructive ? p.destructive : (a.bold ? p.onAccent : p.ink),
                  onTap: () {
                    Navigator.of(context).pop();
                    a.onTap?.call();
                  },
                ),
              ),
            ],
          ]),
        ]),
      ),
    );
  }
}

/// 確認動作：底部的確認面板（iOS 的 confirmationDialog）
Future<void> confirmAction(BuildContext c, String title,
    {String? message, required String label, required VoidCallback onConfirm, bool destructive = true}) {
  final p = Palette.of(c);
  return showModalBottomSheet(
    context: c,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: menuSurface(p), borderRadius: BorderRadius.circular(Radii.section)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, textAlign: TextAlign.center, style: ts(F.headline, w: w6, c: p.ink)),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message, textAlign: TextAlign.center, style: ts(F.foot + 1, c: p.sec)),
          ],
          const SizedBox(height: 16),
          PillButton(
            label: label,
            fg: destructive ? Colors.white : p.onAccent,
            fill: destructive ? p.destructive : p.accent,
            onTap: () {
              Navigator.of(ctx).pop();
              onConfirm();
            },
          ),
          const SizedBox(height: 8),
          PillButton(label: '取消', onTap: () => Navigator.of(ctx).pop()),
        ]),
      ),
    ),
  );
}

/// 輸入一行文字（建立清單）
Future<void> promptText(BuildContext c, String title,
    {required String hint, required String confirm, required bool Function(String) valid, required ValueChanged<String> onDone}) {
  return showDialog(
    context: c,
    useRootNavigator: true,
    builder: (_) => _PromptBox(title: title, hint: hint, confirm: confirm, valid: valid, onDone: onDone),
  );
}

class _PromptBox extends StatefulWidget {
  const _PromptBox({required this.title, required this.hint, required this.confirm, required this.valid, required this.onDone});
  final String title, hint, confirm;
  final bool Function(String) valid;
  final ValueChanged<String> onDone;
  @override
  State<_PromptBox> createState() => _PromptBoxState();
}

class _PromptBoxState extends State<_PromptBox> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final ok = widget.valid(_c.text);
    return Dialog(
      backgroundColor: menuSurface(p),
      insetPadding: const EdgeInsets.symmetric(horizontal: 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.section)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.title, style: ts(F.headline, w: w6)),
          const SizedBox(height: 14),
          TextField(
            controller: _c,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            style: ts(F.body, c: p.ink),
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: ts(F.body, c: p.sec),
              filled: true,
              fillColor: p.fill,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: PillButton(label: '取消', height: 44, onTap: () => Navigator.of(context).pop())),
            const SizedBox(width: 8),
            Expanded(
              child: PillButton(
                label: widget.confirm,
                height: 44,
                fill: p.accent,
                fg: p.onAccent,
                onTap: ok
                    ? () {
                        Navigator.of(context).pop();
                        widget.onDone(_c.text.trim());
                      }
                    : null,
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// MARK: 單字相關的小元件

final _punct = RegExp(r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$', unicode: true);
String stripPunct(String s) => s.replaceAll(_punct, '');

/// 例句：每個英文字都能點來查，單字本身用實線加粗標出
class TappableSentence extends StatefulWidget {
  const TappableSentence({super.key, required this.sentence, this.highlight = '', this.style, required this.onTap});
  final String sentence, highlight;
  final TextStyle? style;
  final ValueChanged<String> onTap;
  @override
  State<TappableSentence> createState() => _TappableSentenceState();
}

class _TappableSentenceState extends State<TappableSentence> {
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

  /// 哪幾個詞是單字本身（"keep the project alive" 標 keep 和 alive，不標 the project）
  Set<int> _keys(List<String> tokens) {
    final re = widget.highlight.isEmpty ? null : WordMatch.pattern(widget.highlight);
    final m = re?.firstMatch(widget.sentence);
    if (m == null) return const {};
    final gaps = <(int, int)>[];
    var from = m.start;
    for (var g = 1; g <= m.groupCount; g++) {
      final text = m[g];
      if (text == null) continue;
      final at = widget.sentence.indexOf(text, from);
      if (at >= 0) {
        gaps.add((at, at + text.length));
        from = at + text.length;
      }
    }
    final keys = <int>{};
    var at = 0;
    for (final (i, t) in tokens.indexed) {
      final s = widget.sentence.indexOf(t, at);
      final e = s + t.length;
      at = e;
      if (s < m.end && e > m.start && !gaps.any((g) => s < g.$2 && e > g.$1)) keys.add(i);
    }
    return keys;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final p = Palette.of(context);
    final base = widget.style ?? ts(F.title3, w: w6);
    final tokens = widget.sentence.split(' ').where((s) => s.isNotEmpty).toList();
    final keys = _keys(tokens);
    final spans = <InlineSpan>[];
    for (final (i, t) in tokens.indexed) {
      if (i > 0) spans.add(const TextSpan(text: ' '));
      final word = stripPunct(t);
      final key = keys.contains(i);
      TapGestureRecognizer? r;
      if (word.isNotEmpty) {
        r = TapGestureRecognizer()..onTap = () => widget.onTap(word);
        _recognizers.add(r);
      }
      spans.add(TextSpan(
        text: t,
        recognizer: r,
        style: TextStyle(
          color: p.accent,
          fontWeight: key ? w7 : null,
          decoration: TextDecoration.underline,
          decorationStyle: key ? TextDecorationStyle.solid : TextDecorationStyle.dotted,
          decorationColor: p.accent.withValues(alpha: key ? .9 : .35),
        ),
      ));
    }
    return Text.rich(TextSpan(style: base.copyWith(height: 1.35), children: spans));
  }
}

class SpeakButton extends StatelessWidget {
  const SpeakButton(this.text, {super.key, this.size = 18});
  final String text;
  final double size;
  @override
  Widget build(BuildContext context) => Tap(
        label: '念出來',
        onTap: () => Speech.say(text),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(Icons.volume_up_rounded, size: size, color: Palette.of(context).accent),
        ),
      );
}

class DetailTag extends StatelessWidget {
  const DetailTag(this.text, {super.key, this.filled = false});
  final String text;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? p.accent : p.accent.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Text(text, style: ts(F.cap, w: w7, c: filled ? p.onAccent : p.accent)),
    );
  }
}

/// 例句區塊：淡底加左邊一條主題色
class QuoteBlock extends StatelessWidget {
  const QuoteBlock({super.key, required this.child, this.color});
  final Widget child;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Palette.of(context).accent;
    return Stack(children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: c.withValues(alpha: .06), borderRadius: BorderRadius.circular(Radii.md)),
        child: child,
      ),
      Positioned(left: 0, top: 8, bottom: 8, width: 3, child: ColoredBox(color: c)),
    ]);
  }
}

class Toast extends StatelessWidget {
  const Toast({super.key, required this.text, required this.onClose});
  final String text;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: menuSurface(p),
        borderRadius: BorderRadius.circular(Radii.lg),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 18, offset: Offset(0, 4))],
      ),
      child: Row(children: [
        Icon(Icons.check_circle_rounded, size: 21, color: p.knowInk),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: ts(F.sub, w: w7, c: p.accent))),
        Tap(label: '關閉', onTap: onClose, child: Icon(Icons.close_rounded, size: 19, color: p.ink)),
      ]),
    );
  }
}

class Ring extends CustomPainter {
  Ring({required this.track, required this.parts, required this.width, this.round = false});
  final Color track;

  /// (比例, 顏色)，從 12 點鐘方向接著畫
  final List<(double, Color)> parts;
  final double width;
  final bool round;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    canvas.drawArc(rect, 0, 2 * pi, false, paint..color = track);
    var start = -pi / 2;
    paint.strokeCap = round ? StrokeCap.round : StrokeCap.butt;
    for (final (v, c) in parts) {
      if (v <= 0) continue;
      canvas.drawArc(rect, start, v * 2 * pi, false, paint..color = c);
      start += v * 2 * pi;
    }
  }

  @override
  bool shouldRepaint(Ring old) => true;
}

/// 一輪結束的成績環
class ScoreRing extends StatelessWidget {
  const ScoreRing({super.key, required this.good, required this.unsure, required this.again});
  final int good, unsure, again;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final total = max(1, good + unsure + again);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOut,
      builder: (_, t, child) => CustomPaint(
        painter: Ring(track: p.sec.withValues(alpha: .12), width: 16, parts: [
          (good / total * t, p.green),
          (unsure / total * t, p.orange),
          (again / total * t, p.accent),
        ]),
        child: child,
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${(good / total * 100).round()}%', style: ts(40, w: w7)),
          Text('一次就會', style: ts(F.cap, w: w6, c: p.sec)),
        ]),
      ),
    );
  }
}

/// 六階：未學到精通，柱子高度是每階的字數
class MasteryLadder extends StatelessWidget {
  const MasteryLadder({super.key, required this.distribution});
  final List<int> distribution;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final top = max(1, distribution.reduce(max));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('熟練階梯', style: ts(F.headline, w: w7))),
        Tap(
          label: '說明',
          onTap: () => showAlert(context, '熟練階梯',
              message: '答「會」往上爬一階，答「不會」退一階。\n初見 翻卡片 → 認得 英翻中 → 熟悉 中翻英 → 穩固 克漏字 → 精通 拼單字。\n爬到精通並再答對一次，就算真正學會。'),
          child: Icon(Icons.help_outline_rounded, size: 21, color: p.sec),
        ),
      ]),
      const SizedBox(height: 14),
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < 6; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${distribution[i]}', style: ts(F.cap, w: w7)),
              const SizedBox(height: 6),
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: 8 + 62 * distribution[i] / top,
                decoration: BoxDecoration(
                  color: i == 0 ? p.sec.withValues(alpha: .18) : p.accent.withValues(alpha: .25 + i * .15),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
              ),
              const SizedBox(height: 6),
              Text(levelNames[i], style: ts(F.cap2, w: w6, c: p.sec)),
            ]),
          ),
        ],
      ]),
    ]);
  }
}

/// 勳章本體：外圈的金屬隨等級升級（銅、銀、金、白金、鑽石），中間是主題色和浮起來的圖示；點一下會翻一圈
class MedalCoin extends StatefulWidget {
  const MedalCoin({super.key, required this.tier, required this.icon, this.size = 64});
  final int tier;
  final IconData icon;
  final double size;

  static (Color, Color, Color) metal(int tier) {
    const m = [
      (0xFFF2C29A, 0xFFC27C47, 0xFF7A4421), // 銅
      (0xFFFFFFFF, 0xFFC3C9CF, 0xFF767E87), // 銀
      (0xFFFFF0A8, 0xFFDDAE34, 0xFF8E6610), // 金
      (0xFFF2FAFF, 0xFFAFCBD8, 0xFF5F7D8B), // 白金
      (0xFFF1E7FF, 0xFFB59DEE, 0xFF5A45A3), // 鑽石
    ];
    final t = m[tier.clamp(1, m.length) - 1];
    return (Color(t.$1), Color(t.$2), Color(t.$3));
  }

  @override
  State<MedalCoin> createState() => _MedalCoinState();
}

class _MedalCoinState extends State<MedalCoin> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Widget _circle(double inset, Decoration d, {Widget? child}) => Positioned.fill(
        child: Padding(
          padding: EdgeInsets.all(inset),
          child: DecoratedBox(decoration: d, child: child),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final size = widget.size, earned = widget.tier > 0;
    final (light, mid, dark) = MedalCoin.metal(widget.tier);
    final coin = SizedBox(
      width: size,
      height: size,
      child: earned
          ? Stack(children: [
              // 外圈：拉絲金屬，兩處反光
              _circle(0, BoxDecoration(
                shape: BoxShape.circle,
                gradient: SweepGradient(colors: [light, mid, dark, mid, light, mid, dark, mid, light]),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .25), blurRadius: size * .1, offset: Offset(0, size * .04))],
              )),
              _circle(size * .085, BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [dark, light]),
              )),
              _circle(size * .105, BoxDecoration(shape: BoxShape.circle, color: p.accent)),
              _circle(size * .105, BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.white.withValues(alpha: .34), Colors.transparent, Colors.black.withValues(alpha: .24)],
                ),
              )),
              _circle(size * .16, BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: light.withValues(alpha: .65), width: max(1, size * .018)),
              )),
              Center(
                child: ShaderMask(
                  shaderCallback: (r) => LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white, light]).createShader(r),
                  child: Icon(widget.icon, size: size * .36, color: Colors.white, shadows: [
                    Shadow(color: Colors.black.withValues(alpha: .35), offset: Offset(0, size * .02), blurRadius: 1),
                  ]),
                ),
              ),
              // 上方一道柔和的反光
              Positioned(
                left: size * .17,
                right: size * .17,
                top: size * .1,
                height: size * .36,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.elliptical(size * .33, size * .18)),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white.withValues(alpha: .42), Colors.white.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ])
          : Stack(children: [
              _circle(0, BoxDecoration(shape: BoxShape.circle, color: p.sec.withValues(alpha: .12))),
              _circle(size * .1, BoxDecoration(shape: BoxShape.circle, border: Border.all(color: p.sec.withValues(alpha: .3), width: 1.5))),
              Center(child: Icon(widget.icon, size: size * .36, color: p.sec.withValues(alpha: .55))),
            ]),
    );
    if (!earned) return coin;
    return GestureDetector(
      onTap: () => _spin.forward(from: 0),
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, child) => Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, .002)
            ..rotateY(Curves.easeOutBack.transform(_spin.value) * 2 * pi),
          child: child,
        ),
        child: coin,
      ),
    );
  }
}

class BadgeMedal extends StatelessWidget {
  const BadgeMedal({super.key, required this.kind, required this.value, this.size = 64});
  final BadgeKind kind;
  final int value;
  final double size;

  static const _icons = {
    'streak': Icons.local_fire_department_rounded,
    'imported': Icons.download_rounded,
    'learned': Icons.menu_book_rounded,
    'mastered': Icons.verified_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final tier = kind.earned(value), earned = tier > 0;
    return Semantics(
      label: '${kind.title}，${earned ? '第 $tier 級（共 ${kind.tiers.length} 級）' : '還沒達成'}，$value / ${kind.next(value)}',
      child: ExcludeSemantics(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: size,
            height: size,
            child: MedalCoin(tier: tier, icon: _icons[kind.id]!, size: size),
          ),
          const SizedBox(height: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < kind.tiers.length; i++)
              Container(
                width: 8,
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: i < tier ? MedalCoin.metal(i + 1).$2 : p.sec.withValues(alpha: .25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ]),
          const SizedBox(height: 6),
          Text(kind.title, style: ts(F.cap2, w: w6, c: p.sec)),
          const SizedBox(height: 2),
          Text('$value / ${kind.next(value)}', style: ts(F.cap, w: w7)),
        ]),
      ),
    );
  }
}

/// 選主題色：紙張顏色的小方塊，下面一條主色寫著名字（和 BanGo 一樣）；名字用紙張色，深色模式也看得清楚
class ThemeGrid extends StatelessWidget {
  const ThemeGrid({super.key, required this.selection, required this.onSelect});
  final String selection;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LayoutBuilder(builder: (context, c) {
      final w = (c.maxWidth - 20) / 3;
      return Wrap(spacing: 10, runSpacing: 10, children: [
        for (final t in AppTheme.all)
          Tap(
            label: t.name,
            onTap: () => onSelect(t.id),
            child: Container(
              width: w,
              height: 76,
              clipBehavior: Clip.antiAlias,
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.md),
                border: selection == t.id ? Border.all(color: p.ink, width: 2) : null,
              ),
              decoration: BoxDecoration(color: t.swatch, borderRadius: BorderRadius.circular(Radii.md)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                    child: Text('Aa', style: ts(F.title3, w: w7, c: t.base)),
                  ),
                ),
                Container(
                  height: 28,
                  color: t.base,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    Expanded(child: Text(t.name, maxLines: 1, style: ts(F.cap, w: w7, c: t.swatch))),
                    if (selection == t.id) Icon(Icons.check_rounded, size: 14, color: t.swatch),
                  ]),
                ),
              ]),
            ),
          ),
      ]);
    });
  }
}

/// 兩欄（或多欄）等寬格子
class StackGrid extends StatelessWidget {
  const StackGrid({super.key, required this.children, this.columns = 2, this.spacing = 10});
  final List<Widget> children;
  final int columns;
  final double spacing;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(spacing: spacing, runSpacing: spacing, children: [
          for (final child in children) SizedBox(width: w, child: child),
        ]);
      });
}

/// 自動縮小才放得下的單行大字（iOS 的 minimumScaleFactor）
class FitText extends StatelessWidget {
  const FitText(this.text, {super.key, required this.style, this.alignment = Alignment.centerLeft});
  final String text;
  final TextStyle style;
  final Alignment alignment;
  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: Text(text, maxLines: 1, style: style),
      );
}
