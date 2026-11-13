// Points / lines coloured by height, intensity or a flat colour.
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float4 color;      // flat colour (mode 1)
    float2 zRange;     // height colour range
    float pointSize;
    float iMax;        // intensity mapped to the top of the colour scale
    int mode;          // 0 height, 1 flat, 2 intensity (falls back to height when intensity < 0)
};

struct VOut {
    float4 pos [[position]];
    float size [[point_size]];
    float3 color;
};

struct LOut {
    float4 pos [[position]];
    float3 color;
};

// height colours: magenta -> white -> cyan -> green
static float3 hue(float t) {
    t = clamp(t, 0.0, 1.0);
    return clamp(float3(abs(t * 4.0 - 3.0) - 1.0, 2.0 - abs(t * 4.0 - 2.0), 2.0 - abs(t * 4.0 - 1.0)), 0.0, 1.0);
}

// blue -> cyan -> green -> yellow -> red
static float3 jet(float t) {
    t = clamp(t, 0.0, 1.0);
    return clamp(float3(1.5 - abs(4.0 * t - 3.0), 1.5 - abs(4.0 * t - 2.0), 1.5 - abs(4.0 * t - 1.0)), 0.0, 1.0);
}

static float3 colorOf(float4 p, constant Uniforms& u) {
    if (u.mode == 1) return u.color.rgb;
    // sqrt spreads the low reflectivities, where most surfaces are
    if (u.mode == 2 && p.w >= 0.0) return jet(sqrt(clamp(p.w / u.iMax, 0.0, 1.0)));
    return hue((p.z - u.zRange.x) / (u.zRange.y - u.zRange.x));
}

vertex VOut pointsVertex(uint vid [[vertex_id]], const device float4* pts [[buffer(0)]],
                         constant Uniforms& u [[buffer(1)]]) {
    float4 p = pts[vid];
    VOut o;
    o.pos = u.mvp * float4(p.xyz, 1.0);
    o.size = u.pointSize;
    o.color = colorOf(p, u);
    return o;
}

vertex LOut linesVertex(uint vid [[vertex_id]], const device float4* pts [[buffer(0)]],
                        constant Uniforms& u [[buffer(1)]]) {
    float4 p = pts[vid];
    LOut o;
    o.pos = u.mvp * float4(p.xyz, 1.0);
    o.color = colorOf(p, u);
    return o;
}

fragment float4 pointsFragment(VOut in [[stage_in]]) { return float4(in.color, 1.0); }
fragment float4 linesFragment(LOut in [[stage_in]]) { return float4(in.color, 1.0); }
