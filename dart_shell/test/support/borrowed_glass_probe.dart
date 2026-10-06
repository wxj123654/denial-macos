// Standalone synthetic offscreen scene for the negative render-view embedder probe.
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:denial_dart_shell/liquid_glass_lab.dart';
import 'package:denial_dart_shell/src/macos/design/macos_design_tokens.dart';
import 'package:denial_dart_shell/src/macos/design/macos_glass.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassPrograms.ensureLoaded();
  if (LiquidGlassPrograms.failure != null) throw LiquidGlassPrograms.failure!;
  final small = Platform.environment['PROBE_SMALL_GLASS'] == 'true';
  if (small) {
    runApp(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MacosPaletteScope(
          palette: MacosPalette.light,
          child: MacosGlassScope(
            frost: 0.5,
            refractive: true,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: Color(0xfff0f0f0)),
                ),
                // Keep in sync with the small numeric oracle in main.rs.
                for (final rect in const [
                  Rect.fromLTWH(480, 420, 36, 24),
                  Rect.fromLTWH(560, 420, 26, 18), // Actual MacosSlider thumb.
                  Rect.fromLTWH(640, 420, 36, 36), // Tool button.
                ])
                  Positioned.fromRect(
                    rect: rect,
                    child: MacosGlass(
                      borderRadius: BorderRadius.circular(100),
                      elevated: false,
                      blurSigma: 0,
                      child: const SizedBox.expand(),
                    ),
                  ),
                // Fixed probe optics must not let business size adaptation
                // hide missing backdrop pixels outside output coverage.
                Positioned(
                  left: 760,
                  top: 420,
                  width: 36,
                  height: 24,
                  child: LiquidGlassBlend(
                    shapes: const [Rect.fromLTWH(3, 3, 30, 18)],
                    blend: 0,
                    optics: const _FixedDepthProbeOptics(),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    stdout.writeln(
      'PROBE_SCENE_READY small=true background=fff0f0f0 frost=0.5 refractive=true blur=0',
    );
    return;
  }
  final blur = double.parse(Platform.environment['PROBE_BLUR'] ?? '2');
  final prior = (Platform.environment['PROBE_PRIOR'] ?? 'true') == 'true';
  final glass = (Platform.environment['PROBE_GLASS'] ?? 'true') == 'true';
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  stdout.writeln(
    'PROBE_METRICS size=${view.physicalSize.width}x${view.physicalSize.height} dpr=${view.devicePixelRatio}',
  );
  final depth = double.parse(Platform.environment['PROBE_DEPTH'] ?? '0');
  final optics = LiquidGlassOptics(
    depth: depth,
    specular: 0,
    saturation: 1,
    tint: const Color(0x00000000),
    blurSigma: blur,
  );
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xff0000ff), Color(0xffff0000)],
                ),
              ),
            ),
          ),
          const Positioned(
            left: 590,
            top: 195,
            width: 80,
            height: 80,
            child: ColoredBox(color: Color(0xffffdd00)),
          ),
          const Positioned(
            left: 790,
            top: 155,
            width: 100,
            height: 100,
            child: ColoredBox(color: Color(0xff00ee22)),
          ),
          if (prior) ...[
            Positioned(
              left: 80,
              top: 280,
              width: 300,
              height: 120,
              child: LiquidGlassLens(
                mode: LiquidGlassMode.refract,
                optics: optics,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: 80,
              top: 440,
              width: 300,
              height: 120,
              child: LiquidGlassLens(
                optics: optics,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: 480,
              top: 100,
              width: 420,
              height: 300,
              child: LiquidGlassBlend(
                shapes: const [
                  Rect.fromLTWH(45, 65, 110, 110),
                  Rect.fromLTWH(165, 75, 150, 90),
                ],
                blend: 48,
                optics: optics,
              ),
            ),
          ],
          if (glass)
            Positioned(
              left: 480,
              top: 420,
              width: 300,
              height: 96,
              child: LiquidGlassBlend(
                shapes: const [Rect.fromLTWH(3, 3, 294, 90)],
                blend: 0,
                optics: optics,
              ),
            ),
        ],
      ),
    ),
  );
  stdout.writeln(
    'PROBE_SCENE_READY blur=$blur prior=$prior depth=$depth glass=$glass',
  );
}

// Exercise the engine's full backdrop contract independently of business
// forSize safety limits. Never use this policy in production materials.
class _FixedDepthProbeOptics extends LiquidGlassOptics {
  const _FixedDepthProbeOptics()
    : super(
        depth: 60,
        blurSigma: 0,
        specular: 0,
        saturation: 1,
        chromaticAberration: 0,
        tint: const Color(0x00000000),
      );

  @override
  LiquidGlassOptics forSize(Size size) => this;
}
