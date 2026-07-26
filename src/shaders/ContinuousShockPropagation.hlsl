#include "KernelParams.hlsli"

StructuredBuffer<float3> bounds : register(t0);
RWStructuredBuffer<float4> positions : register(u0);

groupshared float3 g0;
groupshared float3 g1;

[numthreads(256, 1, 1)]
void ContinuousShockPropagation(int idx: SV_GroupThreadID, int globalIdx: SV_DispatchThreadID) {
    if (idx == 0) {
        float3 b0 = bounds[0];
        float3 b1 = bounds[1];
        float d0 = dot(b0, gParams.kGravity);
        float d1 = dot(b1, gParams.kGravity);

        g0 = d0 < d1 ? b1 : b0;

        float gLen2 = dot(gParams.kGravity, gParams.kGravity);
        g1 = gLen2 > 0.0 ? gParams.kGravity * rsqrt(gLen2) : 0.0.xxx;
    }
    GroupMemoryBarrierWithGroupSync();

    if (globalIdx < gParams.kNumParticles) {
        float4 pos = positions[globalIdx];
        float3 delta = g0 - pos.xyz;
        float invM = dot(delta, g1) * gParams.kShockPropagation;
        invM = exp(invM);
        positions[globalIdx].w *= invM;
    }
}
