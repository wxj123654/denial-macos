import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';

import 'macos_dock.dart';
import 'macos_menu_bar.dart';
import 'macos_theme_adapter.dart';
import 'macos_window_frame.dart';

/// Desktop scene composed in the macOS layout: wallpaper, floating framed
/// windows, a top menu bar, and a centered Dock.
class MacosDesktopScene extends StatelessWidget {
  const MacosDesktopScene({super.key});

  @override
  Widget build(BuildContext context) {
    return MacosThemeScope(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ShellWallpaper(),
          ShellWindowsBuilder(
            builder: (context, windows, actions) {
              final frontmost = windows.isEmpty ? null : windows.last;
              return Stack(
                fit: StackFit.expand,
                children: [
                  for (var i = 0; i < windows.length; i++)
                    Positioned(
                      left: 48.0 + i * 40.0,
                      top: 64.0 + i * 32.0,
                      child: MacosWindowFrame(
                        window: windows[i],
                        focused: windows[i] == frontmost,
                        actions: actions,
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 8,
                    child: Center(
                      child: MacosDock(windows: windows, actions: actions),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: MacosMenuBar(frontmostApp: frontmost?.appId),
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
