#include "KernelParams.hlsli"

StructuredBuffer<FlexInflatable> inflatables : register(t0);
StructuredBuffer<float4> positions : register(t1);
StructuredBuffer<int> reverseLookup : register(t2);
StructuredBuffer<int> indices : register(t3);
RWStructuredBuffer<float> lambdas: register(u0);

#define BLOCK_DIM_X      512
#define BLOCK_DIM_X_BITS 9u

#if USE_NV_SHADER_EXT

#include <nvHLSLExtns.h>
#define WAVE_SIZE      32
#define WAVE_SIZE_BITS 5

#elif USE_AMD_SHADER_EXT

#include <ags_shader_intrinsics_dx11.hlsl>
#define WAVE_SIZE      32
#define WAVE_SIZE_BITS 5

static const int g_AmdDxExtSwizzleOperations[] = {
    AmdDxExtShaderIntrinsicsSwizzle_SwapX1,
    AmdDxExtShaderIntrinsicsSwizzle_SwapX2,
    AmdDxExtShaderIntrinsicsSwizzle_SwapX4,
    AmdDxExtShaderIntrinsicsSwizzle_SwapX8,
    AmdDxExtShaderIntrinsicsSwizzle_SwapX16,
};

#endif

groupshared FlexInflatable inflatableInBlock;
groupshared float volumeOfInflatable;
groupshared float3 centerOfInflatable;

#if USE_NV_SHADER_EXT || USE_AMD_SHADER_EXT
groupshared float volumesInBlock[BLOCK_DIM_X / WAVE_SIZE];
groupshared float3 centersInBlock[BLOCK_DIM_X / WAVE_SIZE];
#else
groupshared float volumesInBlock[BLOCK_DIM_X];
groupshared float3 centersInBlock[BLOCK_DIM_X];
#endif

// Sums `center` across the whole thread group. The vendor paths reduce within a
// wave using shuffle/swizzle intrinsics and then combine the per-wave partials;
// the generic path walks a shared-memory tree over the live lanes.
float3 ReduceCenter(int threadIdx, int numTrisInBlock, float3 center) {
#if USE_NV_SHADER_EXT || USE_AMD_SHADER_EXT
    const int laneIdx = threadIdx & (WAVE_SIZE - 1);
    const int waveIdx = threadIdx >> int(WAVE_SIZE_BITS);
    float3 v1;
    int i;

#if USE_NV_SHADER_EXT
    [unroll]
    for (i = 1; i < WAVE_SIZE; i <<= 1) {
        v1.x = asfloat(NvShflDown(asint(center.x), i));
        v1.y = asfloat(NvShflDown(asint(center.y), i));
        v1.z = asfloat(NvShflDown(asint(center.z), i));
        center = center + v1;
    }
#else
    [unroll]
    for (i = WAVE_SIZE_BITS - 1; i >= 0; --i) {
        v1.x = AmdDxExtShaderIntrinsics_SwizzleF(center.x, g_AmdDxExtSwizzleOperations[i]);
        v1.y = AmdDxExtShaderIntrinsics_SwizzleF(center.y, g_AmdDxExtSwizzleOperations[i]);
        v1.z = AmdDxExtShaderIntrinsics_SwizzleF(center.z, g_AmdDxExtSwizzleOperations[i]);
        center = center + v1;
    }
#endif

    if (laneIdx == 0)
        centersInBlock[waveIdx] = center;
    GroupMemoryBarrierWithGroupSync();

    if (threadIdx == 0) {
        float3 total = centersInBlock[0];
        [unroll]
        for (i = 1; i < (BLOCK_DIM_X / WAVE_SIZE); ++i)
            total = total + centersInBlock[i];
        centersInBlock[0] = total;
    }
    GroupMemoryBarrierWithGroupSync();
    return centersInBlock[0];
#else
    centersInBlock[threadIdx] = center;

    for (uint j = uint(numTrisInBlock) >> 1; j > 0; j >>= 1) {
        GroupMemoryBarrierWithGroupSync();
        if (uint(threadIdx) < j) {
            float3 v1 = centersInBlock[threadIdx];
            float3 v2 = centersInBlock[threadIdx + j];
            centersInBlock[threadIdx] = v1 + v2;
        }
    }

    GroupMemoryBarrierWithGroupSync();
    return centersInBlock[0];
#endif
}

