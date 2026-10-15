#version 460 core

// Page turn: the page folds back flat along a line, like a sheet of paper turned over.
//
// In the fold frame, x is the distance past the fold line along uAxisDir (towards the
// lifted edge). Paper past the fold (x > 0) has been lifted off; it lies face down on the
// page, mirrored across the fold, at s = p - 2x·n. So for each fragment:
//   1. the turned-over flap (plain back of the page)   x < 0, s inside the page
//   2. the untouched page (front)                      x < 0
//   3. the next page showing through (transparent)     x ≥ 0
// There is no roll: the bend is only suggested by shading across the flap near the fold.
// Colors are premultiplied; the layers are composited with antialiased edges.

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;       // page size in logical pixels
uniform vec2 uAxisPoint;  // a point on the fold line
uniform vec2 uAxisDir;    // unit vector perpendicular to the fold, towards the lifted edge
uniform float uRadius;    // softness of the fold's shading and shadows
uniform vec4 uBackColor;  // color of the back of the paper
uniform float uShadow;    // shadow strength, 0 to 1
uniform sampler2D uPage;  // snapshot of the turning page

out vec4 fragColor;

// Signed distance from p to the page rectangle: negative inside.
float pageDistance(vec2 p) {
  vec2 mid = uSize * 0.5;
  vec2 d = abs(p - mid) - mid;
  return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 n = uAxisDir;
  float soft = max(uRadius, 1.0);
  float x = dot(p - uAxisPoint, n);

  // Coverage of everything this side of the fold.
  float near = clamp(0.5 - x, 0.0, 1.0);

  // The flap, mirrored across the fold.
  vec2 s = p - 2.0 * x * n;
  float sd = pageDistance(s);
  float flapCover = clamp(0.5 - sd, 0.0, 1.0) * near;

  // The untouched page, darkened softly where the flap's free edges lie on it.
  vec4 front = texture(uPage, p / uSize);
  float edgeShade = (1.0 - smoothstep(0.0, soft * 0.4 + 4.0, max(sd, 0.0))) * 0.16 * uShadow;
  front.rgb *= 1.0 - edgeShade;

  // The next page, with the shadow of the lifted paper along the fold.
  float t = max(x, 0.0) / (soft * 1.2 + 6.0);
  float fall = 1.0 - clamp(t, 0.0, 1.0);
  vec4 shadow = vec4(0.0, 0.0, 0.0, fall * fall * fall * 0.26 * uShadow);

  vec4 under = front * near + shadow * (1.0 - near);

  // The back of the paper: plain, darker right at the fold where it bends away from the
  // light, then even, falling off a touch towards its free edge.
  float d = max(-x, 0.0);
  float light = mix(0.86, 1.0, smoothstep(0.0, soft * 1.6, d));
  light -= 0.035 * smoothstep(soft * 1.6, soft * 10.0, d);
  // A faint highlight just past the bend.
  light += 0.025 * exp(-pow((d - soft * 0.9) / (soft * 0.5), 2.0));
  vec4 flap = vec4(uBackColor.rgb * light, 1.0) * flapCover;

  fragColor = flap + under * (1.0 - flap.a);
}
