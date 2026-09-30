#version 460 core
#define GLASS_CHROMA 1
#define GLASS_RIM 1
#include "glass_core.glsl"

// Four rounded boxes (centre xy, half size zw) fused with a polynomial
// smooth-minimum; a zero half size disables a slot. uBlend is the fusion
// distance in pixels, uRound the corner radius as a fraction of the
// shorter half size.
uniform vec4 uShape0;
uniform vec4 uShape1;
uniform vec4 uShape2;
uniform vec4 uShape3;
uniform float uBlend;
uniform float uRound;

float smoothUnion(float a, float b, float k) {
  float e = max(k - abs(a - b), 0.0);
  return min(a, b) - e * e * 0.25 / max(k, 1e-3);
}

float shapeSd(vec2 frag, vec4 s, out vec2 g) {
  if (s.z <= 0.0) { g = vec2(0.0); return 1e6; }
  return sdRRect(frag - s.xy, s.zw, min(s.z, s.w) * uRound, g);
}

void main() {
  vec2 position = glassFrag();
  vec2 g0, g1, g2, g3;
  float d0 = shapeSd(position, uShape0, g0);
  float d1 = shapeSd(position, uShape1, g1);
  float d2 = shapeSd(position, uShape2, g2);
  float d3 = shapeSd(position, uShape3, g3);
  float sd = smoothUnion(smoothUnion(d0, d1, uBlend),
                         smoothUnion(d2, d3, uBlend), uBlend);
  // Outward direction from the blended field's weights: nearer shapes pull
  // the normal toward their own gradient.
  float w0 = exp(-max(d0, 0.0) * 0.25);
  float w1 = exp(-max(d1, 0.0) * 0.25);
  float w2 = exp(-max(d2, 0.0) * 0.25);
  float w3 = exp(-max(d3, 0.0) * 0.25);
  vec2 g = g0 * w0 + g1 * w1 + g2 * w2 + g3 * w3;
  vec2 outward = g / max(length(g), 1e-4);
  fragColor = glassShade(position, sd, outward);
}
