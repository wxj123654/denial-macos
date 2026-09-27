import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';

/// Minimal functional mobile scene. The macOS skin is a desktop design; this
/// fallback keeps the phone profile usable until a mobile design exists.
class MacosMobileScene extends StatelessWidget {
  const MacosMobileScene({super.key});

  @override
  Widget build(BuildContext context) {
    return const Stack(
      fit: StackFit.expand,
      children: [ShellWallpaper(), ShellPrimaryWindow()],
    );
  }
}
