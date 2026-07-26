cbuffer params : register(b0) {
    int lengthInWords;
    float4 value;
};

RWStructuredBuffer<float4> g_buffer : register(u0);

[numthreads(256, 1, 1)]
void ClearFloat4(int globalIdx: SV_DispatchThreadID) {
    const int numItems = lengthInWords << 4;
    if (globalIdx < numItems)
        g_buffer[globalIdx] = value;
}