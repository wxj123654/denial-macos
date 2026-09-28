import 'package:denial_dart_shell/src/core/shell_windows.dart';
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
  testWidgets('running separator appears only with running windows', (
    tester,
  ) async {
    final bridge = _SeparatorBridge();
    var windows = const <DenialWindow>[];
    late StateSetter setWindows;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          denialBridgeProvider.overrideWithValue(bridge),
          lockStateRepositoryProvider.overrideWithValue(_NoLockFiles()),
          authenticationProvider.overrideWith(_NoAuthentication.new),
        ],
        child: mobileMotionHarness(
          MacosTheme(
            data: MacosThemeData.light(),
            child: ShellWindowsBuilder(
              builder: (context, _, actions) => StatefulBuilder(
                builder: (context, setState) {
                  setWindows = setState;
                  return Align(
                    alignment: Alignment.bottomCenter,
                    child: MacosDock(
                      windows: windows,
                      actions: actions,
                      onOpenApplications: () {},
                      onOpenSettings: () {},
                    ),
                  );
                },
              ),
            ),
          ),
          size: const Size(900, 400),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(macosDockRunningSeparatorKey), findsNothing);

    setWindows(() => windows = <DenialWindow>[motionWindow(1)]);
    await tester.pumpAndSettle();

    expect(find.byKey(macosDockRunningSeparatorKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _SeparatorBridge extends DenialBridge {
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
