import 'package:flutter/widgets.dart';

/// Design tokens approximating the macOS 26 (Tahoe) "Liquid Glass" language.
///
/// Values are engineering approximations of Apple's published guidance, not
/// Apple-supplied constants. See `docs/MACOS_DESIGN.md` for provenance.
abstract final class MacosSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii. Nested shapes must be concentric: inner = outer - inset.
abstract final class MacosRadii {
  static const double window = 26;
  static const double sidebar = 18;
  static const double card = 18;
  static const double popover = 20;
  static const double dock = 26;
  static const double notification = 22;
  static const double field = 10;

  /// Concentric inner radius for a child inset by [inset] inside [outer].
  static double concentric(double outer, double inset) =>
      (outer - inset).clamp(0, outer).toDouble();
}

/// Control heights on macOS 26; controls are taller and more capsule-like.
abstract final class MacosControlSize {
  static const double mini = 20;
  static const double small = 24;
  static const double regular = 28;
  static const double large = 32;
  static const double extraLarge = 40;
}

abstract final class MacosMotion {
  static const Duration quick = Duration(milliseconds: 140);
  static const Duration standard = Duration(milliseconds: 240);
  static const Duration morph = Duration(milliseconds: 420);
  static const Curve spring = Curves.easeOutCubic;
}

/// Type scale for macOS (SF Pro on Apple platforms). Linux hosts fall back to
/// the shell font stack.
abstract final class MacosType {
  static const List<String> fallback = <String>[
    'Inter',
    'Source Han Sans CN',
    'Noto Sans CJK SC',
  ];

  static TextStyle _style(double size, FontWeight weight, double height) =>
      TextStyle(
        fontFamilyFallback: fallback,
        fontSize: size,
        fontWeight: weight,
        height: height / size,
        decoration: TextDecoration.none,
      );

  static final TextStyle largeTitle = _style(26, FontWeight.w700, 32);
  static final TextStyle title1 = _style(22, FontWeight.w700, 26);
  static final TextStyle title2 = _style(17, FontWeight.w700, 22);
  static final TextStyle title3 = _style(15, FontWeight.w600, 20);
  static final TextStyle headline = _style(13, FontWeight.w700, 16);
  static final TextStyle body = _style(13, FontWeight.w400, 16);
  static final TextStyle callout = _style(12, FontWeight.w400, 15);
  static final TextStyle subheadline = _style(11, FontWeight.w400, 14);
  static final TextStyle footnote = _style(10, FontWeight.w400, 13);
}

/// System accent colors (iOS/macOS 26 light-mode values, slightly brighter
/// than the previous generation).
abstract final class MacosSystemColors {
  static const Color red = Color(0xffff383c);
  static const Color orange = Color(0xffff8d28);
  static const Color yellow = Color(0xffffcc00);
  static const Color green = Color(0xff34c759);
  static const Color mint = Color(0xff00c8b3);
  static const Color blue = Color(0xff0088ff);
  static const Color indigo = Color(0xff6155f5);
  static const Color purple = Color(0xffcb30e0);
  static const Color pink = Color(0xffff2d55);

  static const List<Color> all = <Color>[
    red,
    orange,
    yellow,
    green,
    mint,
    blue,
    indigo,
    purple,
    pink,
  ];
}

/// Appearance-dependent semantic colors.
@immutable
class MacosPalette {
  const MacosPalette._({
    required this.brightness,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.contentBackground,
    required this.controlFill,
    required this.controlFillPressed,
    required this.glassFill,
    required this.glassClearFill,
    required this.glassRim,
    required this.glassShadow,
    required this.accent,
  });

  static const MacosPalette light = MacosPalette._(
    brightness: Brightness.light,
    label: Color(0xdd000000),
    secondaryLabel: Color(0x80000000),
    tertiaryLabel: Color(0x4d000000),
    separator: Color(0x1a000000),
    contentBackground: Color(0xf2ffffff),
    controlFill: Color(0x14000000),
    controlFillPressed: Color(0x26000000),
    glassFill: Color(0x59ffffff),
    glassClearFill: Color(0x1affffff),
    glassRim: Color(0xffffffff),
    glassShadow: Color(0x24000000),
    accent: MacosSystemColors.blue,
  );

  static const MacosPalette dark = MacosPalette._(
    brightness: Brightness.dark,
    label: Color(0xf2ffffff),
    secondaryLabel: Color(0x99ffffff),
    tertiaryLabel: Color(0x59ffffff),
    separator: Color(0x1fffffff),
    contentBackground: Color(0xf21c1c1e),
    controlFill: Color(0x1fffffff),
    controlFillPressed: Color(0x33ffffff),
    glassFill: Color(0x33202024),
    glassClearFill: Color(0x14ffffff),
    glassRim: Color(0xffffffff),
    glassShadow: Color(0x66000000),
    accent: Color(0xff0091ff),
  );

  final Brightness brightness;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color separator;
  final Color contentBackground;
  final Color controlFill;
  final Color controlFillPressed;

  /// Tint for the "regular" Liquid Glass variant.
  final Color glassFill;

  /// Tint for the "clear" variant, used over media-rich content.
  final Color glassClearFill;
  final Color glassRim;
  final Color glassShadow;
  final Color accent;

  bool get isDark => brightness == Brightness.dark;
}

class MacosPaletteScope extends InheritedWidget {
  const MacosPaletteScope({
    super.key,
    required this.palette,
    required super.child,
  });

  final MacosPalette palette;

  static MacosPalette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MacosPaletteScope>()!.palette;

  @override
  bool updateShouldNotify(MacosPaletteScope oldWidget) =>
      palette != oldWidget.palette;
}
