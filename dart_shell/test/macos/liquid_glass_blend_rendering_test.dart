import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:denial_dart_shell/liquid_glass_lab.dart';
import 'package:denial_dart_shell/macos_design_gallery.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _outputWidth = 1200;
const _outputHeight = 850;
const _outputSize = Size(1200, 850);
const _position = Offset(80.25, 60.25);
const _groupSize = Size(420, 300);
// The lab's initial two shapes, expressed in the blend widget's coordinates.
const _labShapes = [
  Rect.fromLTWH(45, 65, 110, 110),
  Rect.fromLTWH(165, 75, 150, 90),
];

void main() {
  setUp(LiquidGlassPrograms.resetForTest);

  test('explicit Impeller runs must exercise shader filters', () {
    if (Platform.environment['DENIAL_FLUTTER_TEST_BACKEND'] == 'opengles') {
      // Never silently return from the GLES-only regressions if an explicit
      // --no-enable-impeller overrode the harness's backend selection.
      expect(Platform.environment['FLUTTER_TEST_IMPELLER'], 'true');
    }
    if (Platform.environment['FLUTTER_TEST_IMPELLER'] == 'true') {
      expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    }
  });

  testWidgets(
    'desktop glass surface retains its material over a bright backdrop',
    (tester) async {
      if (!ui.ImageFilter.isShaderFilterSupported) return;
      const background = Color(0xffc03010);
      tester.view.physicalSize = _outputSize;
      addTearDown(tester.view.reset);
      await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
      expect(LiquidGlassPrograms.failure, isNull);
      for (final dpr in [1.0, 1.75]) {
        tester.view.devicePixelRatio = dpr;
        for (final dark in [false, true]) {
          for (final blur in [0.0, 12.0]) {
            await tester.pumpWidget(
              Directionality(
                textDirection: TextDirection.ltr,
                child: MacosPaletteScope(
                  palette: dark ? MacosPalette.dark : MacosPalette.light,
                  child: MacosGlassScope(
                    frost: 0.5,
                    refractive: true,
                    child: Stack(
                      children: [
                        const Positioned.fill(
                          child: ColoredBox(color: background),
                        ),
                        Positioned(
                          bottom: 100.25,
                          right: 36.25,
                          child: SizedBox(
                            width: 340,
                            child: MacosGlass(
                              blurSigma: blur,
                              elevated: false,
                              borderRadius: BorderRadius.circular(22),
                              child: const SizedBox(height: 62),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            final surface = find.byType(LiquidGlassBlend);
            expect(surface, findsOneWidget);
            expect(tester.getSize(surface), const Size(340, 62));
            final optics = tester.widget<LiquidGlassBlend>(surface).optics;
            final bytes = await _readScene(tester, flipRoot: true);
            final center = tester.getCenter(surface) * dpr;
            final x = center.dx.floor();
            final y = _outputHeight - 1 - center.dy.floor();
            final index = (y * _outputWidth + x) * 4;
            final luma =
                0.299 * background.r +
                0.587 * background.g +
                0.114 * background.b;
            final expected = [
              for (final (source, tint) in [
                (background.r, optics.tint.r),
                (background.g, optics.tint.g),
                (background.b, optics.tint.b),
              ])
                ((luma + (source - luma) * optics.saturation) *
                                (1 - optics.tint.a) +
                            tint * optics.tint.a)
                        .clamp(0.0, 1.0) *
                    255,
            ];
            for (var channel = 0; channel < 3; channel++) {
              expect(
                bytes.getUint8(index + channel),
                closeTo(expected[channel], 4),
                reason:
                    'desktop dark=$dark dpr=$dpr blur=$blur channel=$channel center=$center',
              );
            }
            expect(tester.takeException(), isNull);
          }
        }
      }
    },
    // This regression uses the production desktop's reflected GLES path.
    // Vulkan scene.toImage has a separate transparent-padding baseline.
    skip: Platform.environment['DENIAL_FLUTTER_TEST_BACKEND'] != 'opengles',
  );

  testWidgets(
    'pre-blur does not shrink or shift the glass surface',
    (tester) async {
      if (!ui.ImageFilter.isShaderFilterSupported) return;
      tester.view.physicalSize = _outputSize;
      addTearDown(tester.view.reset);
      await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
      expect(LiquidGlassPrograms.failure, isNull);
      for (final dpr in [1.0, 1.75]) {
        tester.view.devicePixelRatio = dpr;
        (int, int) rows(ByteData bytes) {
          final x = (250 * dpr).round();
          int? first;
          int? last;
          for (var y = 0; y < _outputHeight; y++) {
            if (bytes.getUint8((y * _outputWidth + x) * 4) > 128) {
              first ??= y;
              last = y;
            }
          }
          expect(first, isNotNull, reason: 'glass visible dpr=$dpr');
          return (first!, last!);
        }

        final measured = <(int, int)>[];
        for (final blur in [0.0, 12.0]) {
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: Color(0xff000000)),
                  ),
                  Positioned(
                    left: 100,
                    top: 100,
                    width: 300,
                    height: 80,
                    child: LiquidGlassBlend.surface(
                      radius: 22,
                      optics: LiquidGlassOptics(
                        blurSigma: blur,
                        tint: const Color(0xffffffff),
                        saturation: 1,
                        specular: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          measured.add(rows(await _readScene(tester, flipRoot: true)));
        }
        expect(measured[1], measured[0], reason: 'blur moved edges dpr=$dpr');
      }
    },
    skip: Platform.environment['DENIAL_FLUTTER_TEST_BACKEND'] != 'opengles',
  );

  testWidgets(
    'real blend widget matches the fused field with default blur',
    (tester) async {
      if (!ui.ImageFilter.isShaderFilterSupported) return;
      tester.view.physicalSize = _outputSize;
      addTearDown(tester.view.reset);
      await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
      expect(LiquidGlassPrograms.failure, isNull);

      for (final dpr in [1.0, 1.75]) {
        tester.view.devicePixelRatio = dpr;
        for (final flipRoot in [false, true]) {
          for (final blur in [0.0, const LiquidGlassOptics().blurSigma]) {
            for (final blend in [0.0, 48.0]) {
              await tester.pumpWidget(
                _harness(
                  size: _groupSize,
                  shapes: _labShapes,
                  blend: blend,
                  optics: LiquidGlassOptics(
                    debugShape: true,
                    blurSigma: blur,
                    rootYInverted: flipRoot,
                  ),
                ),
              );
              final bytes = await _readScene(tester, flipRoot: flipRoot);
              final rect = Rect.fromLTWH(
                _position.dx * dpr,
                _position.dy * dpr,
                _groupSize.width * dpr,
                _groupSize.height * dpr,
              );
              final samples = <String>[];
              var mismatches = 0;
              var worstDistance = 0.0;
              var insideCount = 0;
              var outsideCount = 0;
              for (var y = rect.top.ceil(); y < rect.bottom.floor(); y += 2) {
                for (var x = rect.left.ceil(); x < rect.right.floor(); x += 2) {
                  final point = Offset(x + 0.5, y + 0.5) - rect.topLeft;
                  final distance = _fusedDistance(point, dpr, blend);
                  // The existing GLES blur padding can offset the contour
                  // slightly on both engine generations. Keep its bound
                  // explicit while sampling and material tests stay exact.
                  final edgeSlack = blur == 0 ? 2.0 : 8 * dpr;
                  if (distance.abs() < edgeSlack) continue;
                  final inside = distance < 0;
                  if (inside) {
                    insideCount++;
                  } else {
                    outsideCount++;
                  }
                  final outputY = flipRoot ? _outputHeight - 1 - y : y;
                  final observed =
                      bytes.getUint8((outputY * _outputWidth + x) * 4) > 30;
                  if (inside != observed) {
                    mismatches++;
                    worstDistance = math.max(worstDistance, distance.abs());
                    if (samples.length < 5) {
                      samples.add('($x,$y) sd=${distance.toStringAsFixed(1)}');
                    }
                  }
                }
              }
              // This point is outside both individual shapes but inside
              // their smooth union. Test it explicitly so the blur-edge
              // exclusion cannot hide a missing fusion bridge.
              if (blend > 0) {
                const bridge = Offset(160, 120);
                expect(_fusedDistance(bridge * dpr, dpr, 0), greaterThan(0));
                expect(_fusedDistance(bridge * dpr, dpr, blend), lessThan(0));
                final x = ((_position.dx + bridge.dx) * dpr).floor();
                final sceneY = ((_position.dy + bridge.dy) * dpr).floor();
                final y = flipRoot ? _outputHeight - 1 - sceneY : sceneY;
                expect(
                  bytes.getUint8((y * _outputWidth + x) * 4),
                  greaterThan(30),
                  reason:
                      'missing fusion bridge dpr=$dpr flip=$flipRoot blur=$blur',
                );
              }
              expect(insideCount, greaterThan(100));
              expect(outsideCount, greaterThan(100));
              expect(
                mismatches,
                0,
                reason:
                    'dpr=$dpr rootFlip=$flipRoot blur=$blur blend=$blend '
                    'worstDistance=$worstDistance ${samples.join(' ')}',
              );
              expect(tester.takeException(), isNull);
            }
          }
        }
      }
    },
    // Default-blur field coverage is a production GLES contract; Vulkan
    // scene.toImage has a separate pre-existing filter-padding offset.
    skip: Platform.environment['DENIAL_FLUTTER_TEST_BACKEND'] != 'opengles',
  );

  testWidgets('inset blend button remains aligned during retained motion', (
    tester,
  ) async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    const dpr = 1.75;
    const shape = Rect.fromLTWH(3, 3, 294, 90);
    tester.view.physicalSize = _outputSize;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    expect(LiquidGlassPrograms.failure, isNull);
    final motion = ValueNotifier((_position, 1.0));
    addTearDown(motion.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xff000000))),
            ValueListenableBuilder<(Offset, double)>(
              valueListenable: motion,
              child: RepaintBoundary(
                child: SizedBox(
                  width: 300,
                  height: 96,
                  child: LiquidGlassBlend(
                    shapes: [shape],
                    blend: 0,
                    optics: const LiquidGlassOptics(debugShape: true),
                  ),
                ),
              ),
              builder: (context, value, child) => Transform.translate(
                offset: value.$1,
                child: Transform.scale(
                  scale: value.$2,
                  alignment: Alignment.topLeft,
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    for (final (position, scale) in [
      (_position, 1.0),
      (const Offset(180.25, 160.25), 0.96),
      (const Offset(280.25, 260.25), 0.5),
      (const Offset(80.25, 100.25), 1.2),
    ]) {
      motion.value = (position, scale);
      await tester.pump();
      final bytes = await _readScene(tester, flipRoot: true);
      final physicalShape = Rect.fromLTWH(
        (position.dx + shape.left * scale) * dpr,
        (position.dy + shape.top * scale) * dpr,
        shape.width * scale * dpr,
        shape.height * scale * dpr,
      );
      final row = (_outputHeight - physicalShape.center.dy).floor();
      var covered = 0;
      for (
        var x = physicalShape.left.ceil();
        x < physicalShape.right.floor();
        x++
      ) {
        if (bytes.getUint8((row * _outputWidth + x) * 4) > 30) covered++;
      }
      expect(
        covered,
        closeTo(physicalShape.width, 3),
        reason: 'retained position=$position scale=$scale',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('fused glass preserves backdrop sampling without displacement', (
    tester,
  ) async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    tester.view.physicalSize = _outputSize;
    addTearDown(tester.view.reset);
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    expect(LiquidGlassPrograms.failure, isNull);
    for (final dpr in [1.0, 1.75]) {
      tester.view.devicePixelRatio = dpr;
      for (final flipRoot in [false, true]) {
        for (final blur in [0.0, const LiquidGlassOptics().blurSigma]) {
          await tester.pumpWidget(
            _harness(
              size: _groupSize,
              shapes: _labShapes,
              blend: 48,
              gradient: true,
              optics: LiquidGlassOptics(
                depth: 0,
                specular: 0,
                saturation: 1,
                tint: const Color(0x00000000),
                blurSigma: blur,
                rootYInverted: flipRoot,
              ),
            ),
          );
          final bytes = await _readScene(tester, flipRoot: flipRoot);
          for (final point in [
            const Offset(100, 95),
            const Offset(100, 145),
            const Offset(240, 95),
            const Offset(240, 145),
          ]) {
            final x = ((_position.dx + point.dx) * dpr).floor();
            final sceneY = ((_position.dy + point.dy) * dpr).floor();
            final y = flipRoot ? _outputHeight - 1 - sceneY : sceneY;
            final index = (y * _outputWidth + x) * 4;
            final expectedRed = (sceneY + 0.5) / _outputHeight * 255;
            final reason = 'point=$point dpr=$dpr flip=$flipRoot blur=$blur';
            expect(
              bytes.getUint8(index),
              closeTo(expectedRed, 4),
              reason: reason,
            );
            expect(
              bytes.getUint8(index + 2),
              closeTo(255 - expectedRed, 4),
              reason: reason,
            );
            expect(tester.takeException(), isNull);
          }
        }
      }
    }
  });
}

Widget _harness({
  required Size size,
  required List<Rect> shapes,
  required double blend,
  required LiquidGlassOptics optics,
  bool gradient = false,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Stack(
    children: [
      Positioned.fill(
        child: gradient
            ? const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xff0000ff), Color(0xffff0000)],
                  ),
                ),
              )
            : const ColoredBox(color: Color(0xff000000)),
      ),
      Positioned(
        left: _position.dx,
        top: _position.dy,
        width: size.width,
        height: size.height,
        child: LiquidGlassBlend(shapes: shapes, blend: blend, optics: optics),
      ),
    ],
  ),
);

Future<ByteData> _readScene(
  WidgetTester tester, {
  required bool flipRoot,
}) async => (await tester.runAsync(() async {
  final root = Float64List(16)
    ..[0] = 1
    ..[5] = flipRoot ? -1 : 1
    ..[10] = 1
    ..[13] = flipRoot ? _outputHeight.toDouble() : 0
    ..[15] = 1;
  final builder = ui.SceneBuilder()..pushTransform(root);
  final scene = (tester.layers.first as ContainerLayer).buildScene(builder);
  try {
    final image = await scene.toImage(_outputWidth, _outputHeight);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    } finally {
      image.dispose();
    }
  } finally {
    scene.dispose();
  }
}))!;

// Independent CPU oracle for the shader's rounded boxes and smooth union.
double _fusedDistance(Offset point, double dpr, double blend) {
  final a = _roundedDistance(point, _labShapes[0], dpr);
  final b = _roundedDistance(point, _labShapes[1], dpr);
  final k = blend * dpr;
  final e = math.max(k - (a - b).abs(), 0.0);
  return math.min(a, b) - e * e * 0.25 / math.max(k, 1e-3);
}

double _roundedDistance(Offset point, Rect shape, double dpr) {
  final local = point - shape.center * dpr;
  final halfWidth = shape.width * dpr / 2;
  final halfHeight = shape.height * dpr / 2;
  final radius = math.min(halfWidth, halfHeight);
  final qx = local.dx.abs() - halfWidth + radius;
  final qy = local.dy.abs() - halfHeight + radius;
  final x = math.max(qx, 0.0);
  final y = math.max(qy, 0.0);
  return math.min(math.max(qx, qy), 0.0) + math.sqrt(x * x + y * y) - radius;
}
