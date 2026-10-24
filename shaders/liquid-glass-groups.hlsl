// liquid-glass-groups.hlsl - same look as liquid-glass.hlsl, N-shape variant: shapes of one group are joined with a
// polynomial smooth-min so they morph like droplets. Output is premultiplied alpha (transparent outside), shapes come
// from structured buffers (t1 rects, t2 radii: x = corner radius, y = half-height, z = group id, w = blend k px).

cbuffer C : register(b0)
{
    float2 winSize; float2 texSize;                 // window size; capture texture size, both in px
    float2 texOrigin;                               // window px of texture texel (0,0): -margin when the capture extends past the window
    uint shapeCount;                                // shapes used in rects/radii (<= 32)
    uint pad;
};
StructuredBuffer<float4> rects : register(t1);     // x, y, w, h per glass shape, window px
StructuredBuffer<float4> radii : register(t2);     // x = corner radius, y = half-height (lens scale), z = group id, w = blend k px (0 = hard union)
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

float sdBox(float2 p, float4 r, float rad)
{
    float2 c = r.xy + r.zw * 0.5;
    float2 q = abs(p - c) - r.zw * 0.5 + rad;
    return length(max(q, 0)) + min(max(q.x, q.y), 0) - rad;
}

// Polynomial smooth-min: shapes of one group melt together through a liquid neck of width ~k px.
float smin(float a, float b, float k)
{
    if (k <= 0) return min(a, b);
    float h = max(k - abs(a - b), 0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Smooth union inside a group (radii.z = group id, radii.w = blend k), plain min across groups.
float scene(float2 p)
{
    float d = 1e9;
    [loop] for (uint k = 0; k < shapeCount; k++)
    {
        float g = round(radii[k].z);
        bool first = true;
        [loop] for (uint j = 0; j < k; j++) if (round(radii[j].z) == g) first = false;
        if (!first) continue;                       // the group was already folded in by its first shape
        float gd = sdBox(p, rects[k], radii[k].x), gk = radii[k].w;
        [loop] for (uint m = k + 1; m < shapeCount; m++)
        {
            if (round(radii[m].z) != g) continue;
            gk = max(gk, radii[m].w);
            gd = smin(gd, sdBox(p, rects[m], radii[m].x), gk);
        }
        d = min(d, gd);
    }
    return d;
}

uint nearest(float2 p)
{
    uint best = 0; float bd = 1e9;
    [loop] for (uint k = 0; k < shapeCount; k++) { float dk = sdBox(p, rects[k], radii[k].x); if (dk < bd) { bd = dk; best = k; } }
    return best;
}
float3 tap(float2 px) // px in window pixels
{
    return T.SampleLevel(S, (px - texOrigin) / texSize, 0).rgb;
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
    if (d > 1.0) return float4(0, 0, 0, 0);       // outside every shape: fully transparent

    uint si = nearest(p);
    float4 pl = rects[si];
    float pr = radii[si].x, radius = radii[si].y;
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
    return float4(glass * a, a);                   // premultiplied alpha
}
