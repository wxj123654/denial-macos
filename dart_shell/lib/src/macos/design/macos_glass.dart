import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'liquid_glass.dart';
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
  const MacosGlassScope({
    super.key,
    required this.frost,
    this.refractive = false,
    required super.child,
  });

  final double frost;
  final bool refractive;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MacosGlassScope>()?.frost ??
      0.5;

  static bool refractiveOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MacosGlassScope>()
          ?.refractive ??
      false;

  @override
  bool updateShouldNotify(MacosGlassScope old) =>
      frost != old.frost || refractive != old.refractive;
}

class _InsideGlass extends InheritedWidget {
  const _InsideGlass({required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_InsideGlass>() != null;

  @override
  bool updateShouldNotify(_InsideGlass old) => false;
}

/// Liquid Glass uses the refractive shader when enabled by [MacosGlassScope].
/// Backdrop blur, adaptive tint and a specular rim remain the portable fallback.
/// Both paths preserve the same geometry and soft contact shadow.
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
    this.refractive,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final MacosGlassVariant variant;

  /// Optional colored tint (for prominent controls); blended over the fill.
  final Color? tint;
  final double blurSigma;
  final bool elevated;
  final EdgeInsetsGeometry? padding;
  final bool? refractive;

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
    final useRefraction = refractive ?? MacosGlassScope.refractiveOf(context);
    if (useRefraction &&
        frost < 0.999 &&
        borderRadius == BorderRadius.circular(borderRadius.topLeft.x)) {
      final materialFrost = variant == MacosGlassVariant.regular
          ? frost
          : frost * 0.5;
      final glassAlpha = math.max(
        tint?.a ?? 0,
        ui.lerpDouble(fill.a * 0.25, 0.95, materialFrost * materialFrost)!,
      );
      final frosted = surface;
      surface = LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          // The shader shape must stay off the layer's coverage boundary:
          // the GLES negative-render-view pipeline can place the composited
          // backdrop a couple of device pixels off the clip, flattening
          // corners that touch the boundary (see AGENTS.md).
          final slack = math.min(3.0, size.shortestSide / 6);
          final shape = (Offset.zero & size).deflate(slack);
          final roundness = (borderRadius.topLeft.x / (shape.shortestSide / 2))
              .clamp(0.0, 1.0);
          return LiquidGlassBlend(
            shapes: [shape],
            roundness: roundness,
            optics: LiquidGlassOptics(
              tint: base.withValues(alpha: glassAlpha),
              blurSigma: nested ? 0 : math.min(blurSigma, 12) * materialFrost,
            ),
            fallback: frosted,
            child: content,
          );
        },
      );
    }
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
