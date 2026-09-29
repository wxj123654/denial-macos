import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'macos_design_tokens.dart';

enum MacosGlassVariant {
  /// Default: blurred, tinted, legible over any content.
  regular,

  /// More transparent, for media-rich backgrounds.
  clear,
}

/// System-wide Liquid Glass level, as in macOS 27: 0 is clear glass, 1 is a
/// fully frosted, opaque material. Frosting also removes the live blur, which
/// is the expensive part.
class MacosGlassScope extends InheritedWidget {
  const MacosGlassScope({super.key, required this.frost, required super.child});

  final double frost;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MacosGlassScope>()?.frost ??
      0.5;

  @override
  bool updateShouldNotify(MacosGlassScope old) => frost != old.frost;
}

class _InsideGlass extends InheritedWidget {
  const _InsideGlass({required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InsideGlass>() != null;

  @override
  bool updateShouldNotify(_InsideGlass old) => false;
}

/// Portable approximation of Liquid Glass: backdrop blur, adaptive tint, a specular rim lit from the top-left, and a soft
/// contact shadow. The engine's refractive glass can replace this body later
/// without changing call sites.
class MacosGlass extends StatelessWidget {
  const MacosGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.variant = MacosGlassVariant.regular,
    this.tint,
    this.blurSigma = 22,
    this.elevated = true,
    this.padding,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final MacosGlassVariant variant;

  /// Optional colored tint (for prominent controls); blended over the fill.
  final Color? tint;
  final double blurSigma;
  final bool elevated;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    final frost = MacosGlassScope.of(context).clamp(0.0, 1.0);
    final nested = _InsideGlass.of(context);
    final fill = variant == MacosGlassVariant.regular
        ? palette.glassFill
        : palette.glassClearFill;
    final base = tint == null ? fill : Color.alphaBlend(tint!, fill);
    final blurred = !nested && frost < 0.999;
    final double alpha = blurred
        ? ui.lerpDouble(base.a, 0.9, frost)!
        : ui.lerpDouble(0.5, 0.95, frost)!.clamp(base.a, 1.0);
    final tinted = base.withValues(alpha: alpha);
    final sigma =
        (variant == MacosGlassVariant.regular ? blurSigma : blurSigma * 0.5) *
        (1 - frost);
    final content = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    Widget surface = CustomPaint(
      foregroundPainter: _RimPainter(
        borderRadius: borderRadius,
        color: palette.glassRim,
        strong: !palette.isDark,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tinted,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              const Color(
                0xffffffff,
              ).withValues(alpha: palette.isDark ? 0.07 : 0.22),
              const Color(0x00ffffff),
            ],
            stops: const <double>[0, 0.6],
          ),
        ),
        child: content,
      ),
    );
    surface = ClipRRect(
      borderRadius: borderRadius,
      child: blurred
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: TileMode.clamp,
              ),
              child: surface,
            )
          : surface,
    );
    return _InsideGlass(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: elevated
              ? <BoxShadow>[
                  BoxShadow(
                    color: palette.glassShadow,
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: surface,
      ),
    );
  }
}

class _RimPainter extends CustomPainter {
  const _RimPainter({
    required this.borderRadius,
    required this.color,
    required this.strong,
  });

  final BorderRadius borderRadius;
  final Color color;
  final bool strong;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    final rrect = borderRadius.toRRect(rect);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          color.withValues(alpha: strong ? 0.95 : 0.55),
          color.withValues(alpha: 0.04),
          color.withValues(alpha: 0.04),
          color.withValues(alpha: strong ? 0.6 : 0.28),
        ],
        stops: const <double>[0, 0.35, 0.65, 1],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_RimPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.color != color ||
      oldDelegate.strong != strong;
}
