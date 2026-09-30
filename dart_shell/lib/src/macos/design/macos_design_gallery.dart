import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../input/shell_interaction_registry.dart';
import 'macos_controls.dart';
import 'macos_design_tokens.dart';
import 'macos_glass.dart';

BorderRadius _r(double radius) => BorderRadius.circular(radius);

/// Design-review surface for the macOS 26 (Tahoe) Liquid Glass language.
///
/// Presents the tokens, materials, and controls in `lib/src/macos/design` over
/// a colorful backdrop so translucency is evaluable. It reads no runtime
/// state, so it can be embedded in any shell scene.
class MacosDesignGallery extends StatefulWidget {
  const MacosDesignGallery({
    super.key,
    this.initialDark = false,
    this.onExit,
    this.onGlassLab,
  });

  final bool initialDark;

  /// When set, the toolbar shows a button that returns to the desktop.
  final VoidCallback? onExit;

  /// When set, the toolbar shows a button that opens the glass shader lab.
  final VoidCallback? onGlassLab;

  @override
  State<MacosDesignGallery> createState() => _MacosDesignGalleryState();
}

class _MacosDesignGalleryState extends State<MacosDesignGallery> {
  late bool _dark = widget.initialDark;
  bool _switch = true;
  double _slider = 0.6;
  int _segment = 0;
  int _sidebar = 0;
  double _frost = 0.5;

