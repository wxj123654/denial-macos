import 'package:denial_dart_shell/denial.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

/// Wraps shell chrome in a [MacosTheme] derived from Denial's appearance
/// settings, so macos_ui widgets follow the shell's brightness and accent
/// choices instead of a fixed look.
class MacosThemeScope extends ConsumerWidget {
  const MacosThemeScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(
      shellSettingsProvider.select((settings) => settings.appearance),
    );
    final dark =
        appearance.colorSchemePreference.effectiveBrightness == Brightness.dark;
    final accent = accentFromColor(appearance.customAccentColor);
    return MacosTheme(
      data: dark
          ? MacosThemeData.dark(accentColor: accent, isMainWindow: true)
          : MacosThemeData.light(accentColor: accent, isMainWindow: true),
      child: child,
    );
  }
}

/// Maps an arbitrary accent color to the closest macOS [AccentColor] preset.
AccentColor accentFromColor(Color color) {
  final hsv = HSVColor.fromColor(color);
  if (hsv.saturation < 0.15) {
    return AccentColor.graphite;
  }
  final hue = hsv.hue;
  if (hue < 15 || hue >= 340) return AccentColor.red;
  if (hue < 45) return AccentColor.orange;
  if (hue < 75) return AccentColor.yellow;
  if (hue < 165) return AccentColor.green;
  if (hue < 255) return AccentColor.blue;
  if (hue < 295) return AccentColor.purple;
  return AccentColor.pink;
}
