import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'macos_glass.dart';

/// Optical model used by [LiquidGlassLens]. Ordered by GPU cost.
enum LiquidGlassMode {
  /// Backdrop blur, tint and rim gradient only (the existing [MacosGlass]).
  frosted,

  /// Single-tap convex-bezel refraction through a backdrop shader.
  refract,

  /// Refraction, per-channel dispersion, directional specular rim,
  /// saturation and tint.
  liquid,
}

/// Loaded glass programs. Shader programs are compiled once per process.
abstract final class LiquidGlassPrograms {
  static ui.FragmentProgram? _refract;
  static ui.FragmentProgram? _liquid;
  static ui.FragmentProgram? _metaball;
  static Future<void>? _loading;
  static Object? failure;

  static ui.FragmentProgram? get refract => _refract;
  static ui.FragmentProgram? get liquid => _liquid;
  static ui.FragmentProgram? get metaball => _metaball;

  static bool get ready => _refract != null;

  @visibleForTesting
  static void resetForTest() {
    _refract = _liquid = _metaball = null;
    _loading = null;
    failure = null;
  }

  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final programs = await Future.wait([
        ui.FragmentProgram.fromAsset('shaders/glass_refract.frag'),
        ui.FragmentProgram.fromAsset('shaders/glass_liquid.frag'),
        ui.FragmentProgram.fromAsset('shaders/glass_metaball.frag'),
      ]);
      _refract = programs[0];
      _liquid = programs[1];
      _metaball = programs[2];
    } catch (error) {
      failure = error;
    }
  }
}

/// Tunable optics shared by the lens and the blended group. Lengths are in
/// logical pixels.
@immutable
class LiquidGlassOptics {
  const LiquidGlassOptics({
    this.bezel = 18,
    this.refractiveIndex = 1.5,
    this.depth = 60,
    this.chromaticAberration = 0.6,
    this.specular = 0.5,
    this.lightAngle = -math.pi / 4,
    this.saturation = 1.25,
    this.tint = const Color(0x14ffffff),
    this.blurSigma = 2,
    this.invertY = false,
    this.debugShape = false,
    this.pixelScale = 1,
    this.rootYInverted = true,
  });

  final double bezel;
  final double refractiveIndex;
  final double depth;
  final double chromaticAberration;
  final double specular;
  final double lightAngle;
  final double saturation;
  final Color tint;

  /// Extra low-cost pre-blur before refraction; 0 skips the blur pass.
  final double blurSigma;

  /// Flips the backdrop's Y axis on top of the automatic GLES correction.
  final bool invertY;

  /// Paints the shader's shape probe instead of glass.
  final bool debugShape;

  /// Multiplier on the device pixel ratio handed to the shaders; 1 is the
  /// view's own ratio. Exists to diagnose filter-texture size mismatches.
  final double pixelScale;
  final bool rootYInverted;

  LiquidGlassOptics copyWith({
    double? bezel,
    double? refractiveIndex,
    double? depth,
    double? chromaticAberration,
    double? specular,
    double? lightAngle,
    double? saturation,
    Color? tint,
    double? blurSigma,
    bool? invertY,
    bool? debugShape,
    double? pixelScale,
    bool? rootYInverted,
  }) => LiquidGlassOptics(
    bezel: bezel ?? this.bezel,
    refractiveIndex: refractiveIndex ?? this.refractiveIndex,
    depth: depth ?? this.depth,
    chromaticAberration: chromaticAberration ?? this.chromaticAberration,
    specular: specular ?? this.specular,
    lightAngle: lightAngle ?? this.lightAngle,
    saturation: saturation ?? this.saturation,
    tint: tint ?? this.tint,
    blurSigma: blurSigma ?? this.blurSigma,
    invertY: invertY ?? this.invertY,
    debugShape: debugShape ?? this.debugShape,
    pixelScale: pixelScale ?? this.pixelScale,
    rootYInverted: rootYInverted ?? this.rootYInverted,
  );

  LiquidGlassOptics forSize(Size size) => copyWith(
    bezel: math.min(bezel, size.shortestSide / 3),
    depth: math.min(depth, size.shortestSide / 2),
  );

  /// Fills the application uniforms (2..20); 0..1 belong to the engine.
  int apply(
    ui.FragmentShader shader,
    Size size,
    double scale,
    double radius, {
    required Offset origin,
  }) {
    final values = uniformsFor(size, scale, radius, origin: origin);
    for (var i = 2; i < values.length; i++) {
      shader.setFloat(i, values[i]);
    }
    return values.length;
  }

