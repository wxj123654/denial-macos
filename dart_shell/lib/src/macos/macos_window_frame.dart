import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

/// macOS window chrome around a Denial surface: a title bar with traffic
/// lights (left) and a centered window title above the client texture.
class MacosWindowFrame extends StatelessWidget {
  const MacosWindowFrame({
    super.key,
    required this.window,
    required this.actions,
    this.focused = true,
  });

  final DenialWindow window;
  final ShellWindowActions actions;
  final bool focused;

  static const double _titleBarHeight = 28;

  @override
  Widget build(BuildContext context) {
    final theme = MacosTheme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => actions.focus(window),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF000000).withValues(alpha: 0.35),
              blurRadius: focused ? 24 : 12,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: window.width.toDouble(),
              height: _titleBarHeight,
              decoration: BoxDecoration(
                color: dark
                    ? (focused
                          ? const Color(0xFF3B3B3D)
                          : const Color(0xFF2E2E30))
                    : (focused
                          ? const Color(0xFFECECEC)
                          : const Color(0xFFF6F6F6)),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(10),
                ),
                border: Border(
                  bottom: BorderSide(
                    color: dark
                        ? const Color(0xFF1C1C1E)
                        : const Color(0xFFD1D1D1),
                  ),
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 8,
                    child: _TrafficLights(
                      onClose: () => actions.close(window),
                    ),
                  ),
                  Text(
                    window.title.isNotEmpty ? window.title : window.appId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: dark
                          ? MacosColors.white.withValues(
                              alpha: focused ? 0.85 : 0.4,
                            )
                          : MacosColors.black.withValues(
                              alpha: focused ? 0.85 : 0.4,
                            ),
                    ),
                  ),
                ],
              ),
            ),
            WindowContentRect(
              window: window,
              active: focused,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(10),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Close/minimize/zoom traffic lights. Only Close is wired today: the public
/// shell action facade exposes focus/close, while minimize and zoom live on
/// the internal bridge used by the stock frame.
class _TrafficLights extends StatelessWidget {
  const _TrafficLights({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TrafficLight(color: const Color(0xFFFF5F57), onTap: onClose),
        const SizedBox(width: 8),
        const _TrafficLight(color: Color(0xFFFEBC2E)),
        const SizedBox(width: 8),
        const _TrafficLight(color: Color(0xFF28C840)),
      ],
    );
  }
}

class _TrafficLight extends StatelessWidget {
  const _TrafficLight({required this.color, this.onTap});

  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
