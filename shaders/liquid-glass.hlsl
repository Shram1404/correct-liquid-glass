// liquid-glass.hlsl - iOS-style "liquid glass" refraction, single full-screen pass (ps_5_0).
//
// Pipeline per pixel inside a shape:
//   1. SDF of all shapes (rounded rects: circle, pill, rounded rectangle) -> distance d, outward normal n.
//   2. Thin bevel acts as a thick lens: sample position is pushed inward by A*(1-x)^2 (x = 0 at the rim, 1 in the flat centre).
//   3. Extra bends measured from the corner-shrunk inner rectangle, so straight edges stay flat and only corners bend.
//   4. 12-tap disc blur + tiny chromatic split, both scaled by how bent the pixel is.
//   5. Light pipe: colour found just outside the contour is averaged ALONG the contour and mixed into the bevel.
//   6. Grey tint, 1px lit rim (light from top-left), anti-aliased shape edge.
// All constants are intentional; see the README parameter table.
//
// constant buffer: winSize/texSize in px; shapes[k] = x,y,w,h; shapeR[k] = (corner radius, half-height); flags = test pattern.
cbuffer C : register(b0)
{
    float2 winSize; float2 texSize;
    float4 shapes[6];                               // x, y, w, h per glass shape
    float4 shapeR[6];                               // x = corner radius, y = half-height (lens scale)
    float4 flags;                                   // x = test pattern on, y = test mode
};
Texture2D T : register(t0);
SamplerState S : register(s0);

struct V { float4 pos : SV_Position; };

