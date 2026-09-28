import 'dart:async';

import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../desktop/desktop_workspace.dart';
import '../input/shell_interaction_registry.dart';
import '../platform/denial_bridge.dart';
import '../settings/settings_application.dart';
import '../state/shell_controller.dart';
import 'macos_applications_surface.dart';
import 'macos_dock.dart';
import 'macos_menu_bar.dart';
import 'macos_theme_adapter.dart';
import 'macos_window_frame.dart';

typedef MacosWindowPlacement = ({
  DenialWindow window,
  DesktopWindowPlacement placement,
});

/// Phase 1 scene intents for compositor shell actions. Actions without a
/// macOS Phase 1 surface return `null` and are ignored.
enum MacosShellSceneAction { toggleApplications, openSettings }

MacosShellSceneAction? macosShellSceneActionFor(DenialShellAction action) {
  return switch (action) {
    DenialShellAction.applications => MacosShellSceneAction.toggleApplications,
    DenialShellAction.openSettings => MacosShellSceneAction.openSettings,
    _ => null,
  };
}

/// Visible macOS scene entries in the same back-to-front stack order that
/// native input publication uses.
List<MacosWindowPlacement> macosVisibleWindowPlacements({
  required List<DenialWindow> windows,
  required DesktopWorkspaceState workspace,
}) {
  final windowsById = <int, DenialWindow>{
    for (final window in windows)
      if (window.isUserApp) window.objectId: window,
  };
  final placements =
      workspace.placements.values
          .where(
            (placement) =>
                !placement.minimized &&
                workspace.isPlacementOnActiveWorkspace(placement) &&
                windowsById.containsKey(placement.objectId),
          )
          .toList(growable: false)
        ..sort(
          (left, right) => compareDesktopWindowStack(left, right, windowsById),
        );
  return <MacosWindowPlacement>[
    for (final placement in placements)
      (window: windowsById[placement.objectId]!, placement: placement),
  ];
}

/// The painted window frame for [placement]: the native-routed client
/// content rect plus the shell-owned title bar strip above it.
Rect macosWindowFrameRect(DesktopWindowPlacement placement) {
  final content = placement.contentRect;
  final titleBarHeight = placement.drawsLiveServerFrame
      ? MacosWindowFrame.titleBarHeight
      : 0.0;
  return Rect.fromLTWH(
    content.left,
    content.top - titleBarHeight,
    content.width,
    content.height + titleBarHeight,
  );
}

/// Desktop scene composed in the macOS layout: wallpaper, floating framed
/// windows, a top menu bar, a centered Dock, and the Apps surface while it
/// is open.
class MacosDesktopScene extends ConsumerStatefulWidget {
  const MacosDesktopScene({super.key});

  @override
  ConsumerState<MacosDesktopScene> createState() => _MacosDesktopSceneState();
}

class _MacosDesktopSceneState extends ConsumerState<MacosDesktopScene> {
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'macos-applications-search',
  );
  late final StreamSubscription<DenialShellActionEvent>
  _shellActionSubscription;
  late final ProviderSubscription<bool> _lockSubscription;
  bool _applicationsOpen = false;

  @override
  void initState() {
    super.initState();
    _shellActionSubscription = ref
        .read(denialBridgeProvider)
        .shellActions
        .listen(_handleShellAction);
    _lockSubscription = ref.listenManual<bool>(
      shellControllerProvider.select((state) => state.locked),
      (previous, locked) {
        if (locked) {
          _closeApplications();
        }
      },
    );
  }

  @override
  void dispose() {
    unawaited(_shellActionSubscription.cancel());
    _lockSubscription.close();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _handleShellAction(DenialShellActionEvent event) {
    switch (macosShellSceneActionFor(event.action)) {
      case MacosShellSceneAction.toggleApplications:
        _toggleApplications();
      case MacosShellSceneAction.openSettings:
        _openSettings();
      case null:
        break;
    }
  }

  void _toggleApplications() {
    if (_applicationsOpen) {
      _closeApplications();
      return;
    }
    _openApplications();
  }

  void _openApplications() {
    if (_applicationsOpen) {
      return;
    }
    setState(() => _applicationsOpen = true);
    unawaited(
      ref
          .read(homeGridControllerProvider.notifier)
          .refreshDesktopApps(reason: 'launcher-visible'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _closeApplications() {
    if (!mounted || !_applicationsOpen) {
      return;
    }
    setState(() => _applicationsOpen = false);
    _searchFocusNode.unfocus();
  }

  Future<void> _launchApplication(DesktopApp app) async {
    _closeApplications();
    ref
        .read(applicationRecentsProvider.notifier)
        .record(desktopApplicationRecentId(app.id));
    final launcher = ref.read(appLauncherProvider);
    final shell = ref.read(shellControllerProvider.notifier);
    final expectedIds = launcher.expectedWindowAppIds(app);
    if (launcher.usesLegacyTextInput(app)) {
      shell.registerLegacyTextInputAppIds(expectedIds);
    }
    final existing = launcher.findOpenWindow(
      app,
      ref.read(shellControllerProvider).openAppWindows,
    );
    if (existing != null) {
      ref.read(desktopWorkspaceProvider.notifier).activate(existing.objectId);
      shell.focusWindow(existing);
      return;
    }
    await launcher.launch(app);
  }

  void _openSettings() {
    _closeApplications();
    final shellState = ref.read(shellControllerProvider);
    for (final window in shellState.openAppWindows) {
      if (isDenialSettingsApplicationId(window.appId)) {
        ref.read(desktopWorkspaceProvider.notifier).activate(window.objectId);
        ref.read(shellControllerProvider.notifier).focusWindow(window);
        return;
      }
    }
    final configured = ref
        .read(startupEnvironmentProvider)['DENIAL_SETTINGS_BINARY']
        ?.trim();
    final executable = configured == null || configured.isEmpty
        ? 'denial-settings'
        : configured;
    ref.read(denialBridgeProvider).launchApplication(<String>[executable]);
  }

  @override
  Widget build(BuildContext context) {
    final workspace = ref.watch(desktopWorkspaceProvider);
    return MacosThemeScope(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ShellWallpaper(),
          ShellWindowsBuilder(
            builder: (context, windows, actions) {
              final visible = macosVisibleWindowPlacements(
                windows: windows,
                workspace: workspace,
              );
              final frontmost = visible.isEmpty ? null : visible.last.window;
              return Stack(
                fit: StackFit.expand,
                children: [
                  for (var i = 0; i < visible.length; i++)
                    Positioned.fromRect(
                      rect: macosWindowFrameRect(visible[i].placement),
                      child: MacosWindowFrame(
                        window: visible[i].window,
                        actions: actions,
                        contentSize: visible[i].placement.contentRect.size,
                        showFrame: visible[i].placement.drawsLiveServerFrame,
                        focused: i == visible.length - 1,
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 8,
                    child: Center(
                      child: ShellInputRegion(
                        debugLabel: 'macos-dock',
                        child: MacosDock(
                          windows: [for (final entry in visible) entry.window],
                          actions: actions,
                          onOpenApplications: _toggleApplications,
                          onOpenSettings: _openSettings,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: ShellInputRegion(
                      debugLabel: 'macos-menu-bar',
                      child: MacosMenuBar(frontmostApp: frontmost?.appId),
                    ),
                  ),
                  if (_applicationsOpen)
                    Positioned.fill(
                      child: MacosApplicationsSurface(
                        key: macosApplicationsSurfaceKey,
                        searchFocusNode: _searchFocusNode,
                        onDismiss: _closeApplications,
                        onLaunch: _launchApplication,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
