// Shared liquid-glass optics for Denial's backdrop-filter shaders.
//
// Includers define before including this file:
//   GLASS_CHROMA   1 to disperse R/G/B (three backdrop taps instead of one)
//   GLASS_RIM      1 to add the directional specular rim and saturation/tint
//
// Uniform layout is shared by every glass shader so the Dart side can fill
// them with a single routine (floats, in declaration order):
//   0-1 uTextureSize (engine-owned)  2 uRadius  3 uBezel  4 uIndex  5 uDepth  6 uChroma
//   7 uSpec  8 uLightAngle  9 uSat  10 uFlipY  11-14 uTint  15 uDebug  16-17 uOrigin  18-19 uSize  20 uRootYInverted

#include <flutter/runtime_effect.glsl>

uniform vec2 uTextureSize;
uniform float uRadius;
uniform float uBezel;
uniform float uIndex;
uniform float uDepth;
uniform float uChroma;
uniform float uSpec;
uniform float uLightAngle;
uniform float uSat;
uniform float uFlipY;
uniform vec4 uTint;
uniform float uDebug;
uniform vec2 uOrigin;
uniform vec2 uSize;
uniform float uRootYInverted;
uniform sampler2D uTex;

out vec4 fragColor;

// Signed distance to a rounded box and its outward unit gradient.
float sdRRect(vec2 p, vec2 half_size, float r, out vec2 grad) {
  r = min(r, min(half_size.x, half_size.y));
  vec2 q = abs(p) - half_size + r;
  vec2 s = vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
  float outside = length(max(q, 0.0));
  if (q.x > 0.0 || q.y > 0.0) {
    grad = s * max(q, 0.0) / max(outside, 1e-5);
  } else {
    grad = q.x > q.y ? vec2(s.x, 0.0) : vec2(0.0, s.y);
  }
  return min(max(q.x, q.y), 0.0) + outside - r;
}

// FlutterFragCoord is a position in the filter input. Denial's physical
// output canvas reflects Y before capturing that input. Undo the output
// reflection for shape geometry; sampling maps back into input coordinates
// and independently applies the legacy GLES texture-origin correction.
vec2 glassFrag() {
  vec2 frag = FlutterFragCoord().xy;
  if (uRootYInverted > 0.5) frag.y = uTextureSize.y - frag.y;
  return frag - uOrigin;
}

vec2 glassUv(vec2 frag) {
  vec2 inset = vec2(0.5) / uTextureSize;
  vec2 uv = clamp((frag + uOrigin) / uTextureSize, inset, vec2(1.0) - inset);
  if (uRootYInverted > 0.5) uv.y = 1.0 - uv.y;
// Flutter <= 3.44 rendered GLES filter textures with a flipped origin.
// Newer engines normalize owned filter textures and advertise the change
// through this compatibility macro; flipping them again samples the wrong
// rows (or transparent padding after blur).
#if defined(IMPELLER_TARGET_OPENGLES) && !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
  uv.y = 1.0 - uv.y;
#endif
  return vec2(uv.x, uFlipY > 0.5 ? 1.0 - uv.y : uv.y);
}

// Lateral backdrop displacement (in pixels) for a point `depth` px inside the
// edge of a convex glass bezel. The height profile is a circular arc; the
// refracted ray is traced through `uDepth` px of glass.
vec2 glassDisplacement(float depth, vec2 outward) {
  if (depth >= uBezel) return vec2(0.0);
  float t = clamp(depth / uBezel, 0.0, 1.0);
  float u = 1.0 - t;
  float slope = min(u / sqrt(max(1.0 - u * u, 1e-3)), 6.0);
  vec3 n = normalize(vec3(outward * slope, 1.0));
  vec3 r = refract(vec3(0.0, 0.0, -1.0), n, 1.0 / uIndex);
  return r.xy / max(-r.z, 1e-3) * uDepth;
}

vec4 glassShade(vec2 frag, float sd, vec2 outward) {
  float cover = 1.0 - smoothstep(-1.0, 0.5, sd);
  if (uDebug > 0.5) {
    // Shape probe: green outside the glass SDF, red inside, white contour
    // lines every 10 px of depth and at the bezel limit.
    if (cover <= 0.0) return vec4(0.0, 0.35, 0.0, 0.35);
    float band = abs(fract(-sd / 10.0 + 0.5) - 0.5) * 10.0;
    float line = 1.0 - smoothstep(0.0, 1.0, band);
    float limit = 1.0 - smoothstep(0.0, 1.5, abs(-sd - uBezel));
    float a = min(1.0, 0.25 + 0.4 * line + 0.6 * limit);
    return vec4(vec3(1.0, limit, limit) * a * 0.9, a);
  }
  if (cover <= 0.0) return vec4(0.0);
  vec2 disp = glassDisplacement(-sd, outward);
#if GLASS_CHROMA
  vec3 rgb = vec3(
      texture(uTex, glassUv(frag + disp * (1.0 + 0.5 * uChroma))).r,
      texture(uTex, glassUv(frag + disp)).g,
      texture(uTex, glassUv(frag + disp * (1.0 - 0.5 * uChroma))).b);
#else
  vec3 rgb = texture(uTex, glassUv(frag + disp)).rgb;
#endif
#if GLASS_RIM
  float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
  rgb = mix(vec3(luma), rgb, uSat);
  rgb = mix(rgb, uTint.rgb, uTint.a);
  vec2 light = vec2(cos(uLightAngle), sin(uLightAngle));
  float facing = max(dot(outward, light), 0.0) +
                 0.8 * max(dot(outward, -light), 0.0);
  float x = sd / 1.5;
  float rim = 1.0 / (1.0 + 0.89 * x * x);
  float bezelMask = 1.0 - smoothstep(0.0, uBezel, -sd);
  // Edges perpendicular to the light would otherwise get no rim at all and
  // look cut away; a weak ambient term keeps the outline continuous.
  float strength = 0.3 + facing * facing;
  rgb += vec3(strength * uSpec * rim * (0.35 + 0.65 * bezelMask));
#endif
  return vec4(clamp(rgb, 0.0, 1.0) * cover, cover);
}
