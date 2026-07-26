#include "KernelParams.hlsli"

StructuredBuffer<FlexInflatable> inflatables : register(t0);
StructuredBuffer<float4> positions : register(t1);
StructuredBuffer<int> reverseLookup : register(t2);
StructuredBuffer<int> indices : register(t3);
RWStructuredBuffer<float> lambdas: register(u0);

#define BLOCK_DIM_X      512
#define BLOCK_DIM_X_BITS 9u

groupshared FlexInflatable inflatableInBlock;
groupshared float volumeOfInflatable;
groupshared float3 centerOfInflatable;
groupshared float volumesInBlock[BLOCK_DIM_X];
groupshared float3 centersInBlock[BLOCK_DIM_X];

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
            int idx1 = indices[3 * triIdxAbs];
            int posIdx1 = reverseLookup[idx1];

            int idx2 = indices[3 * triIdxAbs + 1];
            int posIdx2 = reverseLookup[idx2];

            int idx3 = indices[3 * triIdxAbs + 2];
            int posIdx3 = reverseLookup[idx3];

            float3 pos1 = positions[posIdx1].xyz;
            float3 pos2 = positions[posIdx2].xyz;
            float3 pos3 = positions[posIdx3].xyz;

            center = (pos1 + pos2 + pos3) * invNumIndices;
        } else
            center = 0.0.xxx;

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
        center = centersInBlock[0];

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
            int idx1 = indices[3 * triIdxAbs];
            int posIdx1 = reverseLookup[idx1];

            int idx2 = indices[3 * triIdxAbs + 1];
            int posIdx2 = reverseLookup[idx2];

            int idx3 = indices[3 * triIdxAbs + 2];
            int posIdx3 = reverseLookup[idx3];

            float3 pos1 = positions[posIdx1].xyz - centerOfInflatable;
            float3 pos2 = positions[posIdx2].xyz - centerOfInflatable;
            float3 pos3 = positions[posIdx3].xyz - centerOfInflatable;

            pos2 -= pos1;
            pos3 -= pos1;

            vol = dot(cross(pos2, pos3), pos1);

        } else
            vol = 0.0;

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
        vol = volumesInBlock[0];

        if (threadIdx == 0)
            volumeOfInflatable += vol;
        GroupMemoryBarrierWithGroupSync();
    }

    if (threadIdx == 0) {
        float k = abs(inflatableInBlock.mRestVolume) / (max(abs(inflatableInBlock.mRestVolume * 0.01), abs(volumeOfInflatable)));

        lambdas[blockIdx] = (k * k * k) * (volumeOfInflatable - inflatableInBlock.mRestVolume) * inflatableInBlock.mConstraintScale;
    }
}
