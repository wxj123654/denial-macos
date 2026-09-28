import 'package:denial_dart_shell/src/core/shell_windows.dart';
import 'package:denial_dart_shell/src/localization/denial_localizations.dart';
import 'package:denial_dart_shell/src/macos/macos_dock.dart';
import 'package:denial_dart_shell/src/models/denial_window.dart';
import 'package:denial_dart_shell/src/models/denial_window_snapshot.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/services/lock_state_repository.dart';
import 'package:denial_dart_shell/src/state/authentication.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';

import '../support/mobile_motion_harness.dart';

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
          child: mobileMotionHarness(
            DenialLocalizationScope(
              locale: const Locale('zh'),
              child: MacosTheme(
                data: MacosThemeData.light(),
                child: ShellWindowsBuilder(
                  builder: (context, windows, actions) => Align(
                    alignment: Alignment.bottomCenter,
                    child: MacosDock(
                      windows: const <DenialWindow>[],
                      actions: actions,
                      onOpenApplications: () => openedApplications += 1,
                      onOpenSettings: () => openedSettings += 1,
                    ),
                  ),
                ),
              ),
            ),
            size: const Size(900, 400),
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
