import 'package:denial_dart_shell/src/core/shell_windows.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/macos/macos_dock.dart';
import 'package:denial_dart_shell/src/macos/macos_dock_model.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_snapshot.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/lock_state_repository.dart';
import 'package:denial_dart_shell/src/state/authentication.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show MenuItemButton;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../support/mobile_motion_harness.dart';

Widget _dockHarness(Widget child, {Locale locale = const Locale('en')}) {
  return mobileMotionHarness(
    DenialLocalizationScope(
      locale: locale,
      child: MacosTheme(
        data: MacosThemeData.light(),
        child: Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) =>
                  Align(alignment: Alignment.bottomCenter, child: child),
            ),
          ],
        ),
      ),
    ),
    size: const Size(900, 400),
  );
}

MacosDockEntry _entry({
  required String id,
  List<DenialWindow> windows = const <DenialWindow>[],
  Set<int> minimizedObjectIds = const <int>{},
  bool pinned = false,
  bool active = false,
  String? pinId,
}) {
  return MacosDockEntry(
    id: id,
    windows: windows,
    minimizedObjectIds: minimizedObjectIds,
    pinned: pinned,
    active: active,
    pinId: pinId,
  );
}

void main() {
  testWidgets(
    'persistent items use localized labels and invoke callbacks with no windows',
    (tester) async {
      var openedApplications = 0;
      var openedSettings = 0;
      final bridge = _DockBridge();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            denialBridgeProvider.overrideWithValue(bridge),
            lockStateRepositoryProvider.overrideWithValue(_NoLockFiles()),
            authenticationProvider.overrideWith(_NoAuthentication.new),
          ],
          child: _dockHarness(
            locale: const Locale('zh'),
            ShellWindowsBuilder(
              builder: (context, windows, actions) => MacosDock(
                entries: const <MacosDockEntry>[],
                onOpenApplications: () => openedApplications += 1,
                onOpenSettings: () => openedSettings += 1,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(macosDockApplicationsKey), findsOneWidget);
      expect(find.byKey(macosDockSettingsKey), findsOneWidget);
      expect(find.bySemanticsLabel('应用'), findsOneWidget);
      expect(find.bySemanticsLabel('设置'), findsOneWidget);

      await tester.tap(find.byKey(macosDockApplicationsKey));
      await tester.pump();
      expect(openedApplications, 1);
      await tester.tap(find.byKey(macosDockSettingsKey));
      await tester.pump();
      expect(openedSettings, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one Dock item shows per application regardless of window count',
    (tester) async {
      final entries = <MacosDockEntry>[
        _entry(
          id: 'alpha',
          windows: <DenialWindow>[
            motionWindow(1, appId: 'alpha'),
            motionWindow(2, appId: 'alpha'),
          ],
        ),
        _entry(
          id: 'beta',
          windows: <DenialWindow>[motionWindow(3, appId: 'beta')],
        ),
      ];
      await tester.pumpWidget(
        ProviderScope(
          child: _dockHarness(
            MacosDock(
              entries: entries,
              onOpenApplications: () {},
              onOpenSettings: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(macosDockItemKey('alpha')), findsOneWidget);
      expect(find.byKey(macosDockItemKey('beta')), findsOneWidget);
      expect(find.byKey(macosDockRunningIndicatorKey('alpha')), findsOneWidget);
      expect(find.byKey(macosDockRunningIndicatorKey('beta')), findsOneWidget);
      expect(find.byKey(macosDockRunningSeparatorKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tapping an entry activates the application group', (
    tester,
  ) async {
    MacosDockEntry? activated;
    final entry = _entry(
      id: 'alpha',
      windows: <DenialWindow>[motionWindow(1, appId: 'alpha')],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: _dockHarness(
          MacosDock(
            entries: <MacosDockEntry>[entry],
            onOpenApplications: () {},
            onOpenSettings: () {},
            onActivateEntry: (value) => activated = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(macosDockItemKey('alpha')));
    await tester.pump();
    expect(activated, same(entry));
    expect(tester.takeException(), isNull);
  });

  testWidgets('secondary tap opens the per-application context menu', (
    tester,
  ) async {
    MacosDockEntry? toggled;
    MacosDockEntry? quit;
    DenialWindow? activatedWindow;
    final entry = _entry(
      id: 'alpha',
      windows: <DenialWindow>[
        motionWindow(1, appId: 'alpha'),
        motionWindow(2, appId: 'alpha'),
      ],
      minimizedObjectIds: const <int>{2},
    );
    await tester.pumpWidget(
      ProviderScope(
        child: _dockHarness(
          MacosDock(
            entries: <MacosDockEntry>[entry],
            onOpenApplications: () {},
            onOpenSettings: () {},
            onActivateWindow: (window) => activatedWindow = window,
            onTogglePin: (value) => toggled = value,
            onQuitEntry: (value) => quit = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(macosDockItemKey('alpha')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Keep in Dock'), findsOneWidget);
    expect(find.text('Minimize'), findsOneWidget);
    expect(find.text('Quit'), findsOneWidget);
    expect(find.text('App 1'), findsOneWidget);
    expect(find.text('App 2'), findsOneWidget);

    await tester.tap(find.byKey(macosDockMenuItemKey('window-1', 'alpha')));
    await tester.pumpAndSettle();
    expect(activatedWindow?.objectId, 1);

    await tester.tap(
      find.byKey(macosDockItemKey('alpha')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(macosDockMenuItemKey('pin', 'alpha')));
    await tester.pumpAndSettle();
    expect(toggled, same(entry));

    await tester.tap(
      find.byKey(macosDockItemKey('alpha')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(macosDockMenuItemKey('quit', 'alpha')));
    await tester.pumpAndSettle();
    expect(quit, same(entry));
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu minimize is disabled when every window is minimized', (
    tester,
  ) async {
    final entry = _entry(
      id: 'alpha',
      windows: <DenialWindow>[motionWindow(1, appId: 'alpha')],
      minimizedObjectIds: const <int>{1},
    );
    await tester.pumpWidget(
      ProviderScope(
        child: _dockHarness(
          MacosDock(
            entries: <MacosDockEntry>[entry],
            onOpenApplications: () {},
            onOpenSettings: () {},
            onMinimizeEntry: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(macosDockItemKey('alpha')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    final minimize = tester.widget<MenuItemButton>(
      find.byKey(macosDockMenuItemKey('minimize', 'alpha')),
    );
    expect(minimize.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned entry without windows offers Open and Remove', (
    tester,
  ) async {
    MacosDockEntry? activated;
    MacosDockEntry? unpinned;
    final entry = _entry(id: 'pinned.desktop', pinned: true);
    await tester.pumpWidget(
      ProviderScope(
        child: _dockHarness(
          MacosDock(
            entries: <MacosDockEntry>[entry],
            onOpenApplications: () {},
            onOpenSettings: () {},
            onActivateEntry: (value) => activated = value,
            onTogglePin: (value) => unpinned = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Pinned entries without windows have no running indicator.
    expect(
      find.byKey(macosDockRunningIndicatorKey('pinned.desktop')),
      findsNothing,
    );
    expect(find.byKey(macosDockRunningSeparatorKey), findsOneWidget);

    await tester.tap(
      find.byKey(macosDockItemKey('pinned.desktop')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Remove from Dock'), findsOneWidget);

    await tester.tap(
      find.byKey(macosDockMenuItemKey('open', 'pinned.desktop')),
    );
    await tester.pumpAndSettle();
    expect(activated, same(entry));

    await tester.tap(
      find.byKey(macosDockItemKey('pinned.desktop')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(macosDockMenuItemKey('pin', 'pinned.desktop')));
    await tester.pumpAndSettle();
    expect(unpinned, same(entry));
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrow keys move focus and Enter activates deterministically', (
    tester,
  ) async {
    var openedApplications = 0;
    var openedSettings = 0;
    MacosDockEntry? activated;
    final entry = _entry(
      id: 'alpha',
      windows: <DenialWindow>[motionWindow(1, appId: 'alpha')],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: _dockHarness(
          MacosDock(
            entries: <MacosDockEntry>[entry],
            onOpenApplications: () => openedApplications += 1,
            onOpenSettings: () => openedSettings += 1,
            onActivateEntry: (value) => activated = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tapping the Apps item focuses it; Right moves to Settings, Right again
    // to the application entry, Enter activates the focused item.
    await tester.tap(find.byKey(macosDockApplicationsKey));
    await tester.pump();
    expect(openedApplications, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(openedSettings, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, same(entry));
    expect(tester.takeException(), isNull);
  });
}

class _DockBridge extends DenialBridge {
  @override
  void start({
    required VoidCallback onWindowsChanged,
    ValueChanged<DenialWindowSnapshot>? onWindowSnapshot,
    required ValueChanged<int> onWindowActivated,
  }) {}

  @override
  Future<DenialWindowSnapshot> listWindows(List<DenialWindow> fallback) async =>
      const DenialWindowSnapshot(sequence: 1, windows: <DenialWindow>[]);
}

class _NoAuthentication extends AuthenticationController {
  @override
  AuthenticationState build() => const AuthenticationState.initial();
}

class _NoLockFiles extends LockStateRepository {
  @override
  void start({required LockRequestChanged onChanged}) {}
}
