import 'dart:ui' as ui;

import 'package:denial_dart_shell/macos_design_gallery.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({bool dark = false}) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(1280, 800)),
      child: MacosDesignGallery(initialDark: dark),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await LiquidGlassPrograms.ensureLoaded();
    expect(LiquidGlassPrograms.failure, isNull);
  });

  test('concentric radius never goes negative', () {
    expect(MacosRadii.concentric(26, 8), 18);
    expect(MacosRadii.concentric(10, 16), 0);
  });

  testWidgets('gallery builds in light and dark and switches pages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness());
    expect(find.text('Buttons'), findsOneWidget);

    await tester.tap(find.text('Materials'));
    await tester.pump();
    expect(find.text('Regular'), findsOneWidget);

    await tester.tap(find.text('Light'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Dark'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery glass and slider thumbs use the refractive material', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    await tester.pumpWidget(_harness());
    expect(find.byType(LiquidGlassBlend), findsWidgets);
    for (final slider in find.byType(MacosSlider).evaluate()) {
      expect(
        find.descendant(
          of: find.byWidget(slider.widget),
          matching: find.byType(LiquidGlassBlend),
        ),
        findsOneWidget,
      );
    }
    await tester.tap(find.text('Materials'));
    await tester.pump();
    for (final label in ['Regular', 'Clear', 'Tinted']) {
      expect(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(LiquidGlassBlend),
        ),
        findsWidgets,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery foreground stays outside glass filter layers', (
    tester,
  ) async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    await tester.pumpWidget(_harness());
    final layers = tester.layers.whereType<BackdropFilterLayer>().toList();
    expect(layers.length, greaterThanOrEqualTo(5));
    for (final layer in layers) {
      expect(layer.firstChild, isNull);
    }
    final scene = (tester.layers.first as ContainerLayer).buildScene(
      ui.SceneBuilder(),
    );
    scene.dispose();
    for (final layer in layers) {
      expect(layer.filter, isNotNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('sliding the new glass thumb still updates its value', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(LiquidGlassPrograms.ensureLoaded);
    await tester.pumpWidget(_harness());
    final slider = find.byType(MacosSlider).at(1);
    final rect = tester.getRect(slider);
    await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
    await tester.pump();
    expect(tester.widget<MacosSlider>(slider).value, 1);
    await tester.dragFrom(
      Offset(rect.left + 14, rect.center.dy),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(
      tester.widget<MacosSlider>(slider).value,
      inInclusiveRange(0.1, 0.3),
    );
    expect(
      find.descendant(of: slider, matching: find.byType(LiquidGlassBlend)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('fully frosted material disables refractive filters', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MacosPaletteScope(
          palette: MacosPalette.light,
          child: const MacosGlassScope(
            frost: 1,
            refractive: true,
            child: Center(
              child: SizedBox(
                width: 120,
                height: 40,
                child: MacosGlass(child: Text('frosted')),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(LiquidGlassBlend), findsNothing);
    expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
    expect(find.text('frosted'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switch and segmented control respond', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(dark: true));
    await tester.tap(find.byType(MacosSwitch));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Columns'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Desktop button appears only with onExit and calls it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness());
    expect(find.text('Desktop'), findsNothing);

    var exited = false;
    await tester.pumpWidget(
      ProviderScope(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(1280, 800)),
            child: MacosDesignGallery(onExit: () => exited = true),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Desktop'));
    expect(exited, isTrue);
  });
}
