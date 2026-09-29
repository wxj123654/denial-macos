import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../localization/denial_localizations.dart';
import '../widgets/shell_cursor.dart';

/// Key for the menu-bar Spotlight search affordance.
const macosMenuBarSpotlightKey = ValueKey<String>('macos-menu-bar-spotlight');

/// Top menu bar in the macOS style: Apple menu, the frontmost application's
/// name, and a clock on the right. When [onOpenSpotlight] is provided, a
/// magnifier affordance ahead of the clock opens the Spotlight surface.
class MacosMenuBar extends StatelessWidget {
  const MacosMenuBar({super.key, this.frontmostApp, this.onOpenSpotlight});

  final String? frontmostApp;

  /// Opens the Spotlight/Apps surface; when `null` the magnifier is omitted.
  final VoidCallback? onOpenSpotlight;

  static const double height = 26;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = dark ? MacosColors.white : MacosColors.black;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: (dark ? MacosColors.black : MacosColors.white).withValues(
        alpha: 0.72,
      ),
      child: Row(
        children: [
          Text('', style: TextStyle(fontSize: 15, color: foreground)),
          const SizedBox(width: 16),
          Text(
            frontmostApp?.isNotEmpty == true ? frontmostApp! : 'Finder',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: foreground,
            ),
          ),
          const Spacer(),
          if (onOpenSpotlight != null)
            _MenuBarSpotlightButton(onPressed: onOpenSpotlight!),
          if (onOpenSpotlight != null) const SizedBox(width: 12),
          const _MenuBarClock(),
        ],
      ),
    );
  }
}

class _MenuBarSpotlightButton extends StatefulWidget {
  const _MenuBarSpotlightButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_MenuBarSpotlightButton> createState() =>
      _MenuBarSpotlightButtonState();
}

class _MenuBarSpotlightButtonState extends State<_MenuBarSpotlightButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final foreground = MacosTheme.of(context).brightness == Brightness.dark
        ? MacosColors.white
        : MacosColors.black;
    return Semantics(
      button: true,
      label: context.l10n.macosSpotlightMenuBarLabel,
      child: MouseRegion(
        cursor: ShellMouseCursors.link,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          key: macosMenuBarSpotlightKey,
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox.square(
            dimension: _extent,
            child: Icon(
              CupertinoIcons.search,
              size: 14,
              color: foreground.withValues(alpha: _hovered ? 1 : 0.75),
            ),
          ),
        ),
      ),
    );
  }

  static const double _extent = 20;
}

class _MenuBarClock extends StatelessWidget {
  const _MenuBarClock();

  @override
  Widget build(BuildContext context) {
    final foreground = MacosTheme.of(context).brightness == Brightness.dark
        ? MacosColors.white
        : MacosColors.black;
    return StreamBuilder<DateTime>(
      stream: Stream<DateTime>.periodic(
        const Duration(seconds: 1),
        (_) => DateTime.now(),
      ),
      builder: (context, snapshot) {
        final now = snapshot.data ?? DateTime.now();
        final hh = now.hour.toString().padLeft(2, '0');
        final mm = now.minute.toString().padLeft(2, '0');
        return Text(
          '$hh:$mm',
          style: TextStyle(fontSize: 13, color: foreground),
        );
      },
    );
  }
}
