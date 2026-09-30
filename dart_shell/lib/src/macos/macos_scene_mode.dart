import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../input/shell_interaction_registry.dart';
import 'design/liquid_glass_lab.dart';
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

/// Whether the liquid-glass shader lab replaces the gallery.
class MacosGlassLabOpenController extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;

  void close() => state = false;
}

final macosGlassLabOpenProvider =
    NotifierProvider<MacosGlassLabOpenController, bool>(
      MacosGlassLabOpenController.new,
    );

/// Desktop content that switches between the real macOS desktop and the
/// design gallery. Both surfaces expose a button to reach the other.
class MacosSceneSwitcher extends ConsumerWidget {
  const MacosSceneSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(macosGalleryOpenProvider)) {
      if (ref.watch(macosGlassLabOpenProvider)) {
        return Stack(
          fit: StackFit.expand,
          children: [
            const ShellInputRegion(
              debugLabel: 'glass-lab',
              pointerPolicy: ShellPointerPolicy.childBounds,
              child: LiquidGlassLab(),
            ),
            Positioned(
              left: 24,
              top: 24,
              child: ShellInputRegion(
                debugLabel: 'glass-lab-back',
                child: GestureDetector(
                  onTap: ref.read(macosGlassLabOpenProvider.notifier).close,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(color: Color(0xaa000000)),
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: Text(
                        'Back',
                        style: TextStyle(
                          color: Color(0xffffffff),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      }
      return MacosDesignGallery(
        onExit: ref.read(macosGalleryOpenProvider.notifier).close,
        onGlassLab: ref.read(macosGlassLabOpenProvider.notifier).open,
      );
    }
    return const MacosDesktopScene();
  }
}
