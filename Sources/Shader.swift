// NUEM (TGTools123). Copyright © 2026 TGTools123, GNU GPL v3.
// The whole effect in one Metal pass: inverse projection (screen pixel → content point), blur levels, fold style,
// grainy blur, black vignette and iphone-duo's darkening, per pixel.

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// Same layout as `Uniforms` in FoldOverlay.swift.
struct Uniforms {
    float4 radii; float4 margins;          // blur levels (points) and their margins (points)
    float2 size; float scale; float D;     // screen size (points), pixels per point, eye distance
    float A; float sinPhi; float s; float rMax;
    int levels; int black; float bottom; float top;
    float crop; float vignette; float vignetteReach; float vignetteEdge;
    float blurReach; float blurBottom; float grainy; float blurScale;
    float darkScale; float brightness;     // brightness: fade to black (never to transparent)
    float4 veil;                           // clock veil (x0, y0, x1, y1) of the snapshot, top-left origin; empty = off
    int style; int fx;                     // fold style: 0 classic, 1 glass, 2 particles, 3 CRT TV, 4 black & white, 5 hologram, 6 CRT filter; snap animation: 0 none, 1 ripple, 2 edge glow
    float styleAmount; float fxTime;       // how far the style has gone (0…1, from the lid angle); snap animation progress (0…1)
    float glassStrength; float particleSize; float time; float corner;   // corner: display corner radius (points)
    float4 holoColor;                      // hologram color (rgb)
    float4 fxColor;                        // snap animation color (rgb) and opacity (a)
    float particleGlow; float crtScan; float crtScanlines; float crtGlow;   // CRT: scanline period (points), gap darkness, bloom
    float crtSaturation; float crtMask; float crtCurve; float veilAmount;  // CRT: saturation, phosphor stripes, tube curvature; clock veil opacity
    float4 tint;                           // tinted blur (Classic, Frosted glass): color (rgb) and amount (a)
    float4 particleColor;                  // particles: a chosen color (rgb, a = 1), or the picture's own (a = 0)
    int fxOnly; int wallMask; int pad2; int pad3;   // fxOnly 1: the snap animation alone, over the real screen (premultiplied);
                                           // wallMask: colors from the wallpaper (1 hologram, 2 snap, 4 blur tint, 8 particles)
    float4 hinge;                          // exact perspective (w = 1): x the screen's bottom edge from the hinge axis, along
                                           // the lid; y the screen's surface in front of the axis; z the eye up the
                                           // picture's plane from the axis (points) — D is then the eye in front of
                                           // that plane.
    float4 background;                     // rgb: where no picture lands (Settings → Effect → Background color), and the vignette's
                                           // color; black = as before
    float4 kf0; float4 kf1; float4 kf2;    // Keyframes mode (kf0.w = 1): screen point → picture point, the rows of a homography
    float cornerBottom;                    // the bottom corners' radius (points); `corner` is the top's (Snap-Back → corners)
};
// NUEM's fold, written by TGTools123.

// Interleaved gradient noise (Jimenez): fixed per pixel, no visible pattern, no flicker.
static float ign(float2 p) { return fract(52.9829189 * fract(0.06711056 * p.x + 0.00583715 * p.y)); }

// A fixed random number per cell: the same cell always gives the same value, so every style is reversible.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Value noise with its gradient — one evaluation gives both — and a fractal sum of it: (value, d/dx, d/dy).
static float3 vnoised(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f), du = 6.0 * f * (1.0 - f);
    float a = hash21(i), b = hash21(i + float2(1, 0)), c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    float k = a - b - c + d;
    return float3(a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y,
                  du.x * ((b - a) + k * u.y), du.y * ((c - a) + k * u.x));
}

static float3 fbmd(float2 p, int octaves) {
    float3 sum = float3(0.0);
    float a = 0.5, s = 1.0;
    for (int i = 0; i < octaves; i++) {
        float3 n = vnoised(p);
        sum += a * float3(n.x, n.yz * s);
        p = p * 2.03 + 7.1; s *= 2.03; a *= 0.5;
    }
    return sum;
}

// The wallpaper's color at a point (points, top-left origin) of the small blurred matte, brightest channel at 1: a
// hue to light things with.
static float3 wallHue(texture2d<float> wall, sampler smp, float2 p, float2 size) {
    float3 w = wall.sample(smp, clamp(p / size, 0.02, 0.98), level(0.0)).rgb;
    return w / max(max(w.r, w.g), max(w.b, 0.05));
}

// Particles: when the particle of a cell leaves (dissolve progress 0…1) — mostly from the top down, with a ragged,
// random edge; all are off by half way.
static float leaveAt(float2 cell, constant Uniforms& U) {
    float yn = clamp((cell.y + 0.5) * U.particleSize / U.size.y, 0.0, 1.0);
    return 0.5 * (0.35 * hash21(cell) + 0.65 * yn);
}