  static const _sidebarItems = <(IconData, String)>[
    (Icons.tune, 'Controls'),
    (Icons.layers, 'Materials'),
    (Icons.text_fields, 'Typography'),
    (Icons.brush, 'Color'),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = _dark ? MacosPalette.dark : MacosPalette.light;
    return MacosPaletteScope(
      palette: palette,
      child: MacosGlassScope(
        frost: _frost,
        refractive: true,
        child: DefaultTextStyle(
        style: MacosType.body.copyWith(color: palette.label),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Backdrop(dark: _dark),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ShellInputRegion(debugLabel: 'gallery-menu-bar', child: _MenuBar()),
            ),
            Positioned.fill(
              top: 44,
              bottom: 104,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 1040,
                    maxHeight: 700,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: ShellInputRegion(
                      debugLabel: 'gallery-window',
                      child: _window(palette),
                    ),
                  ),
                ),
              ),
            ),
            const Positioned(
              bottom: 120,
              right: 36,
              child: ShellInputRegion(
                debugLabel: 'gallery-banner',
                child: _NotificationBanner(),
              ),
            ),
            const Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: _Dock(),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _window(MacosPalette palette) {
    const inset = 8.0;
    return MacosGlass(
      borderRadius: _r(MacosRadii.window),
      blurSigma: 30,
      padding: const EdgeInsets.all(inset),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Padding(
              padding: const EdgeInsets.all(MacosSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _TrafficLights(),
                  const SizedBox(height: MacosSpacing.lg),
                  const MacosSearchField(),
                  const SizedBox(height: MacosSpacing.md),
                  for (var i = 0; i < _sidebarItems.length; i++)
                    _SidebarRow(
                      icon: _sidebarItems[i].$1,
                      label: _sidebarItems[i].$2,
                      selected: i == _sidebar,
                      onTap: () => setState(() => _sidebar = i),
                    ),
                  const SizedBox(height: MacosSpacing.lg),
                  Text('Liquid Glass', style: MacosType.footnote),
                  MacosSlider(
                    value: _frost,
                    onChanged: (v) => setState(() => _frost = v),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: _r(MacosRadii.concentric(MacosRadii.window, inset)),
              child: ColoredBox(
                color: palette.contentBackground,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 76, 28, 28),
                        child: _page(palette),
                      ),
                    ),
                    Positioned(
                      top: 12,
                      left: 12,
                      right: 12,
                      child: _toolbar(palette),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(MacosPalette palette) {
    return Row(
      children: [
        RepaintBoundary(child: MacosGlass(
          borderRadius: _r(100),
          elevated: false,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: Icon(
                Icons.chevron_left,
                size: 15,
                color: palette.label,
              ),
            ),
          ),
        )),
        const SizedBox(width: MacosSpacing.md),
        Text(_sidebarItems[_sidebar].$2, style: MacosType.title2),
        const Spacer(),
        if (widget.onGlassLab != null) ...[
          MacosButton(
            label: 'Glass lab',
            glass: true,
            icon: Icons.blur_on,
            height: 36,
            onPressed: widget.onGlassLab,
          ),
          const SizedBox(width: MacosSpacing.sm),
        ],
        if (widget.onExit != null) ...[
          MacosButton(
            label: 'Desktop',
            glass: true,
            prominent: true,
            icon: Icons.desktop_windows,
            height: 36,
            onPressed: widget.onExit,
          ),
          const SizedBox(width: MacosSpacing.sm),
        ],
        MacosButton(
          label: _dark ? 'Dark' : 'Light',
          glass: true,
          icon: _dark ? Icons.dark_mode : Icons.light_mode,
          height: 36,
          onPressed: () => setState(() => _dark = !_dark),
        ),
      ],
    );
  }

  Widget _page(MacosPalette palette) => switch (_sidebar) {
    0 => _controlsPage(palette),
    1 => _materialsPage(palette),
    2 => _typographyPage(palette),
    _ => _colorPage(palette),
  };

  Widget _section(String title, Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: MacosSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: MacosType.headline),
        const SizedBox(height: MacosSpacing.md),
        child,
      ],
    ),
  );

  Widget _controlsPage(MacosPalette palette) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _section(
        'Buttons',
        Wrap(
          spacing: MacosSpacing.md,
          runSpacing: MacosSpacing.md,
          children: [
            MacosButton(label: 'Cancel', onPressed: () {}),
            MacosButton(label: 'Continue', prominent: true, onPressed: () {}),
            MacosButton(
              label: 'Share',
              icon: Icons.ios_share,
              onPressed: () {},
            ),
            MacosButton(
              label: 'Large',
              prominent: true,
              height: MacosControlSize.extraLarge,
              onPressed: () {},
            ),
          ],
        ),
      ),
      _section(
        'Selection',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MacosSegmented(
              labels: const ['Icons', 'List', 'Columns', 'Gallery'],
              selected: _segment,
              onChanged: (i) => setState(() => _segment = i),
            ),
            const SizedBox(height: MacosSpacing.lg),
            Row(
              children: [
                MacosSwitch(
                  value: _switch,
                  onChanged: (v) => setState(() => _switch = v),
                ),
                const SizedBox(width: MacosSpacing.md),
                const Text('Reduce transparency'),
              ],
            ),
            const SizedBox(height: MacosSpacing.md),
            SizedBox(
              width: 320,
              child: MacosSlider(
                value: _slider,
                onChanged: (v) => setState(() => _slider = v),
              ),
            ),
          ],
        ),
      ),
      _section('Motion', const _MotionDemo()),
      _section(
        'Concentric corners',
        Row(
          children: [
            for (final inset in const [0.0, 8.0, 16.0])
              Padding(
                padding: const EdgeInsets.only(right: MacosSpacing.lg),
                child: _ConcentricDemo(inset: inset),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _materialsPage(MacosPalette palette) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _section(
        'Regular, clear and tinted glass over content',
        SizedBox(
          height: 240,
          child: ClipRRect(
            borderRadius: _r(MacosRadii.card),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const _StripedContent(),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _glassSample('Regular', MacosGlassVariant.regular, null),
                      const SizedBox(width: MacosSpacing.lg),
                      _glassSample('Clear', MacosGlassVariant.clear, null),
                      const SizedBox(width: MacosSpacing.lg),
                      _glassSample(
                        'Tinted',
                        MacosGlassVariant.regular,
                        palette.accent.withValues(alpha: 0.45),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      const Text(
        'Glass is reserved for the navigation and control layer that floats '
        'above content. Content never uses glass.',
      ),
    ],
  );

  Widget _glassSample(String label, MacosGlassVariant variant, Color? tint) =>
      MacosGlass(
        borderRadius: _r(MacosRadii.card),
        variant: variant,
        tint: tint,
        child: SizedBox(
          width: 150,
          height: 110,
          child: Center(child: Text(label, style: MacosType.title3)),
        ),
      );

  Widget _typographyPage(MacosPalette palette) {
    final rows = <(String, TextStyle)>[
      ('Large Title 26', MacosType.largeTitle),
      ('Title 1 22', MacosType.title1),
      ('Title 2 17', MacosType.title2),
      ('Title 3 15', MacosType.title3),
      ('Headline 13', MacosType.headline),
      ('Body 13', MacosType.body),
      ('Callout 12', MacosType.callout),
      ('Subheadline 11', MacosType.subheadline),
      ('Footnote 10', MacosType.footnote),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (name, style) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: MacosSpacing.md),
            child: Text(name, style: style.copyWith(color: palette.label)),
          ),
      ],
    );
  }

  Widget _colorPage(MacosPalette palette) => Wrap(
    spacing: MacosSpacing.md,
    runSpacing: MacosSpacing.md,
    children: [
      for (final color in MacosSystemColors.all)
        Container(
          width: 88,
          height: 64,
          decoration: BoxDecoration(color: color, borderRadius: _r(14)),
        ),
    ],
  );
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    Widget blob(Alignment alignment, Color color, double size) => Align(
      alignment: alignment,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xff10122b), Color(0xff2a1146), Color(0xff081a33)]
              : const [Color(0xffbfd9ff), Color(0xffe9d3ff), Color(0xffffe1c7)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          blob(const Alignment(-0.8, -0.6), MacosSystemColors.blue, 720),
          blob(const Alignment(0.9, -0.2), MacosSystemColors.pink, 620),
          blob(const Alignment(0.1, 0.9), MacosSystemColors.orange, 680),
          blob(const Alignment(-0.9, 0.8), MacosSystemColors.mint, 520),
        ],
      ),
    );
  }
}

