import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// Centered Dock listing running application windows. Tapping an icon focuses
/// the window through the shell's semantic actions.
class MacosDock extends StatelessWidget {
  const MacosDock({super.key, required this.windows, required this.actions});

  final List<DenialWindow> windows;
  final ShellWindowActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: (dark ? MacosColors.black : MacosColors.white).withValues(
          alpha: 0.5,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: (dark ? MacosColors.white : MacosColors.black).withValues(
            alpha: 0.12,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final window in windows)
            _DockIcon(window: window, onTap: () => actions.focus(window)),
        ],
      ),
    );
  }
}

class _DockIcon extends StatelessWidget {
  const _DockIcon({required this.window, required this.onTap});

  final DenialWindow window;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    final source = window.appId.isNotEmpty ? window.appId : window.title;
    final label = source.trim().isEmpty
        ? '?'
        : source.trim().substring(0, 1).toUpperCase();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(11),
              ),
              alignment: Alignment.center,
              child: Text(
                (label ?? '?').toUpperCase(),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: MacosColors.white,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                color: MacosColors.white,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
