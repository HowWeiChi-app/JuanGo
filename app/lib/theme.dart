// 顏色、圓角和字級：數值都照 iOS 版（Core.swift）。
// iOS 用的 HSB 就是 Flutter 的 HSV，所以主題底色的算法可以直接搬過來。

import 'package:material_ui/material_ui.dart';

import 'settings.dart';

class Radii {
  static const double sm = 8, md = 11, lg = 18;

  /// 清單分組的圓角（iOS 26 的 insetGrouped）
  static const double section = 26;
}

/// iOS 的文字樣式對應的字級
class F {
  static const double largeTitle = 34, title = 28, title2 = 22, title3 = 20;
  static const double headline = 17, body = 17, callout = 16, sub = 15;
  static const double foot = 13, cap = 12, cap2 = 11;
}

const w5 = FontWeight.w500, w6 = FontWeight.w600, w7 = FontWeight.w700;

/// 每段文字都帶繁體中文語系，Android 才會選到台灣字形（不然「骨」「直」會是簡中寫法）
TextStyle ts(double size, {FontWeight? w, Color? c, double? h, bool mono = false}) => TextStyle(
      fontSize: size,
      fontWeight: w,
      color: c,
      height: h,
      locale: const Locale('zh', 'TW'),
      fontFamily: mono ? 'monospace' : AppSettings.shared.fontFamily,
    );

class AppTheme {
  const AppTheme(this.id, this.name, this.accentHex, this.bgHex);
  final String id, name;
  final int accentHex, bgHex;

  static const all = [
    AppTheme('phoenix', '鳳凰紅', 0xA3162E, 0xF8F2EA),
    AppTheme('amber', '琥珀', 0xB0661A, 0xF9F1E3),
    AppTheme('pine', '松針', 0x2F6B4F, 0xF1F3EA),
    AppTheme('ink', '墨藍', 0x24407A, 0xF1F1F0),
    AppTheme('plum', '梅子', 0x7A2C5C, 0xF7EFF0),
    AppTheme('graphite', '石墨', 0x3B3A38, 0xF4F2EE),
    AppTheme('action', '天空藍', 0x0066CC, 0xF5F5F7),
  ];

  Color get base => hex(accentHex);
  Color get swatch => hex(bgHex);

  /// 深色模式把主色往白色混 38%，在深底上才看得清楚
  Color accent(bool dark) => dark ? Color.lerp(base, Colors.white, 0.38)! : base;

  /// 同色相、指定飽和度與亮度。灰色主題（石墨）的飽和度會跟著變低，維持中性灰
  Color _tone(double s, double b) {
    final h = HSVColor.fromColor(base);
    final k = (h.saturation / 0.6).clamp(0.0, 1.0);
    return HSVColor.fromAHSV(1, h.hue, s * k, b).toColor();
  }

  Color background(bool dark) => dark ? _tone(0.30, 0.20) : _tone(0.07, 0.975);
  Color section(bool dark) => dark ? _tone(0.30, 0.135) : _tone(0.13, 0.915);
}

Color hex(int v) => Color(0xFF000000 | v);
Color _rgb(double r, double g, double b) => Color.from(alpha: 1, red: r, green: g, blue: b);

/// 目前主題和深淺色下的所有顏色
class Palette {
  Palette._(AppTheme t, this.dark)
      : accent = t.accent(dark),
        bg = t.background(dark),
        card = t.section(dark),
        onAccent = dark ? const Color(0xFF141414) : Colors.white,
        ink = dark ? Colors.white : Colors.black,
        sec = dark ? const Color(0x99EBEBF5) : const Color(0x993C3C43),
        ter = dark ? const Color(0x4DEBEBF5) : const Color(0x4D3C3C43),
        fill = dark ? const Color(0x3D767680) : const Color(0x1F767680),
        separator = dark ? const Color(0x2EFFFFFF) : const Color(0x1F000000),
        knowGreen = dark ? _rgb(.17, .33, .25) : _rgb(.84, .92, .86),
        unsureYellow = dark ? _rgb(.38, .29, .13) : _rgb(.98, .90, .74),
        knowInk = dark ? _rgb(.72, .92, .78) : _rgb(.10, .40, .22),
        unsureInk = dark ? _rgb(.98, .86, .62) : _rgb(.50, .33, .02),
        againInk = dark ? _rgb(.99, .78, .78) : _rgb(.66, .10, .16),
        againPink = dark ? _rgb(.40, .16, .18) : _rgb(.97, .85, .84),
        // 附中的紫紅、天藍，加上制服的深藍（只用顏色，不用校徽）
        hsnuMagenta = hex(dark ? 0xF4A3C8 : 0x9C1D5B),
        hsnuMagentaFill = hex(dark ? 0x4A1A33 : 0xF8E1EB),
        hsnuSky = hex(dark ? 0x9DD4F7 : 0x0D659F),
        hsnuSkyFill = hex(dark ? 0x173F5B : 0xDDEFFB),
        hsnuNavy = hex(dark ? 0xC9D6EE : 0x1E3460),
        green = (dark ? const Color(0xFF30D158) : const Color(0xFF34C759)).withValues(alpha: .75),
        orange = dark ? const Color(0xFFFF9F0A) : const Color(0xFFFF9500),
        destructive = dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);

  final bool dark;
  final Color accent, bg, card, onAccent, ink, sec, ter, fill, separator;
  final Color knowGreen, unsureYellow, knowInk, unsureInk, againInk, againPink;
  final Color hsnuMagenta, hsnuMagentaFill, hsnuSky, hsnuSkyFill, hsnuNavy;
  final Color green, orange, destructive;

  static final _cache = <String, Palette>{};

  /// 呼叫 Theme.of 讓畫面在換主題、換深淺色時自動重畫
  static Palette of(BuildContext context) => forTheme(
        AppSettings.shared.theme,
        Theme.of(context).brightness == Brightness.dark,
      );

  static Palette forTheme(AppTheme t, bool dark) =>
      _cache.putIfAbsent('${t.id}|$dark', () => Palette._(t, dark));
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final p = Palette.forTheme(AppSettings.shared.theme, dark);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: AppSettings.shared.fontFamily,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      primary: p.accent,
      onPrimary: p.onAccent,
      surface: p.bg,
      onSurface: p.ink,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: .25),
      selectionHandleColor: p.accent,
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.fill),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.accent,
      thumbColor: p.accent,
      inactiveTrackColor: p.fill,
      overlayShape: SliderComponentShape.noOverlay,
    ),
  );
}