  @visibleForTesting
  List<double> uniformsFor(
    Size size,
    double scale,
    double radius, {
    required Offset origin,
  }) {
    scale *= pixelScale;
    return [
      0,
      0,
      radius * scale,
      bezel * scale,
      refractiveIndex,
      depth * scale,
      chromaticAberration,
      specular,
      lightAngle,
      saturation,
      invertY ? 1 : 0,
      tint.r,
      tint.g,
      tint.b,
      tint.a,
      debugShape ? 1 : 0,
      origin.dx,
      origin.dy,
      size.width * scale,
      size.height * scale,
      rootYInverted ? 1 : 0,
    ];
  }

  /// The backdrop filter, or null when the engine has no shader image
  /// filters (Skia), so callers can fall back to frosted glass.
  ui.ImageFilter? filterFor(ui.FragmentShader shader, double scale) {
    final ui.ImageFilter shaded;
    try {
      shaded = ui.ImageFilter.shader(shader);
    } on UnsupportedError {
      return null;
    }
    if (blurSigma <= 0) return shaded;
    return ui.ImageFilter.compose(
      outer: shaded,
      inner: ui.ImageFilter.blur(
        sigmaX: blurSigma,
        sigmaY: blurSigma,
        tileMode: TileMode.clamp,
      ),
    );
  }
}

/// A single liquid-glass surface: a rounded rectangle whose bezel refracts
/// whatever is painted behind it.
///
/// Falls back to [MacosGlass] while the shader is loading, if it failed to
/// load, or for [LiquidGlassMode.frosted].
class LiquidGlassLens extends StatefulWidget {
  const LiquidGlassLens({
    super.key,
    required this.child,
    this.mode = LiquidGlassMode.liquid,
    this.radius = 28,
    this.optics = const LiquidGlassOptics(),
    this.padding,
    this.fallback,
  });

  final Widget child;
  final LiquidGlassMode mode;
  final double radius;
  final LiquidGlassOptics optics;
  final EdgeInsetsGeometry? padding;
  final Widget? fallback;

  @override
  State<LiquidGlassLens> createState() => _LiquidGlassLensState();
}

class _LiquidGlassLensState extends State<LiquidGlassLens> {
  ui.FragmentShader? _shader;
  ui.FragmentProgram? _program;

