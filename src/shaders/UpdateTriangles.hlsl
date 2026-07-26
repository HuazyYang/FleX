#include "KernelParams.hlsli"
#include "Utils.hlsli"

StructuredBuffer<float4> sortedNewPositions : register(t0);
StructuredBuffer<float4> sortedVelocities : register(t1);
StructuredBuffer<int> reverseLookup : register(t2);
StructuredBuffer<int> indices : register(t3);
RWByteAddressBuffer accum : register(u0);
RWStructuredBuffer<float3> triNormals : register(u1);

#if USE_NV_SHADER_EXT
#include <nvHLSLExtns.h>
#define InterlockedAddFp32 NvInterlockedAddFp32
#endif

#define BLOCK_DIM_X 256

[numthreads(BLOCK_DIM_X, 1, 1)]
void UpdateTriangles(int globalIdx: SV_DispatchThreadID) {
    if (globalIdx < gParams.kNumTriangles) {
        int idx1 = reverseLookup[indices[globalIdx * 3]];
        int idx2 = reverseLookup[indices[globalIdx * 3 + 1]];
        int idx3 = reverseLookup[indices[globalIdx * 3 + 2]];

        float4 pos1 = sortedNewPositions[idx1];
        float4 pos2 = sortedNewPositions[idx2];
        float4 pos3 = sortedNewPositions[idx3];

        float3 pos21 = pos2.xyz - pos1.xyz;
        float3 pos31 = pos3.xyz - pos1.xyz;
        float3 n = float3(pos31.yzx * pos21.zxy - pos21.yzx * pos3.zxy);
        float A = dot(n, n);
        n = A > 0.0 ? n * rsqrt(A) : 0.0.xxx;
        triNormals[globalIdx] = n;

        if (gParams.kDrag != 0 || gParams.kLift != 0) {
            float3 v1 = sortedVelocities[idx1].xyz;
            float3 v2 = sortedVelocities[idx2].xyz;
            float3 v3 = sortedVelocities[idx3].xyz;

            float3 wind = gParams.kWind - (v1 + v2 + v3) / 3.0;
            float windMag = dot(wind, wind);
            float3 windDir = windMag > 0 ? wind * rsqrt(windMag) : 0.0.xxx;
            float4 n4 = float4(n, dot(n, windDir));
            n4 = n4.w < 0 ? -n4 : n4;
            float2 forceMag = float2(gParams.kDrag, gParams.kLift) * gParams.kDt * n4.w;
            windMag = sqrt(windMag);
            float cosTheta = n4.w;
            float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 0.0));
            forceMag.y *= sinTheta;
            forceMag.y = clamp(forceMag.y, -1.0, 1.0);
            float liftMag = windMag * forceMag.y;

            float3 windT = wind.yzx * n4.zxy - wind.zxy * n4.yzx;
            float3 windN = windT.yzx * wind.zxy - windT.zxy * wind.yzx;
            float windNMag = dot(windN, windN);
            float3 liftDir = windNMag > 0.0 ? windN * rsqrt(windN) : 0.0.xxx;

            float3 windForce = forceMag.x * wind + liftMag * liftDir;

            float3 windAccel;

            windAccel = windForce * pos1.w;

            InterlockedAddFp32(accum, idx1 * 16, windAccel.x);
            InterlockedAddFp32(accum, idx1 * 16 + 4, windAccel.y);
            InterlockedAddFp32(accum, idx1 * 16 + 8, windAccel.z);
            InterlockedAddFp32(accum, idx1 * 16 + 12, 1.0);

            windAccel = windForce * pos2.w;
            InterlockedAddFp32(accum, idx2 * 16, windAccel.x);
            InterlockedAddFp32(accum, idx2 * 16 + 4, windAccel.y);
            InterlockedAddFp32(accum, idx2 * 16 + 8, windAccel.z);
            InterlockedAddFp32(accum, idx2 * 16 + 12, 1.0);

            windAccel = windForce * pos3.w;
            InterlockedAddFp32(accum, idx3 * 16, windAccel.x);
            InterlockedAddFp32(accum, idx3 * 16 + 4, windAccel.y);
            InterlockedAddFp32(accum, idx3 * 16 + 8, windAccel.z);
            InterlockedAddFp32(accum, idx3 * 16 + 12, 1.0);
        }
    }
}