class _MenuBar extends StatelessWidget {
  const _MenuBar();

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    Widget item(String text, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(
        text,
        style: MacosType.body.copyWith(
          color: palette.label,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(Icons.explore, size: 15, color: palette.label),
          item('Denial', bold: true),
          item('File'),
          item('Edit'),
          item('View'),
          item('Window'),
          item('Help'),
          const Spacer(),
          Icon(Icons.wifi, size: 15, color: palette.label),
          item('Tue 9:41'),
        ],
      ),
    );
  }
}

class _TrafficLights extends StatelessWidget {
  const _TrafficLights();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final c in const [
        Color(0xffff5f57),
        Color(0xffffbd2e),
        Color(0xff28c840),
      ])
        Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
    ],
  );
}

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: MacosMotion.quick,
        height: MacosControlSize.large,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: MacosSpacing.md),
        decoration: BoxDecoration(
          color: selected
              ? palette.controlFillPressed
              : const Color(0x00000000),
          borderRadius: _r(100),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: palette.accent),
            const SizedBox(width: MacosSpacing.sm + 2),
            Text(
              label,
              style: MacosType.body.copyWith(
                color: palette.label,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConcentricDemo extends StatelessWidget {
  const _ConcentricDemo({required this.inset});

  final double inset;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    const outer = 32.0;
    return Container(
      width: 120,
      height: 80,
      padding: EdgeInsets.all(inset),
      decoration: BoxDecoration(
        color: palette.controlFill,
        borderRadius: _r(outer),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.accent,
          borderRadius: _r(MacosRadii.concentric(outer, inset)),
        ),
        child: Center(
          child: Text(
            'inset ${inset.toInt()}',
            style: MacosType.subheadline.copyWith(
              color: const Color(0xffffffff),
            ),
          ),
        ),
      ),
    );
  }
}

class _StripedContent extends StatelessWidget {
  const _StripedContent();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final c in MacosSystemColors.all)
        Expanded(
          child: ColoredBox(color: c, child: const SizedBox.expand()),
        ),
    ],
  );
}

