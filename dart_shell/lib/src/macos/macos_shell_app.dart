import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';

import 'macos_desktop_scene.dart';
import 'macos_mobile_scene.dart';

/// Product shell assembled from Denial's reusable host and macOS-styled scenes.
///
/// Mirrors `DenialShellApp`: compositor lifecycle, lock, overlay, and input
/// plumbing stay inside [DenialShell]; this widget only chooses the feature
/// scenes that render in the macOS design language.
class MacosShellApp extends StatelessWidget {
  const MacosShellApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const DenialShell(
      mobile: DenialShellScene(content: MacosMobileScene()),
      desktop: DenialShellScene(content: MacosDesktopScene()),
    );
  }
}
