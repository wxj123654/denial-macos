import 'package:denial_dart_shell/denial.dart';
import 'package:denial_dart_shell/macos_design_gallery.dart';
import 'package:flutter/widgets.dart';

/// Standalone Denial shell that renders only the macOS 26 design gallery.
///
/// To view it, temporarily make `lib/main.dart` call this `main`, or attach a
/// live-development workspace whose `lib/main.dart` matches this file.
void main() {
  runDenialShell(
    shell: const DenialShell(
      mobile: DenialShellScene(content: MacosDesignGallery()),
      desktop: DenialShellScene(content: MacosDesignGallery()),
    ),
  );
}
