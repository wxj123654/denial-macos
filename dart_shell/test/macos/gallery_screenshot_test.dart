import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:denial_dart_shell/macos_design_gallery.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Headless gallery screenshots for development. Disabled unless
/// `GALLERY_SHOTS_DIR` names an output directory:
///
/// ```sh
/// GALLERY_SHOTS_DIR=/tmp/shots DENIAL_FLUTTER_TEST_BACKEND=opengles \
///   tools/denial-pc flutter-test test/macos/gallery_screenshot_test.dart
/// ```
void main() {
  final dir = Platform.environment['GALLERY_SHOTS_DIR'];
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await LiquidGlassPrograms.ensureLoaded();
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Size physical,
    double dpr,
  ) async {
    final bytes = await tester.runAsync(() async {
      final root = Float64List(16)
        ..[0] = 1
        ..[5] = -1
        ..[10] = 1
        ..[13] = physical.height
        ..[15] = 1;
      final builder = ui.SceneBuilder()..pushTransform(root);
      final scene = (tester.layers.first as ContainerLayer).buildScene(builder);
      final image = await scene.toImage(
        physical.width.toInt(),
        physical.height.toInt(),
      );
      final raw = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      image.dispose();
      scene.dispose();
      // Undo the production Y reflection and write the pixels upright.
      final w = physical.width.toInt();
      final h = physical.height.toInt();
      final flipped = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        flipped.setRange(
          y * w * 4,
          (y + 1) * w * 4,
          raw.buffer.asUint8List(raw.offsetInBytes + (h - 1 - y) * w * 4, w * 4),
        );
      }
      final completer = ui.ImmutableBuffer.fromUint8List(flipped);
      final buffer = await completer;
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: w,
        height: h,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      try {
        final frame = await codec.getNextFrame();
        try {
          final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
          return png!.buffer.asUint8List();
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }
    });
    File('$dir/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!);
  }

  testWidgets('gallery screenshots', (tester) async {
    final physical = Size(
      double.parse(Platform.environment["GALLERY_W"] ?? "1920"),
      double.parse(Platform.environment["GALLERY_H"] ?? "1080"),
    );
    final dpr = double.parse(Platform.environment["GALLERY_DPR"] ?? "1");
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    final logical = physical / dpr;
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    expect(LiquidGlassPrograms.failure, isNull);
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: MediaQuery(
              data: MediaQueryData(size: logical, devicePixelRatio: dpr),
              child: MacosDesignGallery(
                key: ValueKey(dark),
                initialDark: dark,
                onExit: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final palette = tester.widget<MacosPaletteScope>(
        find.byType(MacosPaletteScope).first,
      );
      expect(palette.palette.isDark, dark,
          reason: 'Screenshot name must match the actual gallery theme');
      await shoot(tester, 'gallery-${dark ? 'dark' : 'light'}', physical, dpr);
    }
  }, skip: dir == null);
}