  @override
  void initState() {
    super.initState();
    if (!LiquidGlassPrograms.ready) {
      unawaited(
        LiquidGlassPrograms.ensureLoaded().then((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  ui.FragmentShader? _shaderFor(ui.FragmentProgram? program) {
    if (program == null) return null;
    if (!identical(program, _program)) {
      _shader?.dispose();
      _program = program;
      _shader = program.fragmentShader();
    }
    return _shader;
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.radius);
    final program = switch (widget.mode) {
      LiquidGlassMode.frosted => null,
      LiquidGlassMode.refract => LiquidGlassPrograms.refract,
      LiquidGlassMode.liquid => LiquidGlassPrograms.liquid,
    };
    final shader = _shaderFor(program);
    if (shader == null || !_filterSupported(shader)) {
      return widget.fallback ??
          MacosGlass(
            borderRadius: radius,
            padding: widget.padding,
            refractive: false,
            child: widget.child,
          );
    }
    final scale = MediaQuery.devicePixelRatioOf(context);
    final content = widget.padding == null
        ? widget.child
        : Padding(padding: widget.padding!, child: widget.child);
    return ClipRRect(
      borderRadius: radius,
      child: _GlassBackdrop(
        scale: scale,
        filterFor: (origin, size, scale) {
          final optics = widget.optics.forSize(size);
          optics.apply(shader, size, scale, widget.radius, origin: origin);
          return optics.filterFor(shader, scale);
        },
        child: content,
      ),
    );
  }
}

/// Up to four glass shapes that fuse like liquid when they approach each
/// other. [shapes] are in this widget's local logical coordinates.
class LiquidGlassBlend extends StatefulWidget {
  const LiquidGlassBlend({
    super.key,
    required this.shapes,
    this.blend = 40,
    this.roundness = 1,
    this.optics = const LiquidGlassOptics(),
    this.child,
  }) : assert(shapes.length <= 4);

  final List<Rect> shapes;

  /// Fusion distance in logical pixels.
  final double blend;

  /// Corner radius as a fraction of each shape's shorter half size.
  final double roundness;
  final LiquidGlassOptics optics;
  final Widget? child;

  @override
  State<LiquidGlassBlend> createState() => _LiquidGlassBlendState();
}

class _LiquidGlassBlendState extends State<LiquidGlassBlend> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (LiquidGlassPrograms.metaball == null) {
      unawaited(
        LiquidGlassPrograms.ensureLoaded().then((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final program = LiquidGlassPrograms.metaball;
    if (program == null) return widget.child ?? const SizedBox.shrink();
    final shader = _shader ??= program.fragmentShader();
    final scale = MediaQuery.devicePixelRatioOf(context);
    if (!_filterSupported(shader)) {
      return widget.child ?? const SizedBox.shrink();
    }
    return ClipRect(
      child: _GlassBackdrop(
        scale: scale,
        filterFor: (origin, size, scale) {
          final shapeScale = scale * widget.optics.pixelScale;
          var index = widget.optics.apply(
            shader,
            size,
            scale,
            0,
            origin: origin,
          );
          for (var i = 0; i < 4; i++) {
            final rect = i < widget.shapes.length ? widget.shapes[i] : null;
            shader
              ..setFloat(index++, (rect?.center.dx ?? 0) * shapeScale)
              ..setFloat(index++, (rect?.center.dy ?? 0) * shapeScale)
              ..setFloat(index++, (rect?.width ?? 0) / 2 * shapeScale)
              ..setFloat(index++, (rect?.height ?? 0) / 2 * shapeScale);
          }
          shader
            ..setFloat(index++, widget.blend * shapeScale)
            ..setFloat(index, widget.roundness);
          return widget.optics.filterFor(shader, scale);
        },
        child: widget.child ?? const SizedBox.expand(),
      ),
    );
  }
}

/// Whether the engine can build shader image filters (Impeller only).
bool _filterSupported(ui.FragmentShader shader) =>
    ui.ImageFilter.isShaderFilterSupported;

/// A backdrop filter whose shader learns its own position in the view.
///
/// The root backdrop input uses view coordinates, so the shader needs this
/// widget's top-left corner in physical view pixels and its laid-out size.
/// Resolve them at composition time so retained ancestor motion stays aligned.
class _GlassBackdrop extends SingleChildRenderObjectWidget {
  const _GlassBackdrop({
    required this.scale,
    required this.filterFor,
    required super.child,
  });

  final double scale;
  final ui.ImageFilter? Function(Offset originPhysical, Size size, double scale)
  filterFor;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGlassBackdrop(scale, filterFor);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGlassBackdrop renderObject,
  ) {
    renderObject
      ..scale = scale
      ..filterFor = filterFor;
  }
}

class _RenderGlassBackdrop extends RenderProxyBox {
  _RenderGlassBackdrop(this._scale, this._filterFor);

  final _layer = LayerHandle<_GlassBackdropLayer>();
  double _scale;
  ui.ImageFilter? Function(Offset, Size, double) _filterFor;
  ui.ImageFilter? _cachedFilter;
  Rect? _cachedBounds;
  Size? _cachedSize;
  double? _cachedScale;

  set scale(double value) {
    if (value == _scale) return;
    _scale = value;
    markNeedsPaint();
  }

  set filterFor(ui.ImageFilter? Function(Offset, Size, double) value) {
    _filterFor = value;
    _cachedFilter = null;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  ui.ImageFilter? _resolveFilter() {
    if (!hasSize || size.isEmpty) return null;
    final transform = getTransformTo(null);
    final bounds = MatrixUtils.transformRect(transform, Offset.zero & size);
    final matrix = transform.storage;
    final scale =
        _scale *
        math.min(
          math.sqrt(matrix[0] * matrix[0] + matrix[1] * matrix[1]),
          math.sqrt(matrix[4] * matrix[4] + matrix[5] * matrix[5]),
        );
    if (!scale.isFinite || scale <= 0) return null;
    if (_cachedFilter != null &&
        _cachedBounds == bounds &&
        _cachedSize == size &&
        _cachedScale == scale) {
      return _cachedFilter;
    }
    _cachedBounds = bounds;
    _cachedSize = size;
    _cachedScale = scale;
    return _cachedFilter = _filterFor(bounds.topLeft * _scale, size, scale);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _layer.layer ??= _GlassBackdropLayer(_resolveFilter);
    context.pushLayer(_layer.layer!, (context, offset) {}, offset);
    super.paint(context, offset);
  }

  @override
  void dispose() {
    _layer.layer = null;
    super.dispose();
  }
}

class _GlassBackdropLayer extends BackdropFilterLayer {
  _GlassBackdropLayer(this.resolveFilter);

  final ui.ImageFilter? Function() resolveFilter;
  ui.ImageFilter? _resolvedFilter;

  @override
  bool get alwaysNeedsAddToScene => true;

  @override
  ui.ImageFilter? get filter => _resolvedFilter;

  @override
  void addToScene(ui.SceneBuilder builder) {
    _resolvedFilter = resolveFilter();
    if (_resolvedFilter != null) super.addToScene(builder);
  }
}
