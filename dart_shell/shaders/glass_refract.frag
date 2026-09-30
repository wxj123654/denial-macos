#version 460 core
#define GLASS_CHROMA 0
#define GLASS_RIM 0
#include "glass_core.glsl"

void main() {
  vec2 position = glassFrag();
  vec2 outward;
  float sd = sdRRect(position - uSize * 0.5, uSize * 0.5, uRadius, outward);
  fragColor = glassShade(position, sd, outward);
}