// …and the picture under them thins out as they go: the same timing with the per-cell randomness smoothed into soft
// noise, so it never breaks into squares.
static float fadeField(float2 c, constant Uniforms& U) {
    float yn = clamp(c.y / U.size.y, 0.0, 1.0);
    float n = clamp(fbmd(c / (U.particleSize * 3.0), 2).x / 0.75, 0.0, 1.0);
    return 0.5 * (0.35 * n + 0.65 * yn);
}

// …then each one fades out at its own random moment before the progress reaches 1 (the lid at minAngle, where the
// screen goes black): fewer and fewer particles until none.
static float fadeAt(float2 cell, float leave) { return leave + (1.0 - leave) * (0.1 + 0.9 * hash21(cell + 53.0)); }

// Content point → screen point (both in points, top-left origin): the inverse of fmain's projection.
static float2 toScreen(float2 c, constant Uniforms& U) {
    if (U.kf0.w > 0.5) return c;                                 // Keyframes mode: no effect uses it (styles are off)
    float u, v;                                                  // the panel point: from the centre, up from the bottom edge
    if (U.hinge.w > 0.5 || U.hinge.x != 0.0) {                    // about a hinge axis below the screen (exact, or Lift)
        float cphi = sqrt(max(0.0, 1.0 - U.sinPhi * U.sinPhi));
        float qy = (U.size.y - c.y) * (1.0 + U.crop) + U.hinge.x;   // the picture point, up its plane from the axis
        float dy = qy - U.hinge.z, k = U.hinge.y * (1.0 - cphi);
        float a = (qy + dy * k / U.D + U.hinge.y * U.sinPhi) / (cphi + dy * U.sinPhi / U.D);   // along the lid
        float tr = 1.0 - (a * U.sinPhi - k) / U.D;              // the panel point on the way from the eye to the picture
        u = (c.x - U.size.x * 0.5) * tr;
        v = a - U.hinge.x;
    } else {
        float Y = (U.size.y - c.y) * (1.0 + U.crop);            // from the hinge, before the crop zoom
        v = Y * U.D / (U.A + Y * U.sinPhi);
        u = (c.x - U.size.x * 0.5) * (U.D - v * U.sinPhi) / U.D;
    }
    float target = v / U.size.y, t = target;
    if (U.bottom > 0.0 || U.top > 0.0) {                         // undo the Hermite remap (Newton)
        for (int i = 0; i < 4; i++) {
            float t2 = t * t, t3 = t2 * t;
            float f = (1.0 - U.bottom) * (t3 - 2.0 * t2 + t) + (-2.0 * t3 + 3.0 * t2) + (1.0 - U.top) * (t3 - t2);
            float df = (1.0 - U.bottom) * (3.0 * t2 - 4.0 * t + 1.0) + (-6.0 * t2 + 6.0 * t) + (1.0 - U.top) * (3.0 * t2 - 2.0 * t);
            t -= (f - target) / max(df, 0.05);
        }
    }
    return float2(u + U.size.x * 0.5, U.size.y - t * U.size.y);
}

struct VOut { float4 pos [[position]]; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    VOut o; o.pos = float4(p, 0, 1); return o;
}

