import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// Top menu bar in the macOS style: Apple menu, the frontmost application's
/// name, and a clock on the right.
class MacosMenuBar extends StatelessWidget {
  const MacosMenuBar({super.key, this.frontmostApp});

  final String? frontmostApp;

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
          const _MenuBarClock(),
        ],
      ),
    );
  }
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
