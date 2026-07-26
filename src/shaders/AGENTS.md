# NvFlex Shader Sources

## Introduction

This folder contains HLSL shader sources consumed by `NvFlexReversed` project.

The shader sources are recovered from `../dxbc` disassemblies. A Flex shader
group named `g_Flex_<Name>` usually maps to `<Name>.hlsl` or
`<Name>.hlsl_rev`; BVH shader groups named `g_bvh_<Name>` map under `bvh/`.
The `*.asm` files in `../dxbc` are disassembled DXBC 5.0 sources and are the
authority for reverse-recovery work.

## Development Guidelines

- HLSL assembly reference: [Shader Model 5 Assembly](https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/shader-model-5-assembly--directx-hlsl-).

- Read the matching `../dxbc/*.asm` before changing a shader. Use the preamble
  resource table, `dcl_*` declarations, thread-group size, and instruction body
  together; do not rely on `../dxbc/*.hlsl` except as a rough decompiler hint.

- Map `cb0[...]` fields through `KernelParams.hlsli`. Preserve resource binding
  slots, element strides, raw vs typed/structured buffer kinds, UAV write
  masks, atomics, and `numthreads` values.

- Vector swizzles in assembly are component-wise assignments. For example:
  ```
  mul r12.yxz, r10.yzyy, r17.zxzz
  ```
  means:
  ```
  r12.y = r10.y * r17.z
  r12.x = r10.z * r17.x
  r12.z = r10.y * r17.z
  ```

- To compile shader object headers, keep the source listed in `Shaders.cfg` and
  run:
  ```
  cmake --build build --config Debug --target NvFlexShaders
  ```
  `Shaders.cfg` entries use `-T cs -E <EntryPoint>` and are retargeted by CMake
  to `cs_5_0`. Example:
  ```
  CalculateBounds.hlsl                                -T cs -E CalculateBounds
  ```

- To compare generated DXBC against the original source of truth, diff the
  disassembly block enclosed in the generated `{entry}.hlsl.h` file against the
  matching `../dxbc/g_*.asm`. The generated header layout is:
  ```
  #if 0
   // enclosed disassembly DXBC section
  #endif
   // byte constant definition follows
  ```

- Local DXC checks are useful syntax guards for `.hlsl_rev` files, but FXC/DXBC
  output remains authoritative for bytecode matching.

## Conventions

- Keep hand-recovered shader source close to the DXBC body. Prefer clear,
  direct HLSL that preserves control-flow gates, arithmetic order, and output
  semantics over high-level rewrites.

- Use `.hlsl_rev` for hand-recovered files that intentionally remain separate
  from earlier recovered `.hlsl` sources. Every `.hlsl_rev` file currently in
  this folder is listed in `Shaders.cfg`.

- Entry-point names must match the shader group name without the `g_Flex_` or
  `g_bvh_` prefix. Wrapper variants such as `SolveShapes32NV.hlsl_rev` may
  include the composed NV body source and only change `numthreads`/entry point
  when that matches the corresponding DXBC.

- Vendor variants with `NV` or `AMD` suffixes may share a composed source file
  only when the composed source covers the matching DXBC resources and extension
  slots. Keep required `-D...` flags in `Shaders.cfg`.

- Do not add `-Vn` to new `Shaders.cfg` entries unless the C++ side explicitly
  needs a non-entry symbol name. Existing legacy `-Vn` lines should be left
  alone unless their C++ lookup convention is changed deliberately.

- Remove decompiler artifacts before marking a shader complete. No source in
  this directory should contain `Needs manual fix`, `unknown dcl_`, `Known bad
  code`, `3Dmigoto`, or namespace-style decompiler identifiers.

- Keep comments sparse and technical. Do not leave uncertainty notes such as
  `TODO` in recovered shaders unless the work item is still intentionally open
  and reflected in the status table.

- When updating `Shaders.cfg`, verify that every `.hlsl_rev` file is listed
  exactly once, the entry point matches the file stem, and the line does not
  introduce duplicate output names unintentionally.

## Current Work Status

Status is tracked per unique DXBC shader group. The authoritative recovery
source is the corresponding `.asm` disassembly in `../dxbc`; DXBC-side `.hlsl`
artifacts are only rough decompiler hints. A group is marked `Complete` when
the recovered source has been checked against the DXBC resources, cbuffer
fields, thread group, and instruction semantics, and the source is listed in
`Shaders.cfg` when it is meant to produce a shader object. Vendor variants with
`NV` or `AMD` suffixes are marked `Complete` when the composed source covers
their matching DXBC resources and extension behavior.

