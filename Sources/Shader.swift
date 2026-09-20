// Copyright © 2026 TGTools123. NUEM, GNU GPL v3.
// Modified 2026-09-20 for NUEM-Essential: classic fold only.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct Uniforms {
    float4 radii; float4 margins;
    float2 size; float scale; float D;
    float A; float sinPhi; float s; float rMax;
    int levels; int black; float bottom; float top;
    float crop; float vignette; float vignetteReach; float vignetteEdge;
    float blurReach; float blurBottom; float grainy; float blurScale;
    float darkScale; float brightness;
    float4 hinge;
};
static float ign(float2 p) { return fract(52.9829189 * fract(0.06711056 * p.x + 0.00583715 * p.y)); }

struct VOut { float4 pos [[position]]; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    VOut o; o.pos = float4(p, 0, 1); return o;
}

fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]],
                      texture2d<float> sharp [[texture(0)]],
                      array<texture2d<float>, 4> blurs [[texture(1)]],
                      sampler smp [[sampler(0)]]) {
    if (U.black) return float4(0, 0, 0, 1);
    float2 pt = in.pos.xy / U.scale;                 // points, origin top-left

    float u = pt.x - U.size.x * 0.5;
    float v = U.size.y - pt.y;                        // distance from the hinge
    float yv = clamp(v / U.size.y, 0.0, 1.0);         // on screen: 0 = hinge, 1 = top edge

    // Hermite remap of the screen height: f(0) = 0, f(1) = 1, f'(0) = 1 − bottom, f'(1) = 1 − top.
    if (U.bottom > 0.0 || U.top > 0.0) {
        float t = yv, t2 = t * t, t3 = t2 * t;
        float f = (1.0 - U.bottom) * (t3 - 2.0 * t2 + t) + (-2.0 * t3 + 3.0 * t2) + (1.0 - U.top) * (t3 - t2);
        v = f * U.size.y;
    }

    // Tilted panel → upright content plane (ray from the eye): X = D·u/(D − v·sinφ), Y = A·v/(D − v·sinφ).
    float X, Y;                                                  // TGTools123
    if (U.hinge.x != 0.0) {
        // Lift about a hinge axis below the screen: the panel
        // point, in the picture plane's frame (along it from the axis, and out of it toward the eye), then where the
        // ray from the eye through it meets that plane.
        float cphi = sqrt(max(0.0, 1.0 - U.sinPhi * U.sinPhi));
        float a = U.hinge.x + v;                                  // along the lid, from the axis
        float yP = a * cphi - U.hinge.y * U.sinPhi;
        float zP = a * U.sinPhi - U.hinge.y * (1.0 - cphi);
        float den = U.D - zP;
        if (den <= 1.0) return float4(float3(0.0), 1.0);
        float t = U.D / den;
        X = t * u;
        Y = (U.hinge.z + t * (yP - U.hinge.z) - U.hinge.x) / (1.0 + U.crop);
    } else {
        float denom = U.D - v * U.sinPhi;
        if (denom <= 1.0) return float4(float3(0.0), 1.0);
        X = U.D * u / denom;
        Y = U.A * v / denom / (1.0 + U.crop);        // crop = extra vertical zoom anchored at the hinge
    }
    float yn = clamp(Y / U.size.y, 0.0, 1.0);
    float2 c = float2(X + U.size.x * 0.5, U.size.y - Y);   // content point, origin top-left

    // Blur front growing down from the top edge of the screen, soft leading edge, weaker at the hinge.
    float fromTop = 1.0 - yv;
    float behind = 1.0 - smoothstep(U.blurReach - 0.35, U.blurReach + 0.05, fromTop);
    float slope = mix(U.blurBottom, 1.0, pow(yv, 0.7));
    float blurK = clamp(behind * min(1.0, U.blurReach * 1.5) * slope, 0.0, 1.0);
    float R = U.rMax * blurK * U.blurScale;           // blur radius (points)

    float3 color = float3(0);
    if (c.x >= 0.0 && c.x <= U.size.x && c.y >= 0.0 && c.y <= U.size.y)
        color = sharp.sample(smp, c / U.size).rgb;    // snapshot: row 0 = top
    float prev = 0.0;
    for (int i = 0; i < U.levels; i++) {
        float r = U.radii[i];
        if (R <= prev) break;
        float t = clamp((R - prev) / (r - prev), 0.0, 1.0);
        float m = U.margins[i];
        // Core Image textures: row 0 = bottom, so y is measured from the hinge.
        float2 tc = float2((c.x + m) / (U.size.x + 2.0 * m), (U.size.y - c.y + m) / (U.size.y + 2.0 * m));
        color = mix(color, blurs[i].sample(smp, tc).rgb, t);   // clamp_to_zero: colors bleed into black
        prev = r;
    }

    // Grainy blur: 8 taps of the sharp image on a golden spiral rotated by per-pixel noise.
    if (U.grainy > 0.0 && R > 0.5) {
        float rot = ign(floor(c * U.scale) + float2(11.0, 5.0)) * 6.2831853;
        float3 acc = float3(0.0);
        for (int k = 0; k < 8; k++) {
            float a = rot + float(k) * 2.39996323;
            float2 cc = c + float2(cos(a), -sin(a)) * R * sqrt((float(k) + 0.5) / 8.0);
            if (cc.x >= 0.0 && cc.x <= U.size.x && cc.y >= 0.0 && cc.y <= U.size.y)
                acc += sharp.sample(smp, cc / U.size).rgb;
        }
        color = mix(color, acc / 8.0, U.grainy * smoothstep(0.5, 3.0, R));
    }

    // Black vignette from the top edge: solid over 60 % of its reach, then a gradient.
    float e = max(0.01, U.vignetteReach * (U.vignetteEdge / 0.25));
    color = mix(color, float3(0.0), U.vignette * (1.0 - smoothstep(U.vignetteReach * 0.6, max(0.02, U.vignetteReach + e), fromTop)));

    // iphone-duo's darkening (content space), behind the blur front.
    float g = max(0.0, (yn - 0.2) / 0.8);
    color *= 1.0 - min(1.0, 2.0 * U.s * pow(g, 1.35) * U.darkScale) * blurK;

    return float4(color * U.brightness, 1.0);
}
"""