V VS(uint id : SV_VertexID)
{
    V o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// Signed distance to a rounded rectangle (negative inside).
float sdBox(float2 p, float4 r, float rad)
{
    float2 c = r.xy + r.zw * 0.5;
    float2 q = abs(p - c) - r.zw * 0.5 + rad;
    return length(max(q, 0)) + min(max(q.x, q.y), 0) - rad;
}

float scene(float2 p)
{
    float d = 1e9;
    [unroll] for (int k = 0; k < 6; k++) d = min(d, sdBox(p, shapes[k], shapeR[k].x));
    return d;
}

int nearest(float2 p)
{
    int best = 0; float bd = 1e9;
    [unroll] for (int k = 0; k < 6; k++) { float dk = sdBox(p, shapes[k], shapeR[k].x); if (dk < bd) { bd = dk; best = k; } }
    return best;
}
// One background sample in window pixels (or the synthetic test pattern, so screenshots never show a real desktop).
float3 tap(float2 px)
{
    if (flags.x > 0.5) // test pattern: light checker + black disc partly under the left pill
    {
        float2 c = floor(px / 8.0);
        float3 col = fmod(c.x + c.y, 2.0) < 1.0 ? 0.85 : 0.65;
        bool purple = flags.y < 0.5
            ? px.x < winSize.x * 0.5 - shapes[1].z * 0.25                       // mode 1: left part of the screen
            : (px.y > shapes[0].y + shapes[0].w * 0.4 && px.y < shapes[3].y - 4) // mode 2: bottom 60% of each row
              || px.y > shapes[3].y + shapes[3].w * 0.4;
        if (purple) col = float3(0.45, 0.2, 0.75);
        return col;
    }
    return T.SampleLevel(S, px / texSize, 0).rgb;
}

// Rounded-rect contour (corner radius r; r = h/2 is a stadium, r = w/2 = h/2 a circle).
// Arc length s runs: top edge → TR corner → right edge → BR → bottom → BL → left → TL.
static const float PI = 3.14159265;
float rrPerim(float2 hs, float r) { return 4.0 * (hs.x - r) + 4.0 * (hs.y - r) + 2.0 * PI * r; }

float rrArc(float2 c, float2 hs, float r, float2 p) // arc length of the contour point nearest to p
{
    float a = hs.x - r, b = hs.y - r, T = 2.0 * a, Q = PI * r * 0.5, R = 2.0 * b;
    float2 l = p - c, q = abs(l) - float2(a, b);
    if (q.x > 0 && q.y > 0)
    {
        float ang = atan2(q.y, q.x);                // 0 = horizontal side, pi/2 = vertical side of the corner
        if (l.x > 0 && l.y < 0) return T + (PI * 0.5 - ang) * r;
        if (l.x > 0) return T + Q + R + ang * r;
        if (l.y > 0) return 2.0 * T + 2.0 * Q + R + (PI * 0.5 - ang) * r;
        return 2.0 * T + 3.0 * Q + 2.0 * R + ang * r;
    }
    if (q.x > q.y) return l.x > 0 ? T + Q + (l.y + b) : 2.0 * T + 3.0 * Q + R + (b - l.y);
    return l.y < 0 ? (l.x + a) : T + 2.0 * Q + R + (a - l.x);
}

void rrAt(float2 c, float2 hs, float r, float s, out float2 pt, out float2 nrm) // contour point + outward normal
{
    float a = hs.x - r, b = hs.y - r, T = 2.0 * a, Q = PI * r * 0.5, R = 2.0 * b;
    float P = 2.0 * T + 4.0 * Q + 2.0 * R;
    s = s - floor(s / P) * P;
    float g;
    if (s < T) { nrm = float2(0, -1); pt = c + float2(-a + s, -hs.y); return; } s -= T;
    if (s < Q) { g = -PI * 0.5 + s / r; nrm = float2(cos(g), sin(g)); pt = c + float2(a, -b) + nrm * r; return; } s -= Q;
    if (s < R) { nrm = float2(1, 0); pt = c + float2(hs.x, -b + s); return; } s -= R;
    if (s < Q) { g = s / r; nrm = float2(cos(g), sin(g)); pt = c + float2(a, b) + nrm * r; return; } s -= Q;
    if (s < T) { nrm = float2(0, 1); pt = c + float2(a - s, hs.y); return; } s -= T;
    if (s < Q) { g = PI * 0.5 + s / r; nrm = float2(cos(g), sin(g)); pt = c + float2(-a, b) + nrm * r; return; } s -= Q;
    if (s < R) { nrm = float2(-1, 0); pt = c + float2(-hs.x, b - s); return; } s -= R;
    g = PI + s / r; nrm = float2(cos(g), sin(g)); pt = c + float2(-a, -b) + nrm * r;
}

static const float2 disc[12] = {
    float2(1, 0), float2(0.5, 0.866), float2(-0.5, 0.866), float2(-1, 0), float2(-0.5, -0.866), float2(0.5, -0.866),
    float2(0.5, 0), float2(0.25, 0.433), float2(-0.25, 0.433), float2(-0.5, 0), float2(-0.25, -0.433), float2(0.25, -0.433) };

float4 PS(V i) : SV_Target
{
    float2 p = i.pos.xy;
    float d = scene(p);
    float3 bg = tap(p);
    if (d > 1.0) return float4(bg, 1);

    int si = nearest(p);
    float4 pl = shapes[si];
    float pr = shapeR[si].x, radius = shapeR[si].y;
    float e = 0.5;
    float2 n = normalize(float2(scene(p + float2(e, 0)) - scene(p - float2(e, 0)),
                                scene(p + float2(0, e)) - scene(p - float2(0, e))) + 1e-5);
    // Thick cylindrical lens (Telegram/iOS): near the rim rays bend so hard that they sample DEEP inside,
    // up to ~0.7 of the bar height away, past the centre - so content filling the bottom ~70% also shows up,
    // mirrored, on the top rim. Allowed to fold over (real thick glass inverts the image at the edge).
    float bezel = radius * 0.25;                    // thin bevel: only the outer quarter of the half-height bends
    float A = radius * 0.9;                         // at the very rim: sample 0.45 * height inward
    float x = saturate(-d / bezel);                 // 0 at the outer edge, 1 at the flat top
    float shift = A * (1.0 - x) * (1.0 - x);
    float2 q = p - n * shift;
    // No lengthwise centre: both extra bends are relative to the shape's medial AXIS (the centre line along
    // its length), so straight parts are identical everywhere and only the rounded ends bend radially.
    float2 cen = pl.xy + pl.zw * 0.5;
    // inner rect = the shape shrunk by its corner radius: a segment for a stadium, a point for a circle,
    // a real rectangle for a rounded rect - so straight edges stay flat and bending grows only toward corners
    float2 inner = max(pl.zw * 0.5 - pr, 0.0);
    float2 med = clamp(p, cen - inner, cen + inner);
    float2 fromAxis = p - med;
    q += fromAxis / max(radius, 1.0) * radius * 0.15 * (1.0 - x) * (1.0 - x); // rim: minimal outward bow
    q -= fromAxis * 0.03 * x;                                                 // flat part: weaker opposite bend

    float slope = (1.0 - x) * (1.0 - x);           // how "bent" this pixel is, for blur/chroma
    float blurR = lerp(2.0, 0.3, slope);
    float3 acc = 0;
    [unroll] for (int j = 0; j < 12; j++) acc += tap(q + disc[j] * blurR);
    acc /= 12;
    float ca = slope * 1.2;                         // subtle chromatic split only on the bevel
    acc.r = lerp(acc.r, tap(q + n * ca).r, 0.6);
    acc.b = lerp(acc.b, tap(q - n * ca).b, 0.6);

    // Light-pipe rim (what Telegram/iOS do): the bevel carries the colour found just OUTSIDE the edge
    // along the contour, so a colour touching part of the rim flows around the rest of it.
    float2 pc = pl.xy + pl.zw * 0.5, phs = pl.zw * 0.5;
    float P = rrPerim(phs, pr);
    float L = min(P * 0.5, radius * 10.0);          // how far along the rim a colour travels
    float s0 = rrArc(pc, phs, pr, p);
    float3 pipe = 0; float wp = 0;
    [loop] for (int k = -16; k <= 16; k++)
    {
        float u = k / 16.0;
        float2 cp, cn; rrAt(pc, phs, pr, s0 + u * L, cp, cn);
        float w = exp(-u * u * 3.0);
        pipe += tap(cp + cn * 4.0) * w;             // sample a few px outside the rim
        wp += w;
    }
    pipe /= wp;
    float band = pow(saturate(1.0 - x / 0.45), 1.5); // rim band ~45% of the bevel, strongest at the edge
    acc = lerp(acc, pipe, band * 0.35);

    float3 glass = lerp(acc, float3(0.16, 0.16, 0.18), 0.12) * 0.95;  // lighter grey tint so the background reads through

    // thin anti-aliased rim (~1px), light from top-left, faint bounce bottom-right
    float aa = max(fwidth(d), 0.5);
    float rd = (d + 0.75) / (0.55 + aa * 0.5);
    float rim = exp(-rd * rd);
    float lt = dot(n, normalize(float2(-0.6, -0.8)));
    float light = smoothstep(0.0, 1.0, lt) * 0.18 + smoothstep(0.0, 1.0, -lt) * 0.10 + 0.03;
    glass += rim * light;

    float a = 1 - smoothstep(-0.75, 0.75, d);
    return float4(lerp(bg, glass, a), 1);
}
