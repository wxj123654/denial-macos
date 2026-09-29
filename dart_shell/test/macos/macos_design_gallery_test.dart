import 'package:denial_dart_shell/macos_design_gallery.dart';
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
