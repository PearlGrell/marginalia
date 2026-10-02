#version 460 core

// Page curl: the page wraps around a cylinder lying on the page.
//
// In the axis frame, x is the distance past the curl axis along uAxisDir (towards the
// lifted edge). The paper at arc length s past the axis sits on the cylinder for
// s in [0, πr] and lies flat, face down, on top of the page for s > πr. For each fragment,
// candidates are tried from the topmost layer down:
//   1. the flat turned-over flap (back of the page)   x < 0,  s = πr - x
//   2. the top half of the cylinder (back of the page) 0 ≤ x < r, s = r(π - asin(x/r))
//   3. the bottom half of the cylinder (front)         0 ≤ x < r, s = r·asin(x/r)
//   4. the untouched page (front)                      x < 0,  s = x
// Anything else shows the page underneath (transparent), with the curl's shadow on it.

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;       // page size in logical pixels
uniform vec2 uAxisPoint;  // a point on the curl axis
uniform vec2 uAxisDir;    // unit vector perpendicular to the axis, towards the lifted edge
uniform float uRadius;    // cylinder radius
uniform vec4 uBackColor;  // color of the back of the paper
uniform float uShadow;    // shadow strength, 0 to 1
uniform sampler2D uPage;  // snapshot of the turning page

out vec4 fragColor;

const float PI = 3.14159265359;

bool inPage(vec2 p) {
  return p.x >= 0.0 && p.y >= 0.0 && p.x <= uSize.x && p.y <= uSize.y;
}

vec4 frontAt(vec2 p, float light) {
  vec4 c = texture(uPage, p / uSize);
  return vec4(c.rgb * light, c.a);
}

// The back of the paper with the text showing faintly through, mirrored.
vec4 backAt(vec2 p, float light) {
  vec3 ink = texture(uPage, p / uSize).rgb;
  vec3 c = mix(uBackColor.rgb, ink, 0.10);
  return vec4(c * light, 1.0);
}

// Distance from p to the page rectangle (0 inside).
float outside(vec2 p) {
  vec2 d = max(max(-p, p - uSize), vec2(0.0));
  return length(d);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 n = uAxisDir;
  float r = max(uRadius, 0.001);
  float x = dot(p - uAxisPoint, n);
  vec2 base = p - n * x;

  if (x < 0.0) {
    // 1. The flap lying on top. Slightly darker near the fold, where it lifts off.
    vec2 s = base + n * (PI * r - x);
    if (inPage(s)) {
      float lift = smoothstep(0.0, r * 1.5, -x);
      fragColor = backAt(s, mix(0.86, 0.97, lift));
      return;
    }
    // 4. The untouched page, with a soft shadow along the flap's edge.
    vec4 c = frontAt(p, 1.0);
    float edge = outside(s);
    float shade = (1.0 - smoothstep(0.0, 10.0, edge)) * 0.18 * uShadow;
    fragColor = vec4(c.rgb * (1.0 - shade), c.a);
    return;
  }

  if (x < r) {
    float a = asin(clamp(x / r, 0.0, 1.0));

    // 2. Top of the cylinder: the back of the page, lit from above.
    vec2 sTop = base + n * (r * (PI - a));
    if (inPage(sTop)) {
      float up = -cos(PI - a); // 0 at the side of the cylinder, 1 at the top
      fragColor = backAt(sTop, mix(0.72, 1.0, up));
      return;
    }

    // 3. Underside of the cylinder: the front of the page, shaded towards the fold.
    vec2 sBottom = base + n * (r * a);
    if (inPage(sBottom)) {
      float facing = cos(a);
      fragColor = frontAt(sBottom, mix(0.62, 1.0, facing));
      return;
    }
  }

  // The next page shows through; the lifted paper casts a shadow on it.
  float d = x - r;
  float width = r * 1.2 + 12.0;
  float alpha = d > 0.0 ? pow(1.0 - clamp(d / width, 0.0, 1.0), 2.0) * 0.32 * uShadow : 0.0;
  fragColor = vec4(0.0, 0.0, 0.0, alpha);
}
