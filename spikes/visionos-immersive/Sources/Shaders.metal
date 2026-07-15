#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float3 col; };

// Fixed NDC triangle, same in both eyes (Spike A just proves the pipeline; per-eye
// view/projection matrices come with the engine integration).
vertex VOut spike_vertex(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(0.0, 0.6), float2(-0.6, -0.6), float2(0.6, -0.6) };
    const float3 c[3] = { float3(1,0,0), float3(0,1,0), float3(0,0,1) };
    VOut o;
    o.pos = float4(p[vid], 0.0, 1.0);
    o.col = c[vid];
    return o;
}

fragment float4 spike_fragment(VOut in [[stage_in]]) {
    return float4(in.col, 1.0);
}