fragment float4 fmain(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]],
                      texture2d<float> sharp [[texture(0)]],
                      array<texture2d<float>, 4> blurs [[texture(1)]],
                      texture2d<float> wall [[texture(5)]],
                      sampler smp [[sampler(0)]]) {
    if (U.black) return float4(0, 0, 0, 1);
    float2 pt = in.pos.xy / U.scale;                 // points, origin top-left

    // CRT: the screen itself becomes a curved tube, and the power-off squashes the folded picture toward the middle
    // of the screen — a line, then a dot.
    float tube = 1.0, crtLook = 0.0, crtWhite = 0.0, crtOff = 0.0;
    if (U.style == 3) {
        float q = U.styleAmount;
        crtLook = smoothstep(0.0, 0.35, q);
        crtOff = smoothstep(0.4, 0.48, q);                       // the power-off has begun: nothing else covers it
        float2 mid = U.size * 0.5;
        float2 d = (pt - mid) / U.size;
        d *= 1.0 + crtLook * U.crtCurve * dot(d, d);             // barrel curvature: rounded, dark corners
        float sy = max(0.004, 1.0 - smoothstep(0.45, 0.75, q));  // the picture collapses to a line…
        float sx = max(0.003, 1.0 - smoothstep(0.75, 0.9, q));   // …then to a dot…
        float2 out = abs(d) - 0.5 * float2(sx, sy);
        tube = (1.0 - smoothstep(-0.0015, 0.0015, max(out.x, out.y))) * (1.0 - smoothstep(0.93, 1.0, q));   // …which fades
        pt = mid + float2(d.x / sx, d.y / sy) * U.size;
        crtWhite = smoothstep(0.5, 0.85, q);                     // the collapsing line burns white
    } else if (U.style == 6) {
        crtLook = smoothstep(0.0, 0.2, U.styleAmount);          // CRT filter: the look only, fading in early
    }
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
    if (U.kf0.w > 0.5) {
        // Keyframes mode: the picture's trapezoid from the keyframes, one homography; nothing else moves it.
        float3 p = float3(pt, 1.0);
        float3 q = float3(dot(U.kf0.xyz, p), dot(U.kf1.xyz, p), dot(U.kf2.xyz, p));
        if (q.z <= 1e-6) return float4(U.background.rgb * U.brightness, 1.0);
        X = q.x / q.z - U.size.x * 0.5;
        Y = U.size.y - q.y / q.z;
    } else if (U.hinge.w > 0.5 || U.hinge.x != 0.0) {
        // Exact perspective (or Lift, with the tuning's eye and crop), about a hinge axis below the screen: the panel
        // point, in the picture plane's frame (along it from the axis, and out of it toward the eye), then where the
        // ray from the eye through it meets that plane.
        float cphi = sqrt(max(0.0, 1.0 - U.sinPhi * U.sinPhi));
        float a = U.hinge.x + v;                                  // along the lid, from the axis
        float yP = a * cphi - U.hinge.y * U.sinPhi;
        float zP = a * U.sinPhi - U.hinge.y * (1.0 - cphi);
        float den = U.D - zP;
        if (den <= 1.0) return float4(U.background.rgb * U.brightness, 1.0);
        float t = U.D / den;
        X = t * u;
        Y = (U.hinge.z + t * (yP - U.hinge.z) - U.hinge.x) / (1.0 + U.crop);   // crop is 0 with Exact perspective
    } else {
        float denom = U.D - v * U.sinPhi;
        if (denom <= 1.0) return float4(U.background.rgb * U.brightness, 1.0);
        X = U.D * u / denom;
        Y = U.A * v / denom / (1.0 + U.crop);        // crop = extra vertical zoom anchored at the hinge
    }
    float yn = clamp(Y / U.size.y, 0.0, 1.0);
    float2 c = float2(X + U.size.x * 0.5, U.size.y - Y);   // content point, origin top-left

    // Snap animation "ripple": a wobbling ring and two echoes leave the center and bend the picture.
    float3 fxGlow = float3(0.0);
    if (U.fx == 1) {
        float2 d = pt - U.size * 0.5;
        float r = length(d);
        float2 dir = r > 0.0 ? d / r : float2(0.0);
        float maxR = length(U.size) * 0.55, bend = 0.0, glow = 0.0;
        for (int e = 0; e < 3; e++) {
            float te = U.fxTime - float(e) * 0.12;
            if (te <= 0.0) continue;
            float k = clamp(te / 0.85, 0.0, 1.0);
            float ring = maxR * (1.0 - pow(1.0 - k, 2.2));         // eases out as it grows
            float x = (r - ring) / (40.0 + 60.0 * k);
            float env = exp(-x * x * 4.0) * (1.0 - k) * (e == 0 ? 1.0 : 0.5 / float(e));
            bend += sin(x * 9.0) * env;
            glow += env;
        }
        c += dir * bend * 14.0;
        fxGlow = float3(0.85, 0.92, 1.0) * glow * 0.35;
    }

    // Fold styles that move where the picture is read, before sampling (c0 = the content point before).
    float2 c0 = c;
    if (U.style == 5) {                                          // hologram: a few bands glitch sideways
        float h = smoothstep(0.05, 0.45, U.styleAmount);
        float band = floor(c.y / 18.0), tick = floor(U.time * 12.0);
        if (hash21(float2(band, tick)) > 0.93) c.x += (hash21(float2(band, tick + 3.0)) - 0.5) * 40.0 * h;
    }

    // Blur front growing down from the top edge of the screen, soft leading edge, weaker at the hinge.
    float fromTop = 1.0 - yv;
    float behind = 1.0 - smoothstep(U.blurReach - 0.35, U.blurReach + 0.05, fromTop);
    float slope = mix(U.blurBottom, 1.0, pow(yv, 0.7));
    float blurK = clamp(behind * min(1.0, U.blurReach * 1.5) * slope, 0.0, 1.0) * (1.0 - crtOff);
    float R = U.rMax * blurK * U.blurScale;           // blur radius (points)

    float3 color = float3(0);
    if (c.x >= 0.0 && c.x <= U.size.x && c.y >= 0.0 && c.y <= U.size.y)
        color = sharp.sample(smp, c / U.size).rgb;    // snapshot: row 0 = top
    if ((U.style == 3 || U.style == 6) && crtLook > 0.0) {   // CRT: the colors split a little, like an old tube
        float2 ab = float2((U.style == 3 ? 1.5 : 0.8) * crtLook, 0.0);
        color.r = sharp.sample(smp, (c + ab) / U.size).r;
        color.b = sharp.sample(smp, (c - ab) / U.size).b;
    }
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

    // Frosted glass: in front of the blur, behind the grain and the black.
    float2 glassShift = float2(0.0);
    float glassK = 0.0;
    if (U.style == 1 && U.styleAmount > 0.0 && U.levels > 3) {
        float k = U.styleAmount * mix(0.5, 1.0, 1.0 - clamp(c.y / U.size.y, 0.0, 1.0)) * U.glassStrength;
        glassK = k;
        // Relief of hammered, melting glass: fine ripples drawn out into vertical flows, plus finer detail — in
        // picture coordinates, so it moves, crops and tilts with the picture.
        float2 q = float2(c.x / 34.0, c.y / 60.0);
        float3 relief = fbmd(q, 4) + 0.35 * fbmd(q * 3.7 + 11.0, 2) * float3(1.0, 3.7, 3.7);
        float2 grad = relief.yz;                                    // slope of the relief
        glassShift = grad * 9.0 * k;                                // refraction, points
        // The picture behind — sharp and blurred alike — seen bent through it, more frosted as it thickens.
        float2 p = c + glassShift;
        float3 bent = (p.x >= 0.0 && p.x <= U.size.x && p.y >= 0.0 && p.y <= U.size.y) ? sharp.sample(smp, p / U.size).rgb : float3(0.0);
        float m2 = U.margins[2], m3 = U.margins[3];
        float3 l2 = blurs[2].sample(smp, float2((p.x + m2) / (U.size.x + 2.0 * m2), (U.size.y - p.y + m2) / (U.size.y + 2.0 * m2))).rgb;
        float3 l3 = blurs[3].sample(smp, float2((p.x + m3) / (U.size.x + 2.0 * m3), (U.size.y - p.y + m3) / (U.size.y + 2.0 * m3))).rgb;
        float3 seen = mix(bent, mix(l2, l3, clamp(k, 0.0, 1.0)), clamp(0.35 + 0.65 * k, 0.0, 1.0));
        color = mix(color, seen, clamp(k * 1.5, 0.0, 1.0));
        // Light on the glass follows the light coming through it (dark places let less through): glints on the
        // crests, slightly darker hollows, and a cool tint that never lightens.
        float luma = dot(color, float3(0.299, 0.587, 0.114));
        float3 normal = normalize(float3(-grad * 0.6, 1.0));
        float glint = pow(max(0.0, dot(normal, normalize(float3(-0.4, 0.6, 0.7)))), 20.0);
        float hollow = clamp(dot(normal.xy, float2(0.4, -0.6)), 0.0, 1.0);
        color *= mix(float3(1.0), float3(0.86, 0.93, 1.0), 0.6 * k);
        color += k * 1.2 * glint * luma;
        color *= 1.0 - 0.25 * k * hollow;
    }

    // Grainy blur: 8 taps of the sharp image on a golden spiral rotated by per-pixel noise (seen through the glass).
    if (U.grainy > 0.0 && R > 0.5) {
        float rot = ign(floor(c * U.scale) + float2(11.0, 5.0)) * 6.2831853;
        float3 acc = float3(0.0);
        for (int k = 0; k < 8; k++) {
            float a = rot + float(k) * 2.39996323;
            float2 cc = c + glassShift + float2(cos(a), -sin(a)) * R * sqrt((float(k) + 0.5) / 8.0);
            if (cc.x >= 0.0 && cc.x <= U.size.x && cc.y >= 0.0 && cc.y <= U.size.y)
                acc += sharp.sample(smp, cc / U.size).rgb;
        }
        color = mix(color, acc / 8.0, U.grainy * smoothstep(0.5, 3.0, R));
    }

    // Tinted blur (Classic, Frosted glass): where the picture is blurred — or behind the glass — it takes on the
    // tint's hue, like tinted glass: it keeps its light.
    if (U.style <= 1 && U.tint.a > 0.0) {
        float k = clamp(U.tint.a * max(blurK, min(glassK, 1.0)), 0.0, 1.0);
        float3 hue = (U.wallMask & 4) != 0 ? wallHue(wall, smp, c, U.size) : U.tint.rgb / max(max(U.tint.r, U.tint.g), max(U.tint.b, 0.05));
        float luma = dot(color, float3(0.299, 0.587, 0.114));
        color = mix(color, mix(color, luma * hue * 1.2, 0.8), k);
    }

    // Particles: the picture thins out as its particles leave — softly, never cell by cell — glowing a little as it
    // goes.
    if (U.style == 2 && U.styleAmount > 0.0) {
        float t = fadeField(c, U);
        float gone = smoothstep(t - 0.04, t + 0.04, U.styleAmount);
        float heat = smoothstep(t - 0.1, t, U.styleAmount) * (1.0 - gone);
        color *= (1.0 - gone) * (1.0 + heat * 0.5 * U.particleGlow);
    }

    // CRT look, both CRT styles: scanlines (dark gaps between bright lines), RGB phosphor stripes, bloom from the
    // blurred picture — its bright parts most — and livelier colors.
    if ((U.style == 3 || U.style == 6) && crtLook > 0.0) {
        float P = U.crtScan;
        float pxY = P / max(fwidth(c0.y), 1e-4), pxX = P / max(fwidth(c0.x), 1e-4);   // periods on screen, pixels
        float line = 0.5 + 0.5 * cos(c0.y * 6.2831853 / P);
        float scanK = U.crtScanlines * crtLook * smoothstep(2.5, 5.0, pxY);
        color *= mix(1.0, mix(0.18, 1.0, line) * 1.45, scanK);
        float3 stripes = 0.5 + 0.5 * cos(6.2831853 * (c0.x / P - float3(0.0, 1.0 / 3.0, 2.0 / 3.0)));
        color *= mix(float3(1.0), 0.3 + 1.4 * stripes, U.crtMask * crtLook * smoothstep(2.5, 5.0, pxX));
        float m1 = U.margins[1], m2 = U.margins[2];
        float3 b1 = blurs[1].sample(smp, float2((c.x + m1) / (U.size.x + 2.0 * m1), (U.size.y - c.y + m1) / (U.size.y + 2.0 * m1))).rgb;
        float3 b2 = blurs[2].sample(smp, float2((c.x + m2) / (U.size.x + 2.0 * m2), (U.size.y - c.y + m2) / (U.size.y + 2.0 * m2))).rgb;
        float3 bloom = 0.5 * (b1 + b2);
        float bright = smoothstep(0.2, 0.9, dot(bloom, float3(0.299, 0.587, 0.114)));
        color += crtLook * U.crtGlow * bloom * (0.1 + 0.55 * bright);
        float l = dot(color, float3(0.299, 0.587, 0.114));
        color = max(float3(0.0), mix(float3(l), color, mix(1.0, U.crtSaturation, crtLook)));
        color *= 1.0 - (U.style == 3 ? 0.05 : 0.03) * crtLook * hash21(float2(floor(U.time * 30.0), 1.0));   // flicker
    }
    // CRT TV: the collapsing line burns white, and only the tube shows.
    if (U.style == 3) {
        color = mix(color, float3(1.0), crtWhite * 0.8) * (1.0 + crtWhite * 1.5);
        color *= tube;
    }
    // Black & white: the colors drain out (the top a little earlier — a fixed gradient, not a front), with a touch of
    // film contrast and grain.
    if (U.style == 4) {
        float k = clamp(U.styleAmount * 1.7 * mix(0.75, 1.0, 1.0 - clamp(c.y / U.size.y, 0.0, 1.0)), 0.0, 1.0);
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        float film = smoothstep(0.02, 0.98, luma) + (hash21(floor(c0 * U.scale) + floor(U.time * 24.0)) - 0.5) * 0.06 * k;
        color = mix(color, float3(film), k);
    }
    // Hologram: the picture turns into cyan light — outlines brightest, drifting interlace, flicker — then fades
    // until nothing is left; opening, it appears faint and flickering and turns solid.
    if (U.style == 5) {
        float q = U.styleAmount;
        float h = smoothstep(0.05, 0.45, q);                     // how much of a hologram it has become
        float there = 1.0 - smoothstep(0.55, 1.0, q);            // …and how much of it is still there
        float m1 = U.margins[1];
        float3 soft = blurs[1].sample(smp, float2((c.x + m1) / (U.size.x + 2.0 * m1), (U.size.y - c.y + m1) / (U.size.y + 2.0 * m1))).rgb;
        float luma = dot(color, float3(0.299, 0.587, 0.114));
        float edges = length(color - soft);
        float flicker = 0.85 + 0.15 * hash21(float2(floor(U.time * 20.0), 7.0));
        float lines = 0.7 + 0.3 * sin(c.y * 2.2 - U.time * 9.0);
        float3 hc = (U.wallMask & 1) != 0 ? wallHue(wall, smp, c, U.size)                             // its brightest
                  : U.holoColor.rgb / max(max(U.holoColor.r, U.holoColor.g), max(U.holoColor.b, 0.05));
        float3 holo = hc * (0.9 * luma + 2.2 * edges) * lines * flicker;
        color = mix(color, holo * there, h);
    }

    // Clock veil: the clock of a lock screen captured earlier shows an old time — frost it with a wide ring of the
    // most blurred level, feathered at the edges.
    if (U.veil.z > U.veil.x && U.levels > 0 && U.veilAmount > 0.0) {
        float2 n = c / U.size;
        float e = 0.02;
        float m = smoothstep(U.veil.x - e, U.veil.x + e, n.x) * (1.0 - smoothstep(U.veil.z - e, U.veil.z + e, n.x))
                * smoothstep(U.veil.y - e, U.veil.y + e, n.y) * (1.0 - smoothstep(U.veil.w - e, U.veil.w + e, n.y));
        if (m > 0.0) {
            int L = U.levels - 1;
            float mg = U.margins[L], r = max(3.0 * U.radii[L], 0.04 * U.size.y);
            float3 acc = float3(0.0);
            for (int k = 0; k < 8; k++) {
                float a = float(k) * 0.78539816;
                float2 p = c + float2(cos(a), sin(a)) * r;
                float2 tc = float2((p.x + mg) / (U.size.x + 2.0 * mg), (U.size.y - p.y + mg) / (U.size.y + 2.0 * mg));
                acc += blurs[L].sample(smp, tc).rgb;
            }
            color = mix(color, acc / 8.0, m * U.veilAmount);
        }
    }

    // Background color: where no picture lands — around a picture the fold moved in from the edges (Lift, Crop).
    if (any(U.background.rgb > 0.0)) {
        float2 inside = min(c, U.size - c);                      // > 0 within the picture
        color = mix(U.background.rgb, color, smoothstep(-0.5, 0.5, min(inside.x, inside.y)));
    }

    // Black vignette from the top edge: solid over 60 % of its reach, then a gradient.
    float e = max(0.01, U.vignetteReach * (U.vignetteEdge / 0.25));
    // In the background color, so it blends into the empty area around the picture (black: as before).
    color = mix(color, U.background.rgb, U.vignette * (1.0 - crtOff) * (1.0 - smoothstep(U.vignetteReach * 0.6, max(0.02, U.vignetteReach + e), fromTop)));

    // iphone-duo's darkening (content space), behind the blur front.
    float g = max(0.0, (yn - 0.2) / 0.8);
    color *= 1.0 - min(1.0, 2.0 * U.s * pow(g, 1.35) * U.darkScale) * blurK;

    // Snap animations, all built on the edge glow: a stroke around the screen's border, fast in, easing out.
    float3 before = color;
    float fxMask = 0.0;
    if (U.fx >= 2) {
        float t = U.fxTime;
        float a = smoothstep(0.0, 0.12, t) * pow(1.0 - smoothstep(0.12, 1.0, t), 2.0);
        float k = a * U.fxColor.a;                                // …times its opacity
        float2 mid = U.size * 0.5;
        float r = pt.y < mid.y ? U.corner : U.cornerBottom;       // the screen's own corners, top and bottom
        float2 q = abs(pt - mid) - (mid - r);
        float inside = -(length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r);   // distance to the border (points)
        float3 tint = (U.wallMask & 2) != 0 ? wallHue(wall, smp, pt, U.size) : U.fxColor.rgb;   // the wallpaper's along each edge
        if (U.fx == 2) {                                          // edge glow
            float stroke = exp(-(inside - 2.0) * (inside - 2.0) / 3.0);
            float aura = exp(-max(inside, 0.0) / 28.0);
            fxGlow += tint * (0.9 * stroke + 0.45 * aura) * k;
        } else if (U.fx == 3) {                                   // frosted glow: seen through hammered glass
            float2 g = fbmd(float2(pt.x / 34.0, pt.y / 60.0), 3).yz;
            float d = inside + (g.x + g.y) * 6.0;                 // the rim, bent by the glass
            float stroke = exp(-(d - 3.0) * (d - 3.0) / 10.0);
            float aura = exp(-max(d, 0.0) / 40.0);
            float3 normal = normalize(float3(-g * 0.6, 1.0));
            float glint = pow(max(0.0, dot(normal, normalize(float3(-0.4, 0.6, 0.7)))), 20.0);
            fxGlow += mix(tint, float3(0.86, 0.93, 1.0), 0.4) * (0.7 * stroke + 0.5 * aura) * (1.0 + 1.5 * glint) * k;
        } else if (U.fx == 4) {                                   // particle burst: the stroke flashes, then leaves as particles (svertex)
            float flash = smoothstep(0.0, 0.05, t) * (1.0 - smoothstep(0.05, 0.25, t));
            fxGlow += tint * exp(-(inside - 2.0) * (inside - 2.0) / 3.0) * flash * U.fxColor.a;
        } else if (U.fx == 5) {                                   // CRT glow: scanlines through it, its colors split, flicker
            float lines = mix(0.35, 1.0, 0.5 + 0.5 * cos(pt.y * 6.2831853 / U.crtScan));
            float3 split = float3(exp(-(inside - 0.5) * (inside - 0.5) / 3.0), exp(-(inside - 2.0) * (inside - 2.0) / 3.0),
                                  exp(-(inside - 3.5) * (inside - 3.5) / 3.0));
            float aura = exp(-max(inside, 0.0) / 34.0);
            float flicker = 0.85 + 0.15 * hash21(float2(floor(U.time * 30.0), 5.0));
            fxGlow += tint * (1.5 * split + 0.8 * aura) * lines * flicker * k;
        } else if (U.fx == 6) {                                   // inverted glow: a black glow, the colors turned over under its edge
            float band = exp(-(inside - 4.0) * (inside - 4.0) / 30.0);
            float aura = exp(-max(inside, 0.0) / 36.0);
            float3 inverted = 1.0 - color;
            float dark = clamp(0.9 * aura * k, 0.0, 1.0), over = clamp(1.2 * band * k, 0.0, 1.0);
            color = mix(color * (1.0 - dark), inverted, over);
            fxMask = dark + over - dark * over;
        } else if (U.fx == 7) {                                   // hologram glow: the hologram's color, interlaced, glitching
            float3 hc = (U.wallMask & 1) != 0 ? wallHue(wall, smp, pt, U.size)
                      : U.holoColor.rgb / max(max(U.holoColor.r, U.holoColor.g), max(U.holoColor.b, 0.05));
            float band = floor(pt.y / 18.0), tick = floor(U.time * 12.0);
            float d = inside + (hash21(float2(band, tick)) > 0.85 ? (hash21(float2(band, tick + 3.0)) - 0.5) * 24.0 : 0.0);
            float stroke = exp(-(d - 2.0) * (d - 2.0) / 3.0);
            float aura = exp(-max(d, 0.0) / 30.0);
            float lines = 0.6 + 0.4 * sin(pt.y * 2.2 - U.time * 9.0);
            float flicker = 0.8 + 0.2 * hash21(float2(floor(U.time * 20.0), 9.0));
            fxGlow += hc * (0.9 * stroke + 0.5 * aura) * lines * flicker * k;
        }
    }
    if (U.fxOnly != 0) {
        // A valid premultiplied color: the light covers as much as its brightest channel (the compositor drops light
        // with no coverage).
        float3 rgb = (max(color - before * (1.0 - fxMask), 0.0) + fxGlow) * U.brightness;
        float a = clamp(max(fxMask, max(rgb.r, max(rgb.g, rgb.b))), 0.0, 1.0);
        return float4(min(rgb, a), a);
    }
    return float4((color + fxGlow) * U.brightness, 1.0);
}

