import 'package:denial_dart_shell/src/macos/macos_menu_bar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../support/mobile_motion_harness.dart';

void main() {
  testWidgets('the Spotlight affordance reports taps to its callback', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      mobileMotionHarness(
        MacosTheme(
          data: MacosThemeData.light(),
          child: MacosMenuBar(onOpenSpotlight: () => opened += 1),
        ),
        size: const Size(1000, 60),
      ),
    );
    await tester.pump();
    expect(find.byKey(macosMenuBarSpotlightKey), findsOneWidget);
    await tester.tap(find.byKey(macosMenuBarSpotlightKey));
    await tester.pump();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the affordance is omitted without a callback', (tester) async {
    await tester.pumpWidget(
      mobileMotionHarness(
        MacosTheme(data: MacosThemeData.light(), child: const MacosMenuBar()),
        size: const Size(1000, 60),
      ),
    );
    await tester.pump();
    expect(find.byKey(macosMenuBarSpotlightKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
