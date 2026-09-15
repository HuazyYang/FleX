cbuffer consts : register(b0) {
    int gNumBounds;
}

struct FlexConvexMeshDevice {
    float4 mLower;
    float4 mUpper;
    int mPlaneOffset;
    int mPlaneCount;
    int2 mPad;
};

struct FlexTriangleMeshDevice {
    float4 mLower;
    float4 mUpper;
    int mIndexStart;
    int mVertexStart;
    int mNodeStart;
    int mPad;
};

static const uint eNvFlexShapeSphere = 0;
static const uint eNvFlexShapeCapsule = 1;
static const uint eNvFlexShapeBox = 2;
static const uint eNvFlexShapeConvexMesh = 3;
static const uint eNvFlexShapeTriangleMesh = 4;
static const uint eNvFlexShapeSDF = 5;

StructuredBuffer<float4> positions : register(t0);
StructuredBuffer<float4> rotations : register(t1);
StructuredBuffer<float4> positionsPrev : register(t2);
StructuredBuffer<float4> rotationsPrev : register(t3);
StructuredBuffer<uint> flags : register(t4);
StructuredBuffer<float4> geometry : register(t5);
StructuredBuffer<FlexConvexMeshDevice> convexMeshes : register(t6);
StructuredBuffer<FlexTriangleMeshDevice> triangleMeshes : register(t7);
RWStructuredBuffer<float4> lowers : register(u0);
RWStructuredBuffer<float4> uppers : register(u1);

float3 RotateVector(float4 q, float3 v) {
    return v * (2.0 * q.w * q.w - 1.0) + cross(q.xyz, v) * q.w * 2.0 + q.xyz * dot(q.xyz, v) * 2.0;
}

// Same rotation with cross(q.xyz, v) and dot(q.xyz, v) supplied pre-folded. The
// DXBC collapses each basis-axis cross into one masked mul, which is only
// reproducible when the folded form is written out.
float3 RotateBasis(float4 q, float3 v, float3 crossQV, float dotQV) {
    return v * (2.0 * q.w * q.w - 1.0) + crossQV * q.w * 2.0 + q.xyz * dotQV * 2.0;
}

void LocalShapeBounds(uint shapeType, float4 geom, out float3 lower, out float3 upper) {
    switch (shapeType) {
    case eNvFlexShapeSphere:
        lower = -geom.xxx;
        upper = geom.xxx;
        break;
    case eNvFlexShapeCapsule:
        lower = -geom.xxx - float3(geom.y, 0.0, 0.0);
        upper = geom.xxx + float3(geom.y, 0.0, 0.0);
        break;
    case eNvFlexShapeBox:
        lower = -geom.xyz;
        upper = geom.xyz;
        break;
    case eNvFlexShapeConvexMesh: {
        int meshIndex = asint(geom.w) - 1;
        lower = geom.xyz * convexMeshes[meshIndex].mLower.xyz;
        upper = geom.xyz * convexMeshes[meshIndex].mUpper.xyz;
        break;
    }
    case eNvFlexShapeTriangleMesh: {
        int meshIndex = asint(geom.w) - 1;
        lower = geom.xyz * triangleMeshes[meshIndex].mLower.xyz;
        upper = geom.xyz * triangleMeshes[meshIndex].mUpper.xyz;
        break;
    }
    case eNvFlexShapeSDF:
        lower = 0.0;
        upper = geom.xxx;
        break;
    default:
        break;
    }
}

void TransformBounds(float3 position, float4 rotation, float3 lower, float3 upper, out float3 outLower, out float3 outUpper) {
    float3 axisX = RotateBasis(rotation, float3(1.0, 0.0, 0.0),
                               float3(0.0, rotation.z, -rotation.y), rotation.x);
    float3 axisY = RotateBasis(rotation, float3(0.0, 1.0, 0.0),
                               float3(-rotation.z, 0.0, rotation.x), rotation.y);
    float3 axisZ = RotateBasis(rotation, float3(0.0, 0.0, 1.0),
                               float3(rotation.y, -rotation.x, 0.0), rotation.z);

    float3 edges = upper - lower;
    float3 worldExtents = abs(axisX * edges.x) + abs(axisY * edges.y);
    worldExtents = abs(axisZ * edges.z) + worldExtents.xyz;

    float3 center = (lower + upper) * 0.5;
    float3 worldCenter = RotateVector(rotation, center) + position;

    outLower = worldCenter - worldExtents * 0.5;
    outUpper = worldCenter + worldExtents * 0.5;
}

[numthreads(256, 1, 1)]
void TransformShapeBounds(uint idx : SV_DispatchThreadID) {
    if (int(idx) < gNumBounds) {
    uint shapeType = flags[idx] & 7;
    float3 localLower;
    float3 localUpper;
    LocalShapeBounds(shapeType, geometry[idx], localLower, localUpper);

    float3 lowerNow;
    float3 upperNow;
    float3 lowerPrev;
    float3 upperPrev;
    TransformBounds(positions[idx].xyz, rotations[idx], localLower, localUpper, lowerNow, upperNow);
    TransformBounds(positionsPrev[idx].xyz, rotationsPrev[idx], localLower, localUpper, lowerPrev, upperPrev);

    lowers[idx] = float4(min(lowerNow, lowerPrev), 0.0);
    uppers[idx] = float4(max(upperPrev, upperNow), 0.0);
    }
}
