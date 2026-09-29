import 'dart:async';
import 'dart:math' as math;

import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/startup_environment.dart';
import '../desktop/desktop_pixel_alignment.dart';
import '../desktop/desktop_window_coordinator.dart';
import '../desktop/desktop_workspace.dart';
import '../desktop/retained_animated_positioned.dart';
import '../input/shell_interaction_registry.dart';
import '../models/display_layout.dart';
import '../platform/denial_bridge.dart';
import '../settings/settings_application.dart';
import '../settings/settings_controller.dart';
import '../settings/shell_settings.dart';
import '../state/display_layout.dart';
import '../state/shell_controller.dart';
import '../theme/motion.dart';
import 'macos_applications_surface.dart';
import 'macos_dock.dart';
import 'macos_dock_model.dart';
import 'macos_layout_calibration.dart';
import 'macos_menu_bar.dart';
import 'macos_theme_adapter.dart';
import '../widgets/window_surface_tree.dart';
import 'macos_window_frame.dart';

/// Top strip the native work area must reserve: the menu bar plus the
/// shell-painted title bar that sits above every window's client content.
const double macosWorkAreaTopInset =
    MacosMenuBar.height + MacosWindowFrame.titleBarHeight;

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
Rect macosWindowFrameRect(
  DesktopWindowPlacement placement, {
  MacosLayoutCalibration calibration = const MacosLayoutCalibration(),
}) {
  final content = placement.contentRect;
  final titleBarHeight = placement.drawsLiveServerFrame
      ? calibration.titleBarHeight
      : 0.0;
  return Rect.fromLTWH(
    content.left + calibration.offsetX,
    content.top - titleBarHeight + calibration.offsetY,
    content.width,
    content.height + titleBarHeight + calibration.heightDelta,
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
    ref.listenManual<ShellLayoutSettings>(
      shellSettingsProvider.select((settings) => settings.layout),
      (_, layout) => _reserveMenuBarWorkArea(layout),
      fireImmediately: true,
    );
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

  /// The macOS shell owns the only system strip, so the native work area is
  /// pinned below the menu bar and title bar regardless of the stock system
  /// bar thickness setting. Scheduled after the runtime bindings' own sync so
  /// this value is the last one applied.
  void _reserveMenuBarWorkArea(ShellLayoutSettings layout) {
    scheduleMicrotask(() {
      if (!mounted) {
        return;
      }
      ref
          .read(displayLayoutProvider.notifier)
          .applyShellConfiguration(
            side: SystemBarSide.top,
            outputNames: layout.systemBarOutputNames,
            systemBarThickness: macosWorkAreaTopInset,
            maximizePadding: layout.maximizePadding,
          );
    });
  }

  void _beginWindowMove(DenialWindow window) {
    ref.read(desktopWorkspaceProvider.notifier).beginMove(window.objectId);
  }

  void _moveWindow(DenialWindow window, Offset delta) {
    final workspace = ref.read(desktopWorkspaceProvider.notifier);
    final placement = ref
        .read(desktopWorkspaceProvider)
        .placements[window.objectId];
    if (placement == null) {
      return;
    }
    final minTop = macosWorkAreaTopInset;
    final dy = math.max(delta.dy, minTop - placement.contentRect.top);
    workspace.moveBy(window.objectId, Offset(delta.dx, dy));
    final moved = ref
        .read(desktopWorkspaceProvider)
        .placements[window.objectId];
    if (moved != null && moved.contentRect != placement.contentRect) {
      ref
          .read(denialBridgeProvider)
          .configureWindow(window, moved.contentRect);
    }
  }

  void _endWindowMove(DenialWindow window) {
    ref.read(desktopWorkspaceProvider.notifier).endMove(window.objectId);
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

  void _activateDockWindow(DenialWindow window) {
    ref.read(desktopWorkspaceProvider.notifier).activate(window.objectId);
    ref.read(shellControllerProvider.notifier).focusWindow(window);
  }

  /// Dock activation is macOS-style: it restores the application's minimized
  /// windows and raises the group's topmost window. A pinned entry with no
  /// windows launches its application instead.
  void _activateDockEntry(MacosDockEntry entry) {
    if (!entry.running) {
      final app = entry.app;
      if (app != null) {
        unawaited(_launchApplication(app));
      }
      return;
    }
    final workspace = ref.read(desktopWorkspaceProvider.notifier);
    for (final objectId in entry.minimizedObjectIds) {
      workspace.activate(objectId);
    }
    final target = entry.windows.lastWhere(
      (window) => !entry.minimizedObjectIds.contains(window.objectId),
      orElse: () => entry.windows.last,
    );
    workspace.activate(target.objectId);
    ref.read(shellControllerProvider.notifier).focusWindow(target);
  }

  void _minimizeDockEntry(MacosDockEntry entry) {
    final workspace = ref.read(desktopWorkspaceProvider.notifier);
    for (final window in entry.windows) {
      if (!entry.minimizedObjectIds.contains(window.objectId)) {
        workspace.toggleMinimized(window.objectId);
      }
    }
  }

  void _toggleDockPin(MacosDockEntry entry) {
    final pins = ref.read(macosDockPinsProvider.notifier);
    if (pins.isPinned(entry.pinId)) {
      pins.unpin(entry.pinId);
    } else {
      pins.pin(entry.pinId);
    }
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
    ref.watch(desktopWindowCoordinatorProvider);
    ref.listen<int?>(
      shellControllerProvider.select((state) => state.foregroundObjectId),
      (previous, next) {
        final desktop = ref.read(desktopWorkspaceProvider);
        final nextPlacement = next == null ? null : desktop.placements[next];
        if (next != null &&
            next != previous &&
            !desktop.overviewActive &&
            nextPlacement?.minimized != true) {
          ref.read(desktopWorkspaceProvider.notifier).activate(next);
        }
      },
    );
    final workspace = ref.watch(desktopWorkspaceProvider);
    final displayLayout = ref.watch(displayLayoutProvider);
    final calibration = ref.watch(macosLayoutCalibrationProvider);
    final pinnedIds = ref.watch(macosDockPinsProvider);
    final desktopAppSlots = ref.watch(
      homeGridControllerProvider.select((state) => state.asData?.value.slots),
    );
    final appLauncher = ref.watch(appLauncherProvider);
    final installedApps = macosInstalledApplications(desktopAppSlots);
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
              final dockEntries = macosDockEntries(
                windows: windows,
                placements: workspace.placements,
                installedApps: installedApps,
                expectedWindowAppIds: appLauncher.expectedWindowAppIds,
                pinnedIds: pinnedIds,
                foregroundObjectId: frontmost?.objectId,
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  _MacosLayerSurfaces(displayLayout: displayLayout, top: false),
                  for (var i = 0; i < visible.length; i++)
                    Positioned.fromRect(
                      rect: macosWindowFrameRect(
                        visible[i].placement,
                        calibration: calibration,
                      ),
                      child: MacosWindowFrame(
                        window: visible[i].window,
                        actions: actions,
                        contentSize: Size(
                          visible[i].placement.contentRect.width,
                          visible[i].placement.contentRect.height +
                              calibration.heightDelta,
                        ),
                        showFrame: visible[i].placement.drawsLiveServerFrame,
                        focused: i == visible.length - 1,
                        titleHeight: calibration.titleBarHeight,
                        presentationScale: desktopOutputPixelGridForMonitor(
                          displayLayout,
                          visible[i].placement.monitorId,
                        )?.scale,
                        pixelGridOrigin:
                            desktopOutputPixelGridForMonitor(
                              displayLayout,
                              visible[i].placement.monitorId,
                            )?.logicalRect.topLeft ??
                            Offset.zero,
                        onMoveStart: () => _beginWindowMove(visible[i].window),
                        onMoveUpdate: (delta) =>
                            _moveWindow(visible[i].window, delta),
                        onMoveEnd: () => _endWindowMove(visible[i].window),
                      ),
                    ),
                  for (final entry in visible)
                    _MacosWindowPopups(
                      key: ValueKey<int>(entry.window.objectId),
                      window: entry.window,
                      contentRect: entry.placement.contentRect,
                      monitorId: entry.placement.monitorId,
                      displayLayout: displayLayout,
                    ),
                  _MacosPopupSurfaces(displayLayout: displayLayout),
                  _MacosLayerSurfaces(displayLayout: displayLayout, top: true),
                  if (calibration.showOutlines)
                    for (final entry in visible) ...[
                      Positioned.fromRect(
                        rect: entry.placement.contentRect,
                        child: const IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.fromBorderSide(
                                BorderSide(color: Color(0xffff0000), width: 2),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned.fromRect(
                        rect: macosWindowFrameRect(
                          entry.placement,
                          calibration: calibration,
                        ),
                        child: const IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.fromBorderSide(
                                BorderSide(color: Color(0xff0066ff), width: 2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  const Positioned(
                    left: 12,
                    bottom: 12,
                    child: ShellInputRegion(
                      debugLabel: 'macos-calibration',
                      child: MacosCalibrationPanel(),
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
                          entries: dockEntries,
                          onOpenApplications: _toggleApplications,
                          onOpenSettings: _openSettings,
                          onActivateEntry: _activateDockEntry,
                          onActivateWindow: _activateDockWindow,
                          onMinimizeEntry: _minimizeDockEntry,
                          onQuitEntry: (entry) {
                            for (final window in entry.windows) {
                              actions.close(window);
                            }
                          },
                          onTogglePin: _toggleDockPin,
                          onPinApp: (desktopFileId) => ref
                              .read(macosDockPinsProvider.notifier)
                              .pin(desktopFileId),
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
                      child: MacosMenuBar(
                        frontmostApp: frontmost?.appId,
                        onOpenSpotlight: _openApplications,
                      ),
                    ),
                  ),
                  if (_applicationsOpen)
                    Positioned.fill(
                      child: MacosApplicationsSurface(
                        key: macosApplicationsSurfaceKey,
                        searchFocusNode: _searchFocusNode,
                        onDismiss: _closeApplications,
                        onLaunch: _launchApplication,
                        onOpenSettings: _openSettings,
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

/// Layer-shell clients below (background/bottom) or above (top/overlay) the
/// windows. Watches only the layer list so window churn cannot rebuild the
/// scene through it; native input routing owns pointer events.
class _MacosLayerSurfaces extends ConsumerWidget {
  const _MacosLayerSurfaces({required this.displayLayout, required this.top});

  final DisplayLayout? displayLayout;
  final bool top;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaces = ref.watch(
      shellControllerProvider.select((state) => state.layerSurfaces),
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final surface in surfaces)
              if ((surface.contentKind ==
                          DenialWindowContentKind.layerShellTop ||
                      surface.contentKind ==
                          DenialWindowContentKind.layerShellOverlay) ==
                  top)
                if (surface.geometry case final geometry?)
                  if (surface.surfaceLayers.isNotEmpty)
                    Positioned.fromRect(
                      key: ValueKey<String>('layer-${surface.surfaceId}'),
                      rect: geometry,
                      child: RepaintBoundary(
                        child: _surfaceTree(surface, displayLayout, true),
                      ),
                    ),
          ],
        ),
      ),
    );
  }
}

WindowSurfaceTree _surfaceTree(
  DenialWindow window,
  DisplayLayout? layout,
  bool includePopups,
) {
  final grid = desktopOutputPixelGridForMonitor(layout, window.monitorId);
  return WindowSurfaceTree(
    window: window,
    includePopups: includePopups,
    presentationScale: grid?.scale,
    pixelGridOrigin: grid?.logicalRect.topLeft ?? Offset.zero,
  );
}

/// Popup surfaces that belong to no window (input-method candidate lists).
/// Isolated in its own consumer so frequent candidate updates repaint only
/// this layer, and animated like the stock desktop.
class _MacosPopupSurfaces extends ConsumerWidget {
  const _MacosPopupSurfaces({required this.displayLayout});

  final DisplayLayout? displayLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final windows = ref.watch(
      shellControllerProvider.select((state) => state.windows),
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final popup in windows)
              if (popup.isPopupSurface)
                if (popup.geometry case final geometry?)
                  RetainedAnimatedPositioned(
                    key: ValueKey<String>('popup-surface-${popup.objectId}'),
                    duration: reduceMotion
                        ? Duration.zero
                        : Motion.inputMethodPopup,
                    curve: Motion.standard,
                    rect: geometry,
                    child: RepaintBoundary(
                      child: _surfaceTree(popup, displayLayout, true),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

/// Popup layers (menus, tooltips) of one window. Rebuilds only when that
/// window's snapshot changes.
class _MacosWindowPopups extends ConsumerWidget {
  const _MacosWindowPopups({
    super.key,
    required this.window,
    required this.contentRect,
    required this.monitorId,
    required this.displayLayout,
  });

  final DenialWindow window;
  final Rect contentRect;
  final int monitorId;
  final DisplayLayout? displayLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current =
        ref.watch(
          shellControllerProvider.select(
            (state) => state.windowByObjectId(window.objectId),
          ),
        ) ??
        window;
    final grid = desktopOutputPixelGridForMonitor(displayLayout, monitorId);
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (final layer in current.popupSurfaceLayers)
              if (layer.textureId > 0)
                Positioned.fromRect(
                  key: ValueKey<int>(layer.surfaceId),
                  rect: current.mapSurfaceRect(layer, contentRect),
                  child: RepaintBoundary(
                    child: SurfaceLayerTexture(
                      layer: layer,
                      presentationScale: grid?.scale,
                      pixelGridOrigin:
                          grid?.logicalRect.topLeft ?? Offset.zero,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
