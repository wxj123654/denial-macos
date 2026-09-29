import 'package:flutter/material.dart' show Icons;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';

import 'macos_design_tokens.dart';
import 'macos_glass.dart';

const BorderRadius _capsule = BorderRadius.all(Radius.circular(100));

/// Capsule push button. [prominent] fills with the accent color.
class MacosButton extends StatefulWidget {
  const MacosButton({
    super.key,
    required this.label,
    this.onPressed,
    this.prominent = false,
    this.glass = false,
    this.icon,
    this.height = MacosControlSize.regular,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool prominent;

  /// Renders on floating Liquid Glass instead of a flat fill.
  final bool glass;
  final IconData? icon;
  final double height;

  @override
  State<MacosButton> createState() => _MacosButtonState();
}

class _MacosButtonState extends State<MacosButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    final foreground = widget.prominent
        ? const Color(0xffffffff)
        : palette.label;
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.height * 0.6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 14, color: foreground),
            const SizedBox(width: MacosSpacing.xs + 2),
          ],
          Text(
            widget.label,
            style: MacosType.body.copyWith(
              color: foreground,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
    Widget body;
    if (widget.glass) {
      body = MacosGlass(
        borderRadius: _capsule,
        tint: widget.prominent ? palette.accent.withValues(alpha: 0.7) : null,
        blurSigma: 16,
        elevated: false,
        child: SizedBox(
          height: widget.height,
          child: Center(widthFactor: 1, child: content),
        ),
      );
    } else {
      final base = widget.prominent
          ? palette.accent
          : (_pressed ? palette.controlFillPressed : palette.controlFill);
      body = AnimatedContainer(
        duration: MacosMotion.quick,
        height: widget.height,
        decoration: BoxDecoration(
          color: _hovered && widget.prominent
              ? Color.alphaBlend(const Color(0x22ffffff), base)
              : base,
          borderRadius: _capsule,
        ),
        child: Center(widthFactor: 1, child: content),
      );
    }
    if (widget.glass) body = RepaintBoundary(child: body);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          final size = context.size;
          final inside = size != null && (Offset.zero & size).contains(d.localPosition);
          final hoverOk = d.kind != PointerDeviceKind.mouse || _hovered;
          if (inside && hoverOk) setState(() => _pressed = true);
        },
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: MacosMotion.quick,
          curve: MacosMotion.spring,
          child: body,
        ),
      ),
    );
  }
}

/// Switch whose thumb is a wide capsule, as on macOS 26.
class MacosSwitch extends StatelessWidget {
  const MacosSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: MacosMotion.standard,
        curve: MacosMotion.spring,
        width: 42,
        height: 26,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value ? MacosSystemColors.green : palette.controlFillPressed,
          borderRadius: _capsule,
        ),
        child: AnimatedAlign(
          duration: MacosMotion.standard,
          curve: MacosMotion.spring,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 28,
            height: 22,
            decoration: const BoxDecoration(
              color: Color(0xffffffff),
              borderRadius: _capsule,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal slider with a glass thumb.
class MacosSlider extends StatelessWidget {
  const MacosSlider({super.key, required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const thumbWidth = 26.0;
        final width = constraints.maxWidth;
        final travel = width - thumbWidth;
        void update(double dx) =>
            onChanged(((dx - thumbWidth / 2) / travel).clamp(0.0, 1.0));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => update(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
          child: SizedBox(
            height: 28,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: palette.controlFillPressed,
                    borderRadius: _capsule,
                  ),
                ),
                Container(
                  width: thumbWidth / 2 + travel * value,
                  height: 6,
                  decoration: BoxDecoration(
                    color: palette.accent,
                    borderRadius: _capsule,
                  ),
                ),
                Positioned(left: travel * value, child: const _SliderThumb()),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SliderThumb extends StatelessWidget {
  const _SliderThumb();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 18,
      decoration: const BoxDecoration(
        color: Color(0xfffdfdfd),
        borderRadius: _capsule,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

/// Segmented control: a glass track with a lifted selection capsule.
class MacosSegmented extends StatelessWidget {
  const MacosSegmented({
    super.key,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    return Container(
      height: MacosControlSize.large,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.controlFill,
        borderRadius: _capsule,
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: MacosMotion.morph,
            curve: MacosMotion.spring,
            alignment: Alignment(
              labels.length == 1 ? 0 : -1 + 2 * selected / (labels.length - 1),
              0,
            ),
            child: FractionallySizedBox(
              widthFactor: 1 / labels.length,
              child: Container(
                decoration: BoxDecoration(
                  color: palette.isDark
                      ? const Color(0x33ffffff)
                      : const Color(0xffffffff),
                  borderRadius: _capsule,
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(i),
                    child: Center(
                      child: Text(
                        labels[i],
                        style: MacosType.body.copyWith(
                          color: palette.label,
                          fontWeight: i == selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Capsule search field (static placeholder for design review).
class MacosSearchField extends StatelessWidget {
  const MacosSearchField({super.key, this.placeholder = 'Search'});

  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    return Container(
      height: MacosControlSize.large,
      padding: const EdgeInsets.symmetric(horizontal: MacosSpacing.md),
      decoration: BoxDecoration(
        color: palette.controlFill,
        borderRadius: _capsule,
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 14, color: palette.secondaryLabel),
          const SizedBox(width: MacosSpacing.sm),
          Text(
            placeholder,
            style: MacosType.body.copyWith(color: palette.secondaryLabel),
          ),
        ],
      ),
    );
  }
}