// Particles: one sprite per cell of the snapshot, colored by that cell, glowing, drifting up and aside after it
// leaves.
struct PVOut { float4 pos [[position]]; float2 uv; float3 color; float alpha; float glow; float over; };   // over: on the see-through snap window

vertex PVOut pvertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& U [[buffer(0)]],
                     texture2d<float> colors [[texture(0)]], texture2d<float> wall [[texture(1)]],
                     sampler smp [[sampler(0)]]) {
    PVOut o;
    float s = U.particleSize;
    uint cols = uint(ceil(U.size.x / s));
    float2 cell = float2(float(iid % cols), float(iid / cols));
    float leave = leaveAt(cell, U);
    float age = (U.styleAmount - leave) / (fadeAt(cell, leave) - leave);   // 0 → 1 over this particle's own life
    o.uv = float2(0.0); o.color = float3(0.0); o.alpha = 0.0; o.glow = U.particleGlow; o.over = float(U.fxOnly);
    if (age <= 0.0 || age >= 1.0) { o.pos = float4(-3.0, -3.0, 0.0, 1.0); return o; }
    float h = hash21(cell + 17.0), h2 = hash21(cell + 91.0);
    float2 origin = (cell + 0.5) * s;
    float2 drift = float2((h - 0.5) * 180.0 * age + sin(age * 5.0 + h2 * 6.2831853) * 22.0 * age,
                          -(80.0 + 240.0 * h2) * age * age);      // up, and faster and faster
    float2 p = toScreen(origin + drift, U);
    float quad = s * mix(1.2, 0.5, age) * 4.5;                   // the particle and its aura
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 q = p + corner * quad * 0.5;
    o.pos = float4(q.x / U.size.x * 2.0 - 1.0, 1.0 - q.y / U.size.y * 2.0, 0.0, 1.0);
    o.uv = corner;
    float m = U.margins[0];
    float2 tc = float2((origin.x + m) / (U.size.x + 2.0 * m), (U.size.y - origin.y + m) / (U.size.y + 2.0 * m));
    float3 own = colors.sample(smp, tc, level(0.0)).rgb;         // the cell's own color…
    float luma = dot(own, float3(0.299, 0.587, 0.114));
    float3 chosen = (U.wallMask & 8) != 0 ? wallHue(wall, smp, origin, U.size) : U.particleColor.rgb;
    o.color = mix(own, chosen * (0.4 + 0.8 * luma), U.particleColor.a);   // …or the chosen one, shaded by it
    o.alpha = smoothstep(0.0, 0.05, age) * (1.0 - smoothstep(0.75, 1.0, age)) * U.brightness;   // bright, then fades out at its end
    return o;
}