class _NotificationBanner extends StatelessWidget {
  const _NotificationBanner();

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    return SizedBox(
      width: 340,
      child: MacosGlass(
        borderRadius: _r(MacosRadii.notification),
        padding: const EdgeInsets.all(MacosSpacing.md),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: MacosSystemColors.green,
                borderRadius: _r(
                  MacosRadii.concentric(
                    MacosRadii.notification,
                    MacosSpacing.md,
                  ),
                ),
              ),
              child: const Icon(
                Icons.chat_bubble,
                size: 20,
                color: Color(0xffffffff),
              ),
            ),
            const SizedBox(width: MacosSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Messages', style: MacosType.headline),
                  Text(
                    'Design review at 3 PM',
                    style: MacosType.callout.copyWith(
                      color: palette.secondaryLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dock extends StatefulWidget {
  const _Dock();

  @override
  State<_Dock> createState() => _DockState();
}

class _DockState extends State<_Dock> {
  /// Transparent space above the glass so magnified icons stay inside the
  /// input region and are never clipped.
  static const double _dockHeadroom = 36;

  static const double _slot = 64;
  static const double _influence = 84;

  double? _pointerX;
  double _last = 0;

  static const _icons = <(IconData, Color)>[
    (Icons.explore, MacosSystemColors.blue),
    (Icons.mail, MacosSystemColors.indigo),
    (Icons.music_note, MacosSystemColors.pink),
    (Icons.photo, MacosSystemColors.orange),
    (Icons.settings, MacosSystemColors.mint),
    (Icons.delete, MacosSystemColors.purple),
  ];

  double _scale(int i, double x, double amount) {
    final d = (i + 0.5) * _slot - x;
    return 1 + 0.45 * amount * math.exp(-(d * d) / (2 * _influence * _influence / 4));
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ShellInputRegion(
        debugLabel: 'gallery-dock',
        child: MouseRegion(
          onExit: (_) => setState(() => _pointerX = null),
          child: SizedBox(
            height: _dockHeadroom + 72,
            child: Stack(
              alignment: Alignment.bottomCenter,
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 72,
                  child: MacosGlass(
                    borderRadius: _r(MacosRadii.dock),
                    child: const SizedBox.expand(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(MacosSpacing.sm),
                  child: MouseRegion(
                    onEnter: (e) => setState(() => _pointerX = e.localPosition.dx),
                    onHover: (e) => setState(() => _pointerX = e.localPosition.dx),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: _pointerX == null ? 0 : 1),
                      duration: MacosMotion.standard,
                      curve: MacosMotion.spring,
                      builder: (context, amount, _) => TweenAnimationBuilder<double>(
                        tween: Tween<double>(end: _pointerX ?? _last),
                        duration: const Duration(milliseconds: 90),
                        builder: (context, x, _) {
                          if (_pointerX != null) _last = _pointerX!;
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (var i = 0; i < _icons.length; i++)
                                Transform.scale(
                                  scale: _scale(i, x, amount),
                                  alignment: Alignment.bottomCenter,
                                  child: _dockIcon(i),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ),
      ),
    );
  }

  Widget _dockIcon(int i) => Container(
    width: 56,
    height: 56,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      borderRadius: _r(14),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.alphaBlend(const Color(0x55ffffff), _icons[i].$2),
          _icons[i].$2,
        ],
      ),
    ),
    child: Icon(_icons[i].$1, size: 28, color: const Color(0xffffffff)),
  );
}

class _MotionDemo extends StatefulWidget {
  const _MotionDemo();

  @override
  State<_MotionDemo> createState() => _MotionDemoState();
}

class _MotionDemoState extends State<_MotionDemo> {
  bool _on = false;

  @override
  Widget build(BuildContext context) {
    final palette = MacosPaletteScope.of(context);
    Widget track(String label, MacosMotionSample sample) => Padding(
      padding: const EdgeInsets.only(bottom: MacosSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: MacosType.callout.copyWith(color: palette.secondaryLabel),
            ),
          ),
          Expanded(
            child: Container(
              height: 40,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: palette.controlFill,
                borderRadius: _r(100),
              ),
              child: AnimatedAlign(
                duration: sample.duration,
                curve: sample.curve,
                alignment: _on ? Alignment.centerRight : Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: sample.duration,
                  curve: sample.curve,
                  width: _on ? 56 : 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _on ? MacosSystemColors.green : palette.accent,
                    borderRadius: _r(100),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        track('Quick 140ms', MacosMotionSample(MacosMotion.quick, MacosMotion.spring)),
        track('Standard 240ms', MacosMotionSample(MacosMotion.standard, MacosMotion.spring)),
        track('Morph 420ms', MacosMotionSample(MacosMotion.morph, MacosMotion.spring)),
        MacosButton(
          label: _on ? 'Play back' : 'Play',
          icon: _on ? Icons.replay : Icons.play_arrow,
          prominent: true,
          onPressed: () => setState(() => _on = !_on),
        ),
      ],
    );
  }
}

class MacosMotionSample {
  const MacosMotionSample(this.duration, this.curve);

  final Duration duration;
  final Curve curve;
}
