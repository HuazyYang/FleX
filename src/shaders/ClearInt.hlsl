
cbuffer params : register(b0) {
    int lengthInWords;
    int value;
    int _pad1;
    int _pad2;
};

RWStructuredBuffer<int> g_buffer: register(u0);

[numthreads(256, 1, 1)]
void ClearInt(int globalIdx: SV_DispatchThreadID) {
    const int numItems = lengthInWords << 2;
    if (globalIdx < numItems)
        g_buffer[globalIdx] = value;
}

