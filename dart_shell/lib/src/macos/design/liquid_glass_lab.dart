import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'liquid_glass.dart';
import 'macos_design_tokens.dart';

/// Review surface for the liquid-glass shader variants.
///
/// A busy backdrop sits behind one draggable lens per [LiquidGlassMode] and a
/// fused group. Sliders tune the optics, and a live readout reports the
/// average and worst raster/build times of the last second so the cost of each
/// mode can be compared on real hardware. Stress mode animates the backdrop and
/// repeats the selected mode [stressCount] times.
class LiquidGlassLab extends StatefulWidget {
  const LiquidGlassLab({super.key});

  @override
  State<LiquidGlassLab> createState() => _LiquidGlassLabState();
}

class _LiquidGlassLabState extends State<LiquidGlassLab>
    with SingleTickerProviderStateMixin {
  static const stressCount = 8;
  static const _modes = LiquidGlassMode.values;

  late final Ticker _ticker = createTicker((d) => _time.value = d);
  final _time = ValueNotifier(Duration.zero);
  final _offsets = <Offset>[
    const Offset(80, 120),
    const Offset(80, 280),
    const Offset(80, 440),
    const Offset(480, 420),
  ];
  final _blobs = <Offset>[const Offset(580, 220), const Offset(720, 220)];

  LiquidGlassOptics _optics = const LiquidGlassOptics();
  bool _stress = false;
  bool _animate = true;
  int _blendButtonClicks = 0;
  LiquidGlassMode _stressMode = LiquidGlassMode.liquid;
  final _recent = <FrameTiming>[];
  String _readout = 'waiting for frames';

  @override
  void initState() {
    super.initState();
    LiquidGlassPrograms.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _ticker.start();
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  void _onTimings(List<FrameTiming> timings) {
    _recent.addAll(timings);
    if (_recent.length < 60) return;
    double avg(Iterable<Duration> d) =>
        d.fold<int>(0, (a, b) => a + b.inMicroseconds) / d.length / 1000;
    double worst(Iterable<Duration> d) =>
        d.map((e) => e.inMicroseconds).reduce(math.max) / 1000;
    final raster = _recent.map((t) => t.rasterDuration);
    final build = _recent.map((t) => t.buildDuration);
    final view = ui.PlatformDispatcher.instance.views.first;
    final text =
        'dpr ${view.devicePixelRatio}  view ${view.physicalSize.width.toInt()}x${view.physicalSize.height.toInt()}px   '
        'raster avg ${avg(raster).toStringAsFixed(2)} ms  '
        'max ${worst(raster).toStringAsFixed(2)} ms   '
        'build avg ${avg(build).toStringAsFixed(2)} ms  '
        'max ${worst(build).toStringAsFixed(2)} ms   '
        '(${_recent.length} frames)';
    _recent.clear();
    if (mounted) setState(() => _readout = text);
  }

  Widget _drag(int index, Widget child) => Positioned(
    left: _offsets[index].dx,
    top: _offsets[index].dy,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onPanUpdate: (d) => setState(() => _offsets[index] += d.delta),
      child: child,
    ),
  );

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      color: Color(0xffffffff),
      fontSize: 15,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.none,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: _BackdropPainter(_animate ? _time : null),
            ),
          ),
          if (_stress)
            for (var i = 0; i < stressCount; i++)
              Positioned(
                left: 40 + (i % 4) * 300.0,
                top: 560 + (i ~/ 4) * 150.0,
                child: SizedBox(
                  width: 280,
                  height: 120,
                  child: LiquidGlassLens(
                    mode: _stressMode,
                    optics: _optics,
                    radius: 40,
                    child: Center(child: _label('${_stressMode.name} $i')),
                  ),
                ),
              ),
          for (var i = 0; i < _modes.length; i++)
            _drag(
              i,
              SizedBox(
                width: 300,
                height: 120,
                child: LiquidGlassLens(
                  mode: _modes[i],
                  optics: _optics,
                  radius: 44,
                  child: Center(child: _label(_modes[i].name)),
                ),
              ),
            ),
          Positioned(
            left: 480,
            top: 100,
            width: 420,
            height: 300,
            child: Listener(
              onPointerMove: (e) => setState(() {
                _blobs[0] += e.delta;
              }),
              child: LiquidGlassBlend(
                optics: _optics,
                blend: 48,
                shapes: [
                  Rect.fromCenter(
                    center: _blobs[0] - const Offset(480, 100),
                    width: 110,
                    height: 110,
                  ),
                  Rect.fromCenter(
                    center: _blobs[1] - const Offset(480, 100),
                    width: 150,
                    height: 90,
                  ),
                ],
              ),
            ),
          ),
          _drag(
            3,
            SizedBox(
              width: 300,
              height: 96,
              child: _BlendGlassButton(
                key: const ValueKey('lab-blended-glass-button'),
                optics: _optics,
                onPressed: () => setState(() => _blendButtonClicks++),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _label('融合玻璃'),
                    const SizedBox(height: 6),
                    _label('点击 $_blendButtonClicks 次'),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 24,
            top: 24,
            width: 360,
            child: _Controls(
              optics: _optics,
              onOptics: (o) => setState(() => _optics = o),
              stress: _stress,
              onStress: (v) => setState(() => _stress = v),
              animate: _animate,
              onAnimate: (v) => setState(() => _animate = v),
              stressMode: _stressMode,
              onStressMode: (m) => setState(() => _stressMode = m),
            ),
          ),
          Positioned(
            left: 24,
            bottom: 24,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Color(0xaa000000)),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _readout,
                  style: const TextStyle(
                    color: Color(0xffffffff),
                    fontSize: 14,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlendGlassButton extends StatefulWidget {
  const _BlendGlassButton({
    super.key,
    required this.optics,
    required this.onPressed,
    required this.child,
  });

  final LiquidGlassOptics optics;
  final VoidCallback onPressed;
  final Widget child;

  @override
  State<_BlendGlassButton> createState() => _BlendGlassButtonState();
}

class _BlendGlassButtonState extends State<_BlendGlassButton> {
  /// Logical pixels between the button capsule and the widget bounds; see
  /// the shape comment in [build].
  static const _blendButtonShapeSlack = 3.0;

  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: MacosMotion.quick,
          curve: MacosMotion.spring,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Keep the capsule off the layer's coverage boundary. The
              // shader field can sit a couple of device pixels off the clip
              // under the GLES negative-render-view pipeline; a shape that
              // touches the boundary gets its corners flattened by that
              // slack, while an inset capsule (like the floating fusion
              // blobs) stays correct.
              final shape = (Offset.zero & constraints.biggest).deflate(
                _blendButtonShapeSlack,
              );
              return LiquidGlassBlend(
                optics: widget.optics,
                shapes: [shape],
                blend: 0,
                roundness: 1,
                child: Center(child: widget.child),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.optics,
    required this.onOptics,
    required this.stress,
    required this.onStress,
    required this.animate,
    required this.onAnimate,
    required this.stressMode,
    required this.onStressMode,
  });

  final LiquidGlassOptics optics;
  final ValueChanged<LiquidGlassOptics> onOptics;
  final bool stress;
  final ValueChanged<bool> onStress;
  final bool animate;
  final ValueChanged<bool> onAnimate;
  final LiquidGlassMode stressMode;
  final ValueChanged<LiquidGlassMode> onStressMode;

  Widget _slider(
    String name,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) => Row(
    children: [
      SizedBox(
        width: 110,
        child: Text(
          '$name ${value.toStringAsFixed(2)}',
          style: const TextStyle(
            color: Color(0xffffffff),
            fontSize: 12,
            decoration: TextDecoration.none,
          ),
        ),
      ),
      Expanded(
        child: _Track(
          value: (value - min) / (max - min),
          onChanged: (t) => onChanged(min + t * (max - min)),
        ),
      ),
    ],
  );

  Widget _chip(String text, bool on, VoidCallback tap) => GestureDetector(
    onTap: tap,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: on ? const Color(0xff2f7bff) : const Color(0x88000000),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: const TextStyle(
            color: Color(0xffffffff),
            fontSize: 12,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xaa000000),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _slider(
              'bezel',
              optics.bezel,
              2,
              48,
              (v) => onOptics(optics.copyWith(bezel: v)),
            ),
            _slider(
              'index',
              optics.refractiveIndex,
              1.05,
              2.5,
              (v) => onOptics(optics.copyWith(refractiveIndex: v)),
            ),
            _slider(
              'depth',
              optics.depth,
              0,
              160,
              (v) => onOptics(optics.copyWith(depth: v)),
            ),
            _slider(
              'chroma',
              optics.chromaticAberration,
              0,
              2,
              (v) => onOptics(optics.copyWith(chromaticAberration: v)),
            ),
            _slider(
              'specular',
              optics.specular,
              0,
              1.5,
              (v) => onOptics(optics.copyWith(specular: v)),
            ),
            _slider(
              'light',
              optics.lightAngle,
              -math.pi,
              math.pi,
              (v) => onOptics(optics.copyWith(lightAngle: v)),
            ),
            _slider(
              'saturation',
              optics.saturation,
              0.5,
              2,
              (v) => onOptics(optics.copyWith(saturation: v)),
            ),
            _slider(
              'blur',
              optics.blurSigma,
              0,
              20,
              (v) => onOptics(optics.copyWith(blurSigma: v)),
            ),
            _slider(
              'px scale',
              optics.pixelScale,
              0.5,
              3,
              (v) => onOptics(optics.copyWith(pixelScale: v)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _chip(
                  'debug shape',
                  optics.debugShape,
                  () =>
                      onOptics(optics.copyWith(debugShape: !optics.debugShape)),
                ),
                _chip(
                  'flip Y',
                  optics.invertY,
                  () => onOptics(optics.copyWith(invertY: !optics.invertY)),
                ),
                _chip('animate bg', animate, () => onAnimate(!animate)),
                _chip('stress x8', stress, () => onStress(!stress)),
                for (final m in LiquidGlassMode.values)
                  _chip(m.name, stressMode == m, () => onStressMode(m)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        void update(Offset p) => onChanged((p.dx / c.maxWidth).clamp(0.0, 1.0));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (d) => update(d.localPosition),
          onPanUpdate: (d) => update(d.localPosition),
          child: SizedBox(
            height: 24,
            child: CustomPaint(painter: _TrackPainter(value.clamp(0.0, 1.0))),
          ),
        );
      },
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = const Color(0x66ffffff)
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      Offset(t * size.width, y),
      7,
      Paint()..color = const Color(0xffffffff),
    );
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.t != t;
}

/// High-frequency colour, text-like stripes and a moving disc: enough detail
/// that refraction, dispersion and the rim are easy to read.
class _BackdropPainter extends CustomPainter {
  _BackdropPainter(this.time) : super(repaint: time);
  final ValueListenable<Duration>? time;

  @override
  void paint(Canvas canvas, Size size) {
    final t = (time?.value.inMicroseconds ?? 0) / 1e6;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, size.height),
          const [Color(0xff1b3a8a), Color(0xffc0397a), Color(0xfff2a33a)],
          const [0, 0.5, 1],
        ),
    );
    final line = Paint()
      ..color = const Color(0xffffffff)
      ..strokeWidth = 3;
    for (var x = -size.height; x < size.width; x += 28) {
      final shift = (t * 30) % 28;
      canvas.drawLine(
        Offset(x + shift, 0),
        Offset(x + shift + size.height * 0.5, size.height),
        line..color = const Color(0x55ffffff),
      );
    }
    for (var i = 0; i < 6; i++) {
      canvas.drawCircle(
        Offset(
          size.width * (0.15 + 0.14 * i) + 80 * math.sin(t + i),
          size.height * (0.3 + 0.12 * math.cos(t * 0.7 + i)),
        ),
        40 + 14 * i.toDouble(),
        Paint()..color = HSVColor.fromAHSV(1, i * 55.0, 0.8, 1).toColor(),
      );
    }
    final rows = (size.height / 22).floor();
    for (var r = 0; r < rows; r++) {
      canvas.drawRect(
        Rect.fromLTWH(24, r * 22 + 6, 200 + (r * 53) % 500, 7),
        Paint()..color = const Color(0xee101020),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => false;
}