// Same reduction for the scalar volume term.
float ReduceVolume(int threadIdx, int numTrisInBlock, float vol) {
#if USE_NV_SHADER_EXT || USE_AMD_SHADER_EXT
    const int laneIdx = threadIdx & (WAVE_SIZE - 1);
    const int waveIdx = threadIdx >> int(WAVE_SIZE_BITS);
    float s1;
    int i;

#if USE_NV_SHADER_EXT
    [unroll]
    for (i = 1; i < WAVE_SIZE; i <<= 1) {
        s1 = asfloat(NvShflDown(asint(vol), i));
        vol = vol + s1;
    }
#else
    [unroll]
    for (i = WAVE_SIZE_BITS - 1; i >= 0; --i) {
        s1 = AmdDxExtShaderIntrinsics_SwizzleF(vol, g_AmdDxExtSwizzleOperations[i]);
        vol = vol + s1;
    }
#endif

    if (laneIdx == 0)
        volumesInBlock[waveIdx] = vol;
    GroupMemoryBarrierWithGroupSync();

    if (threadIdx == 0) {
        float total = volumesInBlock[0];
        [unroll]
        for (i = 1; i < (BLOCK_DIM_X / WAVE_SIZE); ++i)
            total = total + volumesInBlock[i];
        volumesInBlock[0] = total;
    }
    GroupMemoryBarrierWithGroupSync();
    return volumesInBlock[0];
#else
    volumesInBlock[threadIdx] = vol;

    for (uint j = uint(numTrisInBlock) >> 1; j > 0; j >>= 1) {
        GroupMemoryBarrierWithGroupSync();
        if (uint(threadIdx) < j) {
            float s1 = volumesInBlock[threadIdx];
            float s2 = volumesInBlock[threadIdx + j];
            volumesInBlock[threadIdx] = s1 + s2;
        }
    }
    GroupMemoryBarrierWithGroupSync();
    return volumesInBlock[0];
#endif
}

[numthreads(BLOCK_DIM_X, 1, 1)]
void CalculateInflatableVolume(int threadIdx: SV_GroupThreadID, int blockIdx: SV_GroupID) {

    if (threadIdx == 0) {
        inflatableInBlock = inflatables[blockIdx];
        volumeOfInflatable = 0.0;
        centerOfInflatable = 0.0.xxx;
    }
    GroupMemoryBarrierWithGroupSync();

    const int numBlocks = uint(inflatableInBlock.mNumTris + BLOCK_DIM_X - 1) >> BLOCK_DIM_X_BITS;
    const float invNumIndices = 1.0 / (3.0 * inflatableInBlock.mNumTris);

    for (int bkIdx = 0; bkIdx < numBlocks; ++bkIdx) {
        int triIdx = (bkIdx * BLOCK_DIM_X) + threadIdx;
        int idxBase = inflatableInBlock.mStartTri;
        int numTrisInBlock = min(inflatableInBlock.mNumTris - bkIdx * BLOCK_DIM_X, BLOCK_DIM_X);

        float3 center;

        if (triIdx < inflatableInBlock.mNumTris) {
            int triIdxAbs = triIdx + idxBase;
            int idx1 = indices[triIdxAbs * 3];
            int posIdx1 = reverseLookup[idx1];

            int idx2 = indices[triIdxAbs * 3 + 1];
            int posIdx2 = reverseLookup[idx2];

            int idx3 = indices[triIdxAbs * 3 + 2];
            int posIdx3 = reverseLookup[idx3];

            float3 pos1 = positions[posIdx1].xyz;
            float3 pos2 = positions[posIdx2].xyz;
            float3 pos3 = positions[posIdx3].xyz;

            center = (pos1 + pos2 + pos3) * invNumIndices;
        } else
            center = 0.0.xxx;

        center = ReduceCenter(threadIdx, numTrisInBlock, center);

        if (threadIdx == 0)
            centerOfInflatable += center;
        GroupMemoryBarrierWithGroupSync();
    }

    GroupMemoryBarrierWithGroupSync();

    for (int bkIdxj = 0; bkIdxj < numBlocks; ++bkIdxj) {
        int triIdx = bkIdxj * BLOCK_DIM_X + threadIdx;
        int idxBase = inflatableInBlock.mStartTri;
        int numTrisInBlock = min(inflatableInBlock.mNumTris - bkIdxj * BLOCK_DIM_X, BLOCK_DIM_X);

        float vol;

        if (triIdx < inflatableInBlock.mNumTris) {
            int triIdxAbs = triIdx + idxBase;
            int idx1 = indices[triIdxAbs * 3];
            int posIdx1 = reverseLookup[idx1];

            int idx2 = indices[triIdxAbs * 3 + 1];
            int posIdx2 = reverseLookup[idx2];

            int idx3 = indices[triIdxAbs * 3 + 2];
            int posIdx3 = reverseLookup[idx3];

            float3 pos1 = positions[posIdx1].xyz - centerOfInflatable;
            float3 pos2 = positions[posIdx2].xyz - centerOfInflatable;
            float3 pos3 = positions[posIdx3].xyz - centerOfInflatable;

            pos2 -= pos1;
            pos3 -= pos1;

            vol = dot(cross(pos2, pos3), pos1);

        } else
            vol = 0.0;

        vol = ReduceVolume(threadIdx, numTrisInBlock, vol);

        if (threadIdx == 0)
            volumeOfInflatable += vol;
        GroupMemoryBarrierWithGroupSync();
    }

    if (threadIdx == 0) {
        float k = abs(inflatableInBlock.mRestVolume) / (max(abs(inflatableInBlock.mRestVolume * 0.01), abs(volumeOfInflatable)));

        lambdas[blockIdx] = (k * k * k) * (volumeOfInflatable - inflatableInBlock.mRestVolume) * inflatableInBlock.mConstraintScale;
    }
}
