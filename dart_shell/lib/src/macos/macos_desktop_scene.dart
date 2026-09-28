import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../desktop/desktop_workspace.dart';
import '../input/shell_interaction_registry.dart';
import 'macos_dock.dart';
import 'macos_menu_bar.dart';
import 'macos_theme_adapter.dart';
import 'macos_window_frame.dart';

typedef MacosWindowPlacement = ({
  DenialWindow window,
  DesktopWindowPlacement placement,
});

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
/// windows, a top menu bar, and a centered Dock.
class MacosDesktopScene extends ConsumerWidget {
  const MacosDesktopScene({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
