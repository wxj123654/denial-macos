import 'package:denial_dart_shell/src/macos/macos_dock.dart';
import 'package:denial_dart_shell/src/macos/macos_dock_model.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../support/mobile_motion_harness.dart';

void main() {
  testWidgets(
    'separator divides persistent items from application entries only',
    (tester) async {
      var entries = const <MacosDockEntry>[];
      late StateSetter setEntries;
      await tester.pumpWidget(
        ProviderScope(
          child: mobileMotionHarness(
            MacosTheme(
              data: MacosThemeData.light(),
              child: StatefulBuilder(
                builder: (context, setState) {
                  setEntries = setState;
                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: MacosDock(
                      entries: entries,
                      onOpenApplications: () {},
                      onOpenSettings: () {},
                    ),
                  );
                },
              ),
            ),
            size: const Size(900, 400),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(macosDockRunningSeparatorKey), findsNothing);

      // A pinned application with no windows still forms an application
      // entry, so the separator appears.
      setEntries(
        () => entries = <MacosDockEntry>[
          const MacosDockEntry(id: 'pinned.desktop', pinned: true),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byKey(macosDockRunningSeparatorKey), findsOneWidget);

      // Running entries keep it too, ordered after the pinned item.
      setEntries(
        () => entries = <MacosDockEntry>[
          const MacosDockEntry(id: 'pinned.desktop', pinned: true),
          MacosDockEntry(
            id: 'alpha',
            windows: <DenialWindow>[motionWindow(1, appId: 'alpha')],
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byKey(macosDockRunningSeparatorKey), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(macosDockItemKey('pinned.desktop'))).dx,
        lessThan(tester.getTopLeft(find.byKey(macosDockItemKey('alpha'))).dx),
      );

      setEntries(() => entries = const <MacosDockEntry>[]);
      await tester.pumpAndSettle();
      expect(find.byKey(macosDockRunningSeparatorKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
