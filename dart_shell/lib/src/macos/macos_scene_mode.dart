import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/macos_design_gallery.dart';
import 'macos_desktop_scene.dart';

/// Whether the design gallery replaces the desktop scene.
class MacosGalleryOpenController extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;

  void close() => state = false;
}

final macosGalleryOpenProvider =
    NotifierProvider<MacosGalleryOpenController, bool>(
      MacosGalleryOpenController.new,
    );

/// Desktop content that switches between the real macOS desktop and the
/// design gallery. Both surfaces expose a button to reach the other.
class MacosSceneSwitcher extends ConsumerWidget {
  const MacosSceneSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(macosGalleryOpenProvider)) {
      return MacosDesignGallery(
        onExit: ref.read(macosGalleryOpenProvider.notifier).close,
      );
    }
    return const MacosDesktopScene();
  }
}