// Particle burst (snap animation): one sprite every 5 pt along the screen's edge, in the picture's color (a little of
// the snap color), leaving inward and aside as the edge's flash fades, each a little later than the last.
vertex PVOut svertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& U [[buffer(0)]],
                     texture2d<float> colors [[texture(0)]], texture2d<float> wall [[texture(1)]],
                     sampler smp [[sampler(0)]]) {
    PVOut o;
    float2 S = U.size;
    float per = 2.0 * (S.x + S.y), n = floor(per / 5.0);
    float h = hash21(float2(float(iid), 3.0)), h2 = hash21(float2(float(iid), 11.0)), h3 = hash21(float2(float(iid), 29.0));
    float s = (float(iid) + h) / n * per;                        // along the edge, clockwise from the top-left corner
    float2 p, normal;                                            // on the edge, and pointing inward
    if (s < S.x) { p = float2(s, 0.0); normal = float2(0.0, 1.0); }
    else if (s < S.x + S.y) { p = float2(S.x, s - S.x); normal = float2(-1.0, 0.0); }
    else if (s < 2.0 * S.x + S.y) { p = float2(S.x - (s - S.x - S.y), S.y); normal = float2(0.0, -1.0); }
    else { p = float2(0.0, S.y - (s - 2.0 * S.x - S.y)); normal = float2(1.0, 0.0); }
    float r = p.y < S.y * 0.5 ? U.corner : U.cornerBottom;       // in a rounded corner: onto its arc, pointing to its centre
    if ((p.x < r || p.x > S.x - r) && (p.y < r || p.y > S.y - r)) {
        float2 c = clamp(p, float2(r), S - float2(r));
        float2 d = normalize(p - c);
        p = c + d * r;
        normal = -d;
    }
    p += normal * 2.0;
    float t = clamp((U.fxTime - 0.1 - 0.12 * h3) / 0.78, 0.0, 1.0);
    o.uv = float2(0.0); o.color = float3(0.0); o.alpha = 0.0; o.glow = 1.0; o.over = float(U.fxOnly);
    if (t <= 0.0 || t >= 1.0) { o.pos = float4(-3.0, -3.0, 0.0, 1.0); return o; }
    float ease = 1.0 - (1.0 - t) * (1.0 - t);
    float2 tangent = float2(-normal.y, normal.x);
    float2 q = p + normal * (10.0 + 80.0 * h2) * ease + tangent * (h - 0.5) * 36.0 * ease;
    float quad = mix(11.0, 5.0, t) * (0.7 + 0.6 * h2);           // the particle and its aura
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 v = q + corner * quad * 0.5;
    o.pos = float4(v.x / S.x * 2.0 - 1.0, 1.0 - v.y / S.y * 2.0, 0.0, 1.0);
    o.uv = corner;
    float m = U.margins[0];
    float2 tc = float2((p.x + m) / (S.x + 2.0 * m), (S.y - p.y + m) / (S.y + 2.0 * m));
    float3 own = colors.sample(smp, tc, level(0.0)).rgb;
    float3 chosen = (U.wallMask & 8) != 0 ? wallHue(wall, smp, p, S) : U.particleColor.rgb;
    float3 base = mix(own, chosen * (0.4 + 0.8 * dot(own, float3(0.299, 0.587, 0.114))), U.particleColor.a);
    o.color = mix(base * 1.3 + 0.15, (U.wallMask & 2) != 0 ? wallHue(wall, smp, p, S) : U.fxColor.rgb, 0.3);
    o.alpha = smoothstep(0.0, 0.08, t) * pow(1.0 - t, 1.5) * U.fxColor.a * U.brightness;
    return o;
}

// A particle keeps its color: its core covers what's under it (premultiplied alpha), and only its glow — a halo of
// its color and a hint of white at the center — adds light.
fragment float4 pfragment(PVOut in [[stage_in]]) {
    float d = length(in.uv);                                     // 0 = center, 1 = edge of the sprite
    float core = smoothstep(0.26, 0.16, d);
    float hot = smoothstep(0.12, 0.0, d) * 0.35 * in.glow;
    float aura = exp(-d * d * 6.0) * 0.55 * in.glow;
    float3 light = (in.color * (core * 1.15 + aura) + hot) * in.alpha;
    float a = core * in.alpha;
    if (in.over > 0.5) {                                          // over the real screen: a valid premultiplied color
        a = max(a, min(1.0, max(light.r, max(light.g, light.b))));
        light = min(light, a);
    }
    return float4(light, a);
}
"""