Summary: 84 DXBC shader groups, 84 complete, 0 pending. The shader source tree
currently has 36 recovered `.hlsl` files, 30 `.hlsl_rev` files, plus shared
include/config files. All 30 `.hlsl_rev` files are listed in `Shaders.cfg` for
shader-object generation. The latest recovery pass found no decompiler
placeholders in `src/shaders`, and all `.hlsl_rev` entries passed local DXC
syntax checks as a guardrail; final bytecode equivalence should still be judged
with FXC-generated DXBC disassembly diffs.

| Family | DXBC shader group | `src/shaders` source | Status |
| --- | --- | --- | --- |
| Flex | `g_Flex_ApplyDeltas` | `ApplyDeltas.hlsl_rev` | Complete |
| Flex | `g_Flex_CalculateAnisotropy` | `CalculateAnisotropy.hlsl_rev` | Complete |
| Flex | `g_Flex_CalculateBounds` | `CalculateBounds.hlsl` | Complete |
| Flex | `g_Flex_CalculateBoundsAMD` | `CalculateBounds.hlsl` | Complete |
| Flex | `g_Flex_CalculateBoundsFinalize` | `CalculateBoundsFinalize.hlsl` | Complete |
| Flex | `g_Flex_CalculateBoundsFinalizeAMD` | `CalculateBoundsFinalize.hlsl` | Complete |
| Flex | `g_Flex_CalculateBoundsFinalizeNV` | `CalculateBoundsFinalize.hlsl` | Complete |
| Flex | `g_Flex_CalculateBoundsGroup` | `CalculateBoundsGroup.hlsl` | Complete |
| Flex | `g_Flex_CalculateBoundsGroupAMD` | `CalculateBoundsGroup.hlsl` | Complete |
| Flex | `g_Flex_CalculateBoundsGroupNV` | `CalculateBoundsGroup.hlsl` | Complete |
| Flex | `g_Flex_CalculateBoundsNV` | `CalculateBounds.hlsl` | Complete |
| Flex | `g_Flex_CalculateDensity` | `CalculateDensity.hlsl_rev` | Complete |
| Flex | `g_Flex_CalculateDensitySurfaceTension` | `CalculateDensitySurfaceTension.hlsl_rev` | Complete |
| Flex | `g_Flex_CalculateInflatableVolume` | `CalculateInflatableVolume.hlsl` | Complete |
| Flex | `g_Flex_CalculateInflatableVolumeAMD` | `CalculateInflatableVolume.hlsl` | Complete |
| Flex | `g_Flex_CalculateInflatableVolumeNV` | `CalculateInflatableVolume.hlsl` | Complete |
| Flex | `g_Flex_CalculateParticleHash` | `CalculateParticleHash.hlsl` | Complete |
| Flex | `g_Flex_CalculateVorticity` | `CalculateVorticity.hlsl` | Complete |
| Flex | `g_Flex_ClampDiffuseParticleCount` | `ClampDiffuseParticleCount.hlsl_rev` | Complete |
| Flex | `g_Flex_ClearCellBuckets` | `ClearCellBuckets.hlsl` | Complete |
| Flex | `g_Flex_ClearFloat4` | `ClearFloat4.hlsl` | Complete |
| Flex | `g_Flex_ClearInt` | `ClearInt.hlsl` | Complete |
| Flex | `g_Flex_CollideParticles` | `CollideParticles.hlsl` | Complete |
| Flex | `g_Flex_CollideShapes` | `CollideShapes.hlsl` | Complete |
| Flex | `g_Flex_CollideTriangles` | `CollideTriangles.hlsl` | Complete |
| Flex | `g_Flex_CompactDiffuseParticles` | `CompactDiffuseParticles.hlsl` | Complete |
| Flex | `g_Flex_ComputeTriangleBounds` | `ComputeTriangleBounds.hlsl` | Complete |
| Flex | `g_Flex_ContinuousShockPropagation` | `ContinuousShockPropagation.hlsl` | Complete |
| Flex | `g_Flex_CreateDiffuseParticles` | `CreateDiffuseParticles.hlsl_rev` | Complete |
| Flex | `g_Flex_CreateGrid` | `CreateGrid.hlsl` | Complete |
| Flex | `g_Flex_Finalize` | `Finalize.hlsl_rev` | Complete |
| Flex | `g_Flex_NormalizeVertexNormals` | `NormalizeVertexNormals.hlsl` | Complete |
| Flex | `g_Flex_Predict` | `Predict.hlsl` | Complete |
| Flex | `g_Flex_ReorderParticles` | `ReorderParticles.hlsl` | Complete |
| Flex | `g_Flex_SmoothPositions` | `SmoothPositions.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveContactsAccumulate` | `SolveContactsAccumulate.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveContactsAveraged` | `SolveContactsAveraged.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveContactsSequential` | `SolveContactsSequential.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveDensities` | `SolveDensities.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveDensitiesNonFluid` | `SolveDensitiesNonFluid.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveDensitiesSurfaceTension` | `SolveDensitiesSurfaceTension.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveInflatableVolume` | `SolveInflatableVolume.hlsl` | Complete |
| Flex | `g_Flex_SolveInflatableVolumeNV` | `SolveInflatableVolume.hlsl` | Complete |
| Flex | `g_Flex_SolveShapes` | `SolveShapes.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveShapes128NV` | `SolveShapes128NV.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveShapes32NV` | `SolveShapes32NV.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveShapesNV` | `SolveShapesNV.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveShapesPlasticDeformation` | `SolveShapesPlasticDeformation.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveShapesPlasticDeformation128NV` | `SolveShapesPlasticDeformation128NV.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveShapesPlasticDeformation32NV` | `SolveShapesPlasticDeformation32NV.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveShapesPlasticDeformationNV` | `SolveShapesPlasticDeformationNV.hlsl_rev` | Complete |
| Flex | `g_Flex_SolveSprings` | `SolveSprings.hlsl` | Complete |
| Flex | `g_Flex_SolveSpringsNV` | `SolveSprings.hlsl` | Complete |
| Flex | `g_Flex_SolveVelocities` | `SolveVelocities.hlsl_rev` | Complete |
| Flex | `g_Flex_SpringsGenerateIndices` | `SpringsGenerateIndices.hlsl_rev` | Complete |
| Flex | `g_Flex_SpringsParticleRange` | `SpringsParticleRange.hlsl_rev` | Complete |
| Flex | `g_Flex_SpringsReorder` | `SpringsReorder.hlsl_rev` | Complete |
| Flex | `g_Flex_TransformShapeBounds` | `TransformShapeBounds.hlsl_rev` | Complete |
| Flex | `g_Flex_UpdateDiffuseParticles` | `UpdateDiffuseParticles.hlsl_rev` | Complete |
| Flex | `g_Flex_UpdateTriangles` | `UpdateTriangles.hlsl` | Complete |
| Flex | `g_Flex_UpdateTrianglesInit` | `UpdateTrianglesInit.hlsl` | Complete |
| Flex | `g_Flex_UpdateTrianglesNV` | `UpdateTriangles.hlsl` | Complete |
| Flex | `g_Flex_UpdateVelocities` | `UpdateVelocities.hlsl_rev` | Complete |
| Flex | `g_Flex_UpdateVertexNormals` | `UpdateVertexNormals.hlsl` | Complete |
| Flex | `g_Flex_UpdateVertexNormalsInit` | `UpdateVertexNormalsInit.hlsl` | Complete |
| Flex | `g_Flex_UpdateVertexNormalsNV` | `UpdateVertexNormals.hlsl` | Complete |
| Radix sort | `g_RadixSort1CS` | `radixSort1CS.hlsl` | Complete |
| Radix sort | `g_RadixSort2CS` | `radixSort2CS.hlsl` | Complete |
| Radix sort | `g_RadixSort3CS` | `radixSort3CS.hlsl` | Complete |
| Radix sort | `g_RadixSortBlockCS` | `radixSortBlockCS.hlsl` | Complete |
| BVH | `g_bvh_BuildHierarchy` | `bvh/BuildHierarchy.hlsl` | Complete |
| BVH | `g_bvh_BuildLeaves` | `bvh/BuildLeaves.hlsl` | Complete |
| BVH | `g_bvh_CalculateKeyDeltas` | `bvh/CalculateKeyDeltas.hlsl` | Complete |
| BVH | `g_bvh_CalculateMortonCodes` | `bvh/CalculateMortonCodes.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBounds` | `bvh/ComputeTotalBounds.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBoundsAMD` | `bvh/ComputeTotalBounds.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBoundsFinalize` | `bvh/ComputeTotalBoundsFinalize.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBoundsFinalizeAMD` | `bvh/ComputeTotalBoundsFinalize.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBoundsFinalizeNV` | `bvh/ComputeTotalBoundsFinalize.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBoundsGroup` | `bvh/ComputeTotalBoundsGroup.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBoundsGroupAMD` | `bvh/ComputeTotalBoundsGroup.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBoundsGroupNV` | `bvh/ComputeTotalBoundsGroup.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalBoundsNV` | `bvh/ComputeTotalBounds.hlsl` | Complete |
| BVH | `g_bvh_ComputeTotalInvEdges` | `bvh/ComputeTotalInvEdges.hlsl_rev` | Complete |

Shared shader support files:

| File | Role | Status |
| --- | --- | --- |
| `KernelParams.hlsli` | Shared Flex kernel parameter declarations. | Support |
| `Utils.hlsli` | Shared shader helper code. | Support |
| `bvh/BVHCommon.hlsli` | Shared BVH shader helper code. | Support |
| `Shaders.cfg` | Build manifest for recovered shader compilation, including all `.hlsl_rev` sources. | Support |
