// metal-lint self-test: this file contains exactly five deliberate errors.
// Each offending line carries an EXPECT-ERROR marker; selftest/run.sh checks
// that the linter reports an error on every one of those lines.
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

fragment float4 badFragment(VertexOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler s [[sampler(0)]]) {
    float4 v = float4(1.0, 2.0, 3.0, 4.0);
    float3 p = v.xyzq;                               // EXPECT-ERROR: 'q' is not a vector component
    float scale = undeclaredScale * 2.0;             // EXPECT-ERROR: undeclared identifier
    float a = 1.0f                                   // EXPECT-ERROR: missing semicolon
    float b = 2.0f;
    float4 c = tex.sample(s, float3(in.uv, 0.0));    // EXPECT-ERROR: texture2d::sample takes a float2
    float3 q = v;                                    // EXPECT-ERROR: float4 cannot initialise a float3
    return c + float4(p + q, a + b + scale);
}
