import 'dart:async';

import 'package:denial_dart_shell/src/launcher/controllers/application_recents_controller.dart';
import 'package:denial_dart_shell/src/launcher/controllers/home_grid_controller.dart';
import 'package:denial_dart_shell/src/launcher/models/home_grid_item.dart';
import 'package:denial_dart_shell/src/macos/macos_applications_surface.dart';
import 'package:denial_dart_shell/src/macos/macos_desktop_scene.dart';
import 'package:denial_dart_shell/src/models/display_layout.dart';
import 'package:denial_dart_shell/src/platform/denial_bridge.dart';
import 'package:denial_dart_shell/src/settings/settings_controller.dart';
import 'package:denial_dart_shell/src/settings/shell_settings.dart';
import 'package:denial_dart_shell/src/state/display_layout.dart';
import 'package:denial_dart_shell/src/state/shell_controller.dart';
import 'package:denial_dart_shell/src/state/shell_state.dart';
import 'package:denial_dart_shell/src/wallpaper/state/wallpaper_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/mobile_motion_harness.dart';

void main() {
  testWidgets('locking the shell dismisses the open Apps surface', (
    tester,
  ) async {
    final shell = _SceneShell();
    final bridge = _SceneBridge();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          denialBridgeProvider.overrideWithValue(bridge),
          shellControllerProvider.overrideWith(() => shell),
          displayLayoutProvider.overrideWith(() => _NoDisplayLayout()),
          wallpaperControllerProvider.overrideWith(() => _NoWallpaper()),
          shellSettingsProvider.overrideWith(() => _NoShellSettings()),
          homeGridControllerProvider.overrideWith(() => _SceneGrid()),
          applicationRecentsProvider.overrideWith(
            () => _SceneRecents(const <String>[]),
          ),
        ],
        child: mobileMotionHarness(
          const MacosDesktopScene(),
          size: const Size(1280, 800),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(macosApplicationsSurfaceKey), findsNothing);

    bridge.emitShellAction(DenialShellAction.applications);
    await tester.pumpAndSettle();
    expect(find.byKey(macosApplicationsSurfaceKey), findsOneWidget);

    shell.lock();
    await tester.pumpAndSettle();
    expect(find.byKey(macosApplicationsSurfaceKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _SceneShell extends ShellController {
  @override
  ShellState build() => ShellState.initial();

  void lock() => state = ShellState.initial(locked: true);
}

class _SceneBridge extends DenialBridge {
  final StreamController<DenialShellActionEvent> _shellActions =
      StreamController<DenialShellActionEvent>.broadcast();

  @override
  Stream<DenialShellActionEvent> get shellActions => _shellActions.stream;

  void emitShellAction(DenialShellAction action) {
    _shellActions.add(
      DenialShellActionEvent(
        action: action,
        monitorId: null,
        requestId: 0,
        textureId: null,
        workspaceId: null,
      ),
    );
  }
}

class _NoDisplayLayout extends DisplayLayoutController {
  @override
  DisplayLayout? build() => null;
}

class _NoWallpaper extends WallpaperController {
  @override
  WallpaperExperienceState build() => WallpaperExperienceState.initial();
}

class _NoShellSettings extends ShellSettingsController {
  @override
  ShellSettings build() => const ShellSettings();
}

class _SceneGrid extends HomeGridController {
  @override
  Future<HomeGridState> build() async =>
      HomeGridState(slots: <HomeGridItem?>[]);

  @override
  void setLauncherActive(bool active) {}

  @override
  Future<void> refreshDesktopApps({String reason = 'manual'}) async {}
}

class _SceneRecents extends ApplicationRecentsController {
  _SceneRecents(this.entries);

  final List<String> entries;

  @override
  List<String> build() => entries;
}
