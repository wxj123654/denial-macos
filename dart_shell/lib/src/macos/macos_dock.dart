import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../localization/denial_localizations.dart';

/// Key for the persistent Apps entry in the macOS Dock.
const macosDockApplicationsKey = ValueKey<String>('macos-dock-applications');

/// Key for the persistent System Settings entry in the macOS Dock.
const macosDockSettingsKey = ValueKey<String>('macos-dock-settings');

/// Key for the divider between persistent items and running windows.
const macosDockRunningSeparatorKey = ValueKey<String>(
  'macos-dock-running-separator',
);

/// Centered Dock with persistent shell items (Apps and Settings) followed by
/// the running application windows. Tapping a window icon focuses the window
/// through the shell's semantic actions.
class MacosDock extends StatelessWidget {
  const MacosDock({
    super.key,
    required this.windows,
    required this.actions,
    required this.onOpenApplications,
    required this.onOpenSettings,
  });

  final List<DenialWindow> windows;
  final ShellWindowActions actions;
  final VoidCallback onOpenApplications;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final l10n = context.l10n;
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
          _PersistentDockItem(
            key: macosDockApplicationsKey,
            icon: CupertinoIcons.square_grid_3x2,
            label: l10n.desktopApplicationsTitle,
            onTap: onOpenApplications,
          ),
          _PersistentDockItem(
            key: macosDockSettingsKey,
            icon: CupertinoIcons.gear_solid,
            label: l10n.settingsApplicationTitle,
            onTap: onOpenSettings,
          ),
          if (windows.isNotEmpty) ...[
            Container(
              key: macosDockRunningSeparatorKey,
              width: 1,
              height: 36,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              color: (dark ? MacosColors.white : MacosColors.black).withValues(
                alpha: 0.18,
              ),
            ),
            for (final window in windows)
              _DockIcon(window: window, onTap: () => actions.focus(window)),
          ],
        ],
      ),
    );
  }
}

class _PersistentDockItem extends StatelessWidget {
  const _PersistentDockItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = MacosTheme.of(context).primaryColor;
    return Semantics(
      button: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 22, color: MacosColors.white),
          ),
        ),
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
