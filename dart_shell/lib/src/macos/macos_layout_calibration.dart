import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'design/macos_controls.dart';
import 'design/macos_design_tokens.dart';
import 'macos_scene_mode.dart';
import 'macos_window_frame.dart';

/// Live, session-only knobs for aligning the painted macOS window chrome with
/// the native client rectangle. Nothing here is persisted or sent to the
/// compositor: it only moves and resizes what Flutter paints, so it is safe
/// to experiment with and to reset.
@immutable
class MacosLayoutCalibration {
  const MacosLayoutCalibration({
    this.titleBarHeight = MacosWindowFrame.titleBarHeight,
    this.offsetX = 0,
    this.offsetY = 0,
    this.heightDelta = 0,
    this.showOutlines = false,
  });

  /// Height of the painted title strip above the client content.
  final double titleBarHeight;

  /// Shift applied to the whole painted frame (title bar and content).
  final double offsetX;
  final double offsetY;

  /// Added to the painted content height (negative trims the bottom).
  final double heightDelta;

  /// Draws the native content rect (red) and painted frame (blue).
  final bool showOutlines;

  MacosLayoutCalibration copyWith({
    double? titleBarHeight,
    double? offsetX,
    double? offsetY,
    double? heightDelta,
    bool? showOutlines,
  }) => MacosLayoutCalibration(
    titleBarHeight: titleBarHeight ?? this.titleBarHeight,
    offsetX: offsetX ?? this.offsetX,
    offsetY: offsetY ?? this.offsetY,
    heightDelta: heightDelta ?? this.heightDelta,
    showOutlines: showOutlines ?? this.showOutlines,
  );

  @override
  bool operator ==(Object other) =>
      other is MacosLayoutCalibration &&
      other.titleBarHeight == titleBarHeight &&
      other.offsetX == offsetX &&
      other.offsetY == offsetY &&
      other.heightDelta == heightDelta &&
      other.showOutlines == showOutlines;

  @override
  int get hashCode =>
      Object.hash(titleBarHeight, offsetX, offsetY, heightDelta, showOutlines);

  @override
  String toString() =>
      'titleBarHeight=$titleBarHeight offsetX=$offsetX offsetY=$offsetY '
      'heightDelta=$heightDelta';
}

class MacosLayoutCalibrationController
    extends Notifier<MacosLayoutCalibration> {
  @override
  MacosLayoutCalibration build() => const MacosLayoutCalibration();

  void update(MacosLayoutCalibration Function(MacosLayoutCalibration) change) =>
      state = change(state);

  void reset() => state = const MacosLayoutCalibration();
}

final macosLayoutCalibrationProvider =
    NotifierProvider<MacosLayoutCalibrationController, MacosLayoutCalibration>(
      MacosLayoutCalibrationController.new,
    );

/// Collapsed chip that expands into the calibration panel.
class MacosCalibrationPanel extends ConsumerStatefulWidget {
  const MacosCalibrationPanel({super.key});

  @override
  ConsumerState<MacosCalibrationPanel> createState() =>
      _MacosCalibrationPanelState();
}

class _MacosCalibrationPanelState extends ConsumerState<MacosCalibrationPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(macosLayoutCalibrationProvider);
    final controller = ref.read(macosLayoutCalibrationProvider.notifier);
    return MacosPaletteScope(
      palette: MacosPalette.dark,
      child: DefaultTextStyle(
        style: MacosType.body.copyWith(color: MacosPalette.dark.label),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xe6101014),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.all(MacosSpacing.md),
            child: SizedBox(
              width: _open ? 300 : null,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: _open
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MacosButton(
                        label: _open ? 'Hide calibration' : 'Calibrate',
                        onPressed: () => setState(() => _open = !_open),
                      ),
                      const SizedBox(width: MacosSpacing.sm),
                      MacosButton(
                        label: 'Gallery',
                        prominent: true,
                        onPressed: ref
                            .read(macosGalleryOpenProvider.notifier)
                            .open,
                      ),
                    ],
                  ),
                  if (_open) ...[
                    const SizedBox(height: MacosSpacing.md),
                    _StepRow(
                      label: 'Title bar height',
                      value: value.titleBarHeight,
                      onChanged: (v) => controller.update(
                        (c) => c.copyWith(titleBarHeight: v.clamp(0, 80)),
                      ),
                    ),
                    _StepRow(
                      label: 'Offset X',
                      value: value.offsetX,
                      onChanged: (v) =>
                          controller.update((c) => c.copyWith(offsetX: v)),
                    ),
                    _StepRow(
                      label: 'Offset Y',
                      value: value.offsetY,
                      onChanged: (v) =>
                          controller.update((c) => c.copyWith(offsetY: v)),
                    ),
                    _StepRow(
                      label: 'Height delta',
                      value: value.heightDelta,
                      onChanged: (v) =>
                          controller.update((c) => c.copyWith(heightDelta: v)),
                    ),
                    Row(
                      children: [
                        MacosSwitch(
                          value: value.showOutlines,
                          onChanged: (v) => controller.update(
                            (c) => c.copyWith(showOutlines: v),
                          ),
                        ),
                        const SizedBox(width: MacosSpacing.sm),
                        const Expanded(
                          child: Text('Outlines: red = native, blue = painted'),
                        ),
                      ],
                    ),
                    const SizedBox(height: MacosSpacing.md),
                    Row(
                      children: [
                        MacosButton(
                          label: 'Reset',
                          onPressed: controller.reset,
                        ),
                      ],
                    ),
                    const SizedBox(height: MacosSpacing.sm),
                    Text(
                      value.toString(),
                      style: MacosType.footnote.copyWith(
                        color: MacosPalette.dark.secondaryLabel,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: MacosSpacing.sm),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          MacosButton(
            label: '-5',
            height: MacosControlSize.small,
            onPressed: () => onChanged(value - 5),
          ),
          const SizedBox(width: 4),
          MacosButton(
            label: '-1',
            height: MacosControlSize.small,
            onPressed: () => onChanged(value - 1),
          ),
          SizedBox(
            width: 44,
            child: Text(
              value.toStringAsFixed(0),
              textAlign: TextAlign.center,
              style: MacosType.headline.copyWith(
                color: MacosPalette.dark.label,
              ),
            ),
          ),
          MacosButton(
            label: '+1',
            height: MacosControlSize.small,
            onPressed: () => onChanged(value + 1),
          ),
          const SizedBox(width: 4),
          MacosButton(
            label: '+5',
            height: MacosControlSize.small,
            onPressed: () => onChanged(value + 5),
          ),
        ],
      ),
    );
  }
}
