import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:denial_dart_shell/liquid_glass_lab.dart';
import 'package:denial_dart_shell/macos_design_gallery.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(LiquidGlassPrograms.resetForTest);

  test('explicit Impeller runs must support shader image filters', () {
    if (Platform.environment['FLUTTER_TEST_IMPELLER'] == 'true') {
      expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    }
  });

  test('engine-owned input size is separate from lens geometry', () {
    final core = File('shaders/glass_core.glsl').readAsStringSync();
    final uniforms = RegExp(
      r'uniform\s+(\w+)\s+(\w+)\s*;',
    ).allMatches(core).toList();
    expect(uniforms.first.group(1), 'vec2');
    expect(uniforms.first.group(2), 'uTextureSize');
    expect(uniforms.where((u) => u.group(2) == 'uSize'), hasLength(1));
    for (final name in ['refract', 'liquid']) {
      final shader = File('shaders/glass_$name.frag').readAsStringSync();
      expect(shader, contains('uSize * 0.5'));
      expect(shader, isNot(contains('uTextureSize * 0.5')));
    }
  });

  test('shape coordinates account for output reflection, not the GLES API', () {
    final core = File('shaders/glass_core.glsl').readAsStringSync();
    final body = RegExp(
      r'vec2 glassFrag\(\)\s*\{([^}]+)\}',
    ).firstMatch(core)!.group(1)!;
    expect(body, contains('FlutterFragCoord().xy'));
    expect(body, contains('return frag - uOrigin;'));
    expect(
      body,
      contains('if (uRootYInverted > 0.5) frag.y = uTextureSize.y - frag.y;'),
    );
    expect(body, isNot(contains('IMPELLER_TARGET_OPENGLES')));
  });

  test('sampling uses engine texture size and GLES UV correction', () {
    final core = File('shaders/glass_core.glsl').readAsStringSync();
    final body = RegExp(
      r'vec2 glassUv\(vec2 frag\)\s*\{([^}]+)\}',
    ).firstMatch(core)!.group(1)!;
    expect(body, contains('(frag + uOrigin) / uTextureSize'));
    expect(
      body,
      contains(
        'defined(IMPELLER_TARGET_OPENGLES) && '
        '!defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)',
      ),
    );
    expect(body, contains('uv.y = 1.0 - uv.y;'));
    expect(body, isNot(contains('/ uView')));
  });

  test('engine size overwrite preserves geometry at fractional DPR', () {
    const size = Size(300, 120);
    const position = Offset(80, 440);
    const optics = LiquidGlassOptics();
    for (final dpr in [1.0, 1.25, 1.75, 2.0]) {
      for (final texture in [const Size(3840, 2160), const Size(1600, 900)]) {
        final origin = position * dpr;
        final values = optics.uniformsFor(size, dpr, 44, origin: origin);
        values[0] = texture.width;
        values[1] = texture.height;
        expect(values.sublist(16, 18), [origin.dx, origin.dy]);
        expect(values.sublist(18, 20), [size.width * dpr, size.height * dpr]);
        expect(values[2], 44 * dpr);
        final fragment = origin + Offset(size.width / 2, size.height / 2) * dpr;
        final local = fragment - Offset(values[16], values[17]);
        expect(local, Offset(values[18] / 2, values[19] / 2));
        final uv = Offset(
          (local.dx + values[16]) / values[0],
          (local.dy + values[17]) / values[1],
        );
        expect(
          uv,
          Offset(fragment.dx / texture.width, fragment.dy / texture.height),
        );
      }
    }
  });

  test('small glass controls fit the bezel and depth to their size', () {
    const optics = LiquidGlassOptics();
    final thumb = optics.forSize(const Size(26, 18));
    expect(thumb.bezel, 6);
    expect(thumb.depth, 9);
    final panel = optics.forSize(const Size(300, 120));
    expect(panel.bezel, optics.bezel);
    expect(panel.depth, optics.depth);
  });

  test('pixel scale changes geometry without moving its view origin', () {
    const optics = LiquidGlassOptics(pixelScale: 2);
    final values = optics.uniformsFor(
      const Size(300, 120),
      1.75,
      44,
      origin: const Offset(140, 770),
    );
    expect(values.sublist(16, 18), [140, 770]);
    expect(values.sublist(18, 20), [1050, 420]);
  });

  testWidgets('all shader assets load and accept the complete uniform ABI', (
    tester,
  ) async {
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    expect(LiquidGlassPrograms.failure, isNull);
    for (final program in [
      LiquidGlassPrograms.refract,
      LiquidGlassPrograms.liquid,
      LiquidGlassPrograms.metaball,
    ]) {
      expect(program, isNotNull);
      final shader = program!.fragmentShader();
      final count = const LiquidGlassOptics().apply(
        shader,
        const Size(300, 120),
        1.75,
        44,
        origin: const Offset(140, 770),
      );
      expect(count, 21);
      if (ui.ImageFilter.isShaderFilterSupported) {
        expect(const LiquidGlassOptics().filterFor(shader, 1.75), isNotNull);
        expect(
          const LiquidGlassOptics(blurSigma: 0).filterFor(shader, 1.75),
          isNotNull,
        );
      }
      expect(shader.getUniformFloat('uRootYInverted').shaderIndex, 20);
      shader.getUniformVec2('uTextureSize');
      shader.getUniformVec2('uSize');
      final total = identical(program, LiquidGlassPrograms.metaball) ? 39 : 21;
      shader.setFloat(total - 1, 1);
      expect(() => shader.setFloat(total, 1), throwsRangeError);
      shader.dispose();
    }
  });

  testWidgets('offscreen filter coverage is invariant under lens translation', (
    tester,
  ) async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    await tester.runAsync(() async {
      await LiquidGlassPrograms.ensureLoaded();
      expect(LiquidGlassPrograms.failure, isNull);
      for (final dpr in [1.0, 1.75]) {
        final width = (1600 * dpr).round();
        final height = (900 * dpr).round();
        for (final flipRoot in [false, true]) {
          for (final blur in [0.0, 2.0, 12.0]) {
            for (final position in [
              const Offset(80, 120),
              const Offset(80, 280),
              const Offset(80, 440),
              const Offset(650, 390),
              const Offset(1200, 680),
            ]) {
              final origin = position * dpr;
              final logicalRect = Rect.fromLTWH(
                position.dx,
                position.dy,
                300,
                120,
              );
              final rect = Rect.fromLTWH(
                origin.dx,
                origin.dy,
                300 * dpr,
                120 * dpr,
              );
              final shader = LiquidGlassPrograms.liquid!.fragmentShader();
              final optics = LiquidGlassOptics(
                debugShape: true,
                blurSigma: blur,
                rootYInverted: flipRoot,
              );
              optics.apply(
                shader,
                const Size(300, 120),
                dpr,
                44,
                origin: origin,
              );
              final filter = optics.filterFor(shader, dpr)!;
              final recorder = ui.PictureRecorder();
              final canvas = Canvas(recorder);
              canvas.drawRect(
                Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
                Paint()..color = const Color(0xff000000),
              );
              final background = recorder.endRecording();
              final childRecorder = ui.PictureRecorder();
              Canvas(
                childRecorder,
              ).drawRect(logicalRect, Paint()..color = const Color(0x01000000));
              final child = childRecorder.endRecording();
              final builder = ui.SceneBuilder()
                ..addPicture(Offset.zero, background);
              final root = Float64List(16)
                ..[0] = dpr
                ..[5] = flipRoot ? -dpr : dpr
                ..[10] = 1
                ..[13] = flipRoot ? height.toDouble() : 0
                ..[15] = 1;
              builder.pushTransform(root);
              builder.pushClipRRect(
                RRect.fromRectAndRadius(logicalRect, const Radius.circular(44)),
              );
              builder.pushBackdropFilter(filter);
              builder.addPicture(Offset.zero, child);
              builder.pop();
              builder.pop();
              builder.pop();
              final scene = builder.build();
              final image = await scene.toImage(width, height);
              expect(image.width, width);
              expect(image.height, height);
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final row = (flipRoot ? height - rect.center.dy : rect.center.dy)
                  .floor();
              var covered = 0;
              for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
                if (bytes.getUint8((row * width + x) * 4) > 30) covered++;
              }
              image.dispose();
              scene.dispose();
              background.dispose();
              child.dispose();
              shader.dispose();
              expect(
                covered,
                closeTo(rect.width, 3),
                reason:
                    'origin=$position dpr=$dpr blur=$blur rootFlip=$flipRoot: covered row width',
              );
            }
          }
        }
      }
    });
  });

  testWidgets('blended button footprint matches an ideal capsule', (
    tester,
  ) async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    await tester.runAsync(() async {
      await LiquidGlassPrograms.ensureLoaded();
      const dpr = 1.75;
      const width = 900;
      const height = 700;
      const logical = Rect.fromLTWH(120, 140, 300, 96);
      final rect = Rect.fromLTWH(
        logical.left * dpr,
        logical.top * dpr,
        logical.width * dpr,
        logical.height * dpr,
      );
      for (final flipRoot in [false, true]) {
        final shader = LiquidGlassPrograms.metaball!.fragmentShader();
        final optics = LiquidGlassOptics(
          debugShape: true,
          blurSigma: 0,
          rootYInverted: flipRoot,
        );
        final origin = logical.topLeft * dpr;
        var index = optics.apply(shader, logical.size, dpr, 0, origin: origin);
        final local = Offset.zero & logical.size;
        for (var i = 0; i < 4; i++) {
          final r = i == 0 ? local : null;
          shader
            ..setFloat(index++, (r?.center.dx ?? 0) * dpr)
            ..setFloat(index++, (r?.center.dy ?? 0) * dpr)
            ..setFloat(index++, (r?.width ?? 0) / 2 * dpr)
            ..setFloat(index++, (r?.height ?? 0) / 2 * dpr);
        }
        shader
          ..setFloat(index++, 0)
          ..setFloat(index, 1);
        final filter = optics.filterFor(shader, dpr)!;
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, width * 1.0, height * 1.0),
          Paint()..color = const Color(0xff000000),
        );
        final background = recorder.endRecording();
        final childRecorder = ui.PictureRecorder();
        Canvas(
          childRecorder,
        ).drawRect(logical, Paint()..color = const Color(0x01000000));
        final child = childRecorder.endRecording();
        final root = Float64List(16)
          ..[0] = dpr
          ..[5] = flipRoot ? -dpr : dpr
          ..[10] = 1
          ..[13] = flipRoot ? height.toDouble() : 0
          ..[15] = 1;
        final builder = ui.SceneBuilder()..addPicture(Offset.zero, background);
        builder.pushTransform(root);
        builder.pushClipRect(logical);
        builder.pushBackdropFilter(filter);
        builder.addPicture(Offset.zero, child);
        builder.pop();
        builder.pop();
        builder.pop();
        final scene = builder.build();
        final image = await scene.toImage(width, height);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final radius = rect.height / 2;
        var mismatches = 0;
        final samples = <String>[];
        // A flipped root draws the widget at height - rect in output rows;
        // scan those rows so the whole outline, including the top edge, is
        // compared against the ideal capsule.
        final yStart = (flipRoot ? height - rect.bottom : rect.top).floor() - 2;
        final yEnd = (flipRoot ? height - rect.top : rect.bottom).ceil() + 2;
        for (var y = yStart; y < yEnd; y++) {
          for (var x = rect.left.floor() - 2; x < rect.right.ceil() + 2; x++) {
            final sceneY = flipRoot ? height - y - 0.5 : y + 0.5;
            final p = Offset(x + 0.5, sceneY) - rect.center;
            final q = Offset(
              math.max(p.dx.abs() - (rect.width / 2 - radius), 0),
              p.dy.abs() - (rect.height / 2 - radius),
            );
            final distance =
                math.sqrt(q.dx * q.dx + math.max(q.dy, 0) * math.max(q.dy, 0)) -
                radius;
            if (distance.abs() < 1.5) continue;
            final inside = distance < 0;
            final observed = bytes.getUint8((y * width + x) * 4) > 30;
            if (inside != observed) {
              mismatches++;
              if (samples.length < 6)
                samples.add('($x,$y) d=${distance.toStringAsFixed(1)}');
            }
          }
        }
        image.dispose();
        scene.dispose();
        background.dispose();
        child.dispose();
        shader.dispose();
        expect(
          mismatches,
          0,
          reason: 'rootFlip=$flipRoot ${samples.join(' ')}',
        );
      }
    });
  });

  testWidgets('blended button top and bottom contours mirror each other', (
    tester,
  ) async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    await tester.runAsync(() async {
      await LiquidGlassPrograms.ensureLoaded();
      const dpr = 1.75;
      const width = 900;
      const height = 700;
      const logical = Rect.fromLTWH(120, 140, 300, 96);
      final rect = Rect.fromLTWH(
        logical.left * dpr,
        logical.top * dpr,
        logical.width * dpr,
        logical.height * dpr,
      );
      final shader = LiquidGlassPrograms.metaball!.fragmentShader();
      const optics = LiquidGlassOptics(
        blurSigma: 0,
        // Measure coverage in red over black. Final framebuffer alpha is
        // opaque on GLES because it includes the backdrop, not just glass.
        tint: Color(0xffffffff),
        saturation: 1,
        specular: 0,
      );
      final origin = logical.topLeft * dpr;
      var index = optics.apply(shader, logical.size, dpr, 0, origin: origin);
      final local = Offset.zero & logical.size;
      for (var i = 0; i < 4; i++) {
        final r = i == 0 ? local : null;
        shader
          ..setFloat(index++, (r?.center.dx ?? 0) * dpr)
          ..setFloat(index++, (r?.center.dy ?? 0) * dpr)
          ..setFloat(index++, (r?.width ?? 0) / 2 * dpr)
          ..setFloat(index++, (r?.height ?? 0) / 2 * dpr);
      }
      shader
        ..setFloat(index++, 0)
        ..setFloat(index, 1);
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, width * 1.0, height * 1.0),
        Paint()..color = const Color(0xff000000),
      );
      final background = recorder.endRecording();
      final childRecorder = ui.PictureRecorder();
      Canvas(
        childRecorder,
      ).drawRect(logical, Paint()..color = const Color(0x01000000));
      final child = childRecorder.endRecording();
      final root = Float64List(16)
        ..[0] = dpr
        ..[5] = -dpr
        ..[10] = 1
        ..[13] = height.toDouble()
        ..[15] = 1;
      final builder = ui.SceneBuilder()..addPicture(Offset.zero, background);
      builder.pushTransform(root);
      builder.pushClipRect(logical);
      builder.pushBackdropFilter(optics.filterFor(shader, dpr)!);
      builder.addPicture(Offset.zero, child);
      builder.pop();
      builder.pop();
      builder.pop();
      final scene = builder.build();
      final image = await scene.toImage(width, height);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      image.dispose();
      scene.dispose();
      background.dispose();
      child.dispose();
      shader.dispose();

      int coverageAt(int x, int y) => bytes.getUint8((y * width + x) * 4);
      // Choose pixel-centre pairs on opposite sides of the reflected
      // centre. Rounding both integer row boundaries up shifts both samples
      // by half a pixel and exaggerates differences at the capsule's tip.
      int outputRow(double sceneRow) => sceneRow < rect.center.dy
          ? (height - sceneRow).floor()
          : (height - sceneRow).ceil() - 1;
      (int?, int?) span(int y) {
        int? first;
        int? last;
        for (var x = rect.left.floor() - 3; x < rect.right.ceil() + 3; x++) {
          if (coverageAt(x, y) > 120) {
            last = x;
            first ??= x;
          }
        }
        return (first, last);
      }

      final issues = <String>[];
      final center = rect.center.dy;
      for (var t = 3.0; t < rect.height / 2; t += 3) {
        final (topStart, topEnd) = span(outputRow(center - t));
        final (bottomStart, bottomEnd) = span(outputRow(center + t));
        if (topStart == null || topEnd == null) {
          issues.add('t=${t.toStringAsFixed(0)} top row uncovered');
          continue;
        }
        if (bottomStart == null || bottomEnd == null) {
          issues.add('t=${t.toStringAsFixed(0)} bottom row uncovered');
          continue;
        }
        if ((topStart - bottomStart).abs() > 3 ||
            (topEnd - bottomEnd).abs() > 3) {
          issues.add(
            't=${t.toStringAsFixed(0)} spans '
            'top=$topStart..$topEnd bottom=$bottomStart..$bottomEnd',
          );
        }
        // The fused outline must stay inside the widget's clip rect.
        for (final start in [topStart, bottomStart]) {
          if (start < rect.left - 2) issues.add('t=$t escapes clip left');
        }
        for (final end in [topEnd, bottomEnd]) {
          if (end > rect.right + 2) issues.add('t=$t escapes clip right');
        }
      }
      expect(issues.take(6).join('; '), isEmpty, reason: 'mirror mismatches');

      // The anti-aliased flat edges must also match after mirroring.
      int rowCoverageSum(int y) {
        var sum = 0;
        for (var x = rect.left.floor(); x < rect.right.ceil(); x++) {
          sum += coverageAt(x, y);
        }
        return sum;
      }

      final topSum = rowCoverageSum(outputRow(rect.top + 1.5));
      final bottomSum = rowCoverageSum(outputRow(rect.bottom - 1.5));
      expect(
        (topSum - bottomSum).abs() / math.max(topSum, bottomSum),
        lessThan(0.25),
        reason: 'edge coverage top=$topSum bottom=$bottomSum',
      );
    });
  });

  testWidgets('blended button rim is continuous around the whole outline', (
    tester,
  ) async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    await tester.runAsync(() async {
      await LiquidGlassPrograms.ensureLoaded();
      const dpr = 1.75;
      const width = 900;
      const height = 700;
      const logical = Rect.fromLTWH(120, 140, 300, 96);
      final rect = Rect.fromLTWH(
        logical.left * dpr,
        logical.top * dpr,
        logical.width * dpr,
        logical.height * dpr,
      );
      const sectors = 16;
      Future<(List<double>, List<int>)> meanLift(
        LiquidGlassOptics optics,
      ) async {
        final shader = LiquidGlassPrograms.metaball!.fragmentShader();
        final origin = logical.topLeft * dpr;
        var index = optics.apply(shader, logical.size, dpr, 0, origin: origin);
        final local = Offset.zero & logical.size;
        for (var i = 0; i < 4; i++) {
          final r = i == 0 ? local : null;
          shader
            ..setFloat(index++, (r?.center.dx ?? 0) * dpr)
            ..setFloat(index++, (r?.center.dy ?? 0) * dpr)
            ..setFloat(index++, (r?.width ?? 0) / 2 * dpr)
            ..setFloat(index++, (r?.height ?? 0) / 2 * dpr);
        }
        shader
          ..setFloat(index++, 0)
          ..setFloat(index, 1);
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, width * 1.0, height * 1.0),
          Paint()..color = const Color(0xff202020),
        );
        final background = recorder.endRecording();
        final childRecorder = ui.PictureRecorder();
        Canvas(
          childRecorder,
        ).drawRect(logical, Paint()..color = const Color(0x01000000));
        final child = childRecorder.endRecording();
        final root = Float64List(16)
          ..[0] = dpr
          ..[5] = -dpr
          ..[10] = 1
          ..[13] = height.toDouble()
          ..[15] = 1;
        final builder = ui.SceneBuilder()..addPicture(Offset.zero, background);
        builder.pushTransform(root);
        builder.pushClipRect(logical);
        builder.pushBackdropFilter(optics.filterFor(shader, dpr)!);
        builder.addPicture(Offset.zero, child);
        builder.pop();
        builder.pop();
        builder.pop();
        final scene = builder.build();
        final image = await scene.toImage(width, height);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final radius = rect.height / 2;
        final sum = List<double>.filled(sectors, 0);
        final count = List<int>.filled(sectors, 0);
        // The flipped root draws the button at height - rect in output rows;
        // sample those so every sector (including the upper half) reads real
        // glass pixels instead of the empty backdrop above the widget.
        final yStart = (height - rect.bottom).floor();
        final yEnd = (height - rect.top).ceil();
        for (var y = yStart; y < yEnd; y++) {
          for (var x = rect.left.floor(); x < rect.right.ceil(); x++) {
            final p = Offset(x + 0.5, height - y - 0.5) - rect.center;
            final q = Offset(
              math.max(p.dx.abs() - (rect.width / 2 - radius), 0),
              p.dy.abs() - (rect.height / 2 - radius),
            );
            final distance =
                math.sqrt(q.dx * q.dx + math.max(q.dy, 0) * math.max(q.dy, 0)) -
                radius;
            if (distance > -1 || distance < -4) continue;
            final sector =
                ((math.atan2(p.dy, p.dx) + math.pi) / (2 * math.pi) * sectors)
                    .floor() %
                sectors;
            sum[sector] += bytes.getUint8((y * width + x) * 4) / 255;
            count[sector]++;
          }
        }
        image.dispose();
        scene.dispose();
        background.dispose();
        child.dispose();
        shader.dispose();
        return (
          [for (var i = 0; i < sectors; i++) sum[i] / math.max(count[i], 1)],
          count,
        );
      }

      const base = LiquidGlassOptics(
        blurSigma: 0,
        tint: Color(0x00000000),
        saturation: 1,
      );
      final (flatMeans, flatCounts) = await meanLift(
        base.copyWith(specular: 0),
      );
      final (litMeans, _) = await meanLift(base.copyWith(specular: 1));
      final rim = [
        for (var i = 0; i < sectors; i++) litMeans[i] - flatMeans[i],
      ];
      // An empty sector would average to a silent zero, so require every
      // sector to have sampled the actual outline band.
      for (var i = 0; i < sectors; i++) {
        expect(
          flatCounts[i],
          greaterThan(0),
          reason: 'sector $i sampled nothing',
        );
      }
      expect(
        rim.reduce(math.min),
        greaterThan(0.04),
        reason:
            'rim per 22.5 degree sector: ${rim.map((v) => v.toStringAsFixed(2))}',
      );
    });
  });

  testWidgets('lens uses its laid-out size under unbounded row constraints', (
    tester,
  ) async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    await tester.pumpWidget(
      MacosPaletteScope(
        palette: MacosPalette.light,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LiquidGlassLens(
                  child: SizedBox(
                    width: 120,
                    height: 32,
                    child: Text('intrinsic button'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(LiquidGlassLens)), const Size(120, 32));
    // The pre-blur lives in its own sibling backdrop layer beneath the shader
    // layer so the shader keeps exact view-space coordinates.
    expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'retained lens motion keeps the shader aligned at fractional DPR',
    (tester) async {
      if (!ui.ImageFilter.isShaderFilterSupported) return;
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.75;
      addTearDown(tester.view.reset);
      await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
      final position = ValueNotifier((Offset.zero, 1.0));
      addTearDown(position.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: Color(0xff000000)),
              ),
              ValueListenableBuilder<(Offset, double)>(
                valueListenable: position,
                child: const RepaintBoundary(
                  child: LiquidGlassLens(
                    radius: 16,
                    optics: LiquidGlassOptics(debugShape: true, blurSigma: 0),
                    child: SizedBox(width: 120, height: 32),
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
      for (final (offset, scale) in [
        (const Offset(10, 20), 1.0),
        (const Offset(80, 100), 0.5),
        (const Offset(80, 100), 0.96),
        (const Offset(200, 200), 1.2),
      ]) {
        position.value = (offset, scale);
        await tester.pump();
        await tester.runAsync(() async {
          final matrix = Float64List(16)
            ..[0] = 1
            ..[5] = -1
            ..[10] = 1
            ..[13] = 600
            ..[15] = 1;
          final builder = ui.SceneBuilder()..pushTransform(matrix);
          final scene = (tester.layers.first as ContainerLayer).buildScene(
            builder,
          );
          final image = await scene.toImage(800, 600);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final row = (600 - (offset.dy + 8 * scale) * 1.75).floor();
          var covered = 0;
          for (
            var x = (offset.dx * 1.75).ceil();
            x < ((offset.dx + 120 * scale) * 1.75).floor();
            x++
          ) {
            if (bytes.getUint8((row * 800 + x) * 4) > 30) covered++;
          }
          image.dispose();
          scene.dispose();
          final expectedWidth =
              (120 - 32 * (1 - math.sqrt(0.75))) * 1.75 * scale;
          expect(
            covered,
            closeTo(expectedWidth, 3),
            reason: 'retained offset=$offset scale=$scale',
          );
        });
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('lens falls back to frosted glass before shaders load', (
    tester,
  ) async {
    await tester.pumpWidget(
      MacosPaletteScope(
        palette: MacosPalette.light,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 200,
              height: 100,
              child: LiquidGlassLens(child: Text('glass')),
            ),
          ),
        ),
      ),
    );
    expect(find.text('glass'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('glass can be dragged from its blank surface, not just text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(3840, 2160);
    tester.view.devicePixelRatio = 1.75;
    addTearDown(tester.view.reset);
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    await tester.pumpWidget(
      MacosPaletteScope(
        palette: MacosPalette.light,
        child: const LiquidGlassLab(),
      ),
    );
    final lens = find.byType(LiquidGlassLens).at(2);
    final before = tester.getTopLeft(lens);
    const delta = Offset(100, 80);
    await tester.dragFrom(before + const Offset(20, 60), delta);
    await tester.pump();
    expect(tester.getTopLeft(lens), before + delta);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lab has a labelled standalone blended glass button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    await tester.pumpWidget(
      MacosPaletteScope(
        palette: MacosPalette.light,
        child: const LiquidGlassLab(),
      ),
    );
    final button = find.byKey(const ValueKey('lab-blended-glass-button'));
    expect(button, findsOneWidget);
    expect(find.text('融合玻璃'), findsOneWidget);
    final surface = find.descendant(
      of: button,
      matching: find.byType(LiquidGlassBlend),
    );
    expect(surface, findsOneWidget);
    final glass = tester.widget<LiquidGlassBlend>(surface);
    // The capsule sits off the coverage boundary so GLES pipeline slack
    // cannot flatten its corners.
    expect(glass.shapes, [const Rect.fromLTWH(3, 3, 294, 90)]);
    expect(glass.optics, const LiquidGlassOptics());
    final before = tester.getTopLeft(button);
    await tester.tapAt(before + const Offset(16, 48));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('点击 1 次'), findsOneWidget);
    await tester.dragFrom(before + const Offset(20, 48), const Offset(80, 40));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(button), before + const Offset(80, 40));
    expect(find.text('点击 1 次'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lab builds every mode and the stress grid', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MacosPaletteScope(
        palette: MacosPalette.light,
        child: const LiquidGlassLab(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    for (final mode in LiquidGlassMode.values) {
      expect(find.text(mode.name), findsWidgets);
    }
    await tester.tap(find.text('stress x8'));
    await tester.pump();
    expect(find.text('liquid 7'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
