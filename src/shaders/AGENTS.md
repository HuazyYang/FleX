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

- On Linux the same comparison can be run directly with the Wine-hosted Windows
  SDK compiler, which is the only way to judge bytecode equivalence:
  ```
  fxc=$(find "${WINEPREFIX:-$HOME/.wineprefixes/dev-x64}/drive_c/Program Files (x86)/Windows Kits/10/bin" \
      -path '*/x64/fxc.exe' | sort -Vr | head -1)
  WINEDEBUG=-all wine "$fxc" /nologo -T cs_5_0 -E <Entry> -Fh out.h src/shaders/<Name>.hlsl_rev
  ```
  Keep the input and output paths relative to the repository root; FXC runs
  under Wine and cannot open absolute Linux paths.
  Extract the block from `cs_5_0` to `#endif` in `out.h` (it is CRLF), strip the
  `dcl_constantbuffer` / `dcl_resource_*` / `dcl_uav_*` / `dcl_globalFlags` /
  `dcl_indexableTemp` lines and the trailing `// Approximately N instruction
  slots used` comment, then diff against the same range of `../dxbc/g_*.asm`.
  A second pass with register names normalised away
  (`sed -E 's/\br[0-9]+\.[xyzw]+/R/g; s/\br[0-9]+\b/R/g'`) separates real
  differences from register-allocation noise.

- Vendor extension variants use the real vendor header, never a local
  transcription: `#include <nvHLSLExtns.h>` from `external/nvapi/include`, which
  `src/CMakeLists.txt` already puts on the shader include path, plus
  `-DNV_SHADER_EXTN_SLOT=u7` in `Shaders.cfg`. Read the opcode the DXBC stores at
  byte 0 of the `u7` record against `nvShaderExtnEnums.h` before naming the
  intrinsic: opcode 3 is `NV_EXTN_OP_SHFL_DOWN`, and `NV_EXTN_OP_SHFL_XOR` is 4.
  Note `grep` can silently fail to match inside these headers because they are
  ISO-8859 rather than UTF-8; pipe through `tr -d '\r'` and use `LC_ALL=C`.

- The shipped `.asm` files were produced by FXC 6.3.9600 (Windows 8.1 SDK); the
  SDK available here is FXC 10.1. Even for a perfect source recovery the two
  differ in ways that carry no semantic weight, and these are expected:
  register allocation and the `mov` shuffles it implies, instruction scheduling
  within a basic block, operand order of commutative `add`/`mul`/`and`/`or`,
  destination write masks and the source swizzles that follow from them, and
  constant folding of `cross()` against a literal basis vector. Chase a
  difference only when it changes the opcode sequence, the control flow, or an
  operand's meaning.

- Local DXC checks are useful syntax guards for recovered sources, but FXC/DXBC
  output remains authoritative for bytecode matching.

## Conventions

- Keep hand-recovered shader source close to the DXBC body. Prefer clear,
  direct HLSL that preserves control-flow gates, arithmetic order, and output
  semantics over high-level rewrites.

- Use `.hlsl_rev` while a hand-recovered source is still being reconciled with
  its DXBC. Once its group reaches `Exact` in the status table below, rename it
  to `.hlsl` and update its `Shaders.cfg` line and table row in the same change;
  the suffix marks work in progress, not provenance. Every `.hlsl_rev` file in
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

- When updating `Shaders.cfg`, verify that every recovered source is listed
  exactly once, the entry point matches the file stem, and the line does not
  introduce duplicate output names unintentionally.

## Current Work Status

Status is tracked per unique DXBC shader group. The authoritative recovery
source is the corresponding `.asm` disassembly in `../dxbc`; DXBC-side `.hlsl`
artifacts are only rough decompiler hints.

For `.hlsl_rev` groups the status now records the result of an FXC round trip
(see the Wine FXC recipe above), not just a reading of the source:

- `Exact` — the recovered source recompiles to disassembly identical to the
  shipped `.asm` once the binding/`dcl_*` declarations and the trailing
  instruction-count comment are removed.
- `Equivalent` — the opcode sequence and control flow match the shipped `.asm`
  one for one; the remaining textual differences are the FXC 6.3 vs 10.1
  artifacts listed under Development Guidelines (register allocation, in-block
  scheduling, commutative operand order, write masks, and folding of `cross()`
  against a literal basis vector).
- `Partial` — some instruction blocks still differ in substance; the divergence
  is named in the notes under the table.

The `.hlsl` groups have now been through the same round trip and carry the same
three statuses. Only the BVH and radix-sort groups are still marked `Complete`,
meaning reviewed against the DXBC but not round-tripped here.

Summary: 84 DXBC shader groups, of which 67 have been round-tripped — 31
recompile exactly, 34 recompile to an equivalent instruction sequence, and 2 are
partial; the remaining 17 (BVH, radix sort) stay `Complete`.

The ten hand-recovered groups that reached `Exact` have been renamed from
`.hlsl_rev` to `.hlsl`, leaving 23 `.hlsl_rev` sources: 21 equivalent and 2
partial. Counting by entry point rather than file, 31 of the 67 round-tripped
groups recompile exactly.

Every recovered source is listed in `Shaders.cfg` exactly once with an entry
point equal to its file stem; all of them compile with the Windows SDK FXC as
`cs_5_0` and pass a DXC `-T cs_6_0 -HV 2016` syntax check, whose only diagnostics are the two
intentional `-Wparameter-usage` warnings for `planeW` in
`CollideShapes.hlsl_rev` (`BoxContact` and `SdfContact` write their out
parameters only on the hit path, as the DXBC does; both sites carry a comment
saying so). No source in this folder contains a decompiler placeholder.

Known remaining divergence. No recovered source is now known to disagree with
its `.asm` on what it computes. The two `Partial` rows are control-flow *shape*
differences, where the two compiler versions emit the same computation with a
different branch layout; they are recorded as `Partial` rather than `Equivalent`
only because the number of branches does not match one for one.

- `CollideShapes.hlsl_rev` — FXC 10.1 materialises `SdfContact`'s boolean
  return into a register (one extra `else` holding `mov r, l(0)`) and merges the
  gradient test into the store gate with an extra `and`, where FXC 6.3 nested
  the store directly inside the gate. `if_nz`, `endif`, `loop`, `switch` and
  `break` counts are otherwise identical on both sides, no resource access
  differs, and the arithmetic matches. `CapsuleContact` is now the full
  segment-versus-segment closest-point test with both `div_sat` clamps, matching
  the DXBC; the earlier axis-clamp approximation is gone.
- `CollideTriangles.hlsl_rev` — FXC 10.1 flattens three nested `if_nz` gates in
  the triangle-collection loop into `ine` plus two `and` feeding a single
  `if_nz`, so the new build has two fewer `if_nz`/`endif` pairs. It also hoists
  the particle load block above the neighbour loop. Nothing else differs beyond
  register allocation and `mad`/`mul` packing.
Among the `.hlsl` groups the largest residuals are the three
`CalculateInflatableVolume` variants (58 to 167 lines after register
normalisation). Their reductions match the DXBC exactly — same shuffle/swizzle
counts, same groupshared traffic, same barrier count, no control-flow
asymmetry — and the residual is FXC 6.3 hoisting the sixteen unrolled partial-sum
indices into registers (`dcl_temps` 34 versus 19 on the NV variant) together with
swizzle packing. `UpdateTriangles` and `UpdateTrianglesNV` (19) carry the wind
vector in reversed `zyx` component order throughout, which is a packing choice,
plus tighter cross-product packing in 10.1.

The largest residuals among the `Equivalent` group are worth knowing so they are
not mistaken for regressions. `SmoothPositions.hlsl_rev` (6 lines after register
normalisation) is the clearest case of pure allocation noise: the shipped `.asm`
carries an `else` arm whose only contents are `mov r, r` copies of the same value
the `then` arm produces, and FXC 10.1 coalesces the registers and drops the arm.
An `else` that holds nothing but register copies is register allocation, not a
control-flow difference, which is why this counts as `Equivalent`. `CalculateAnisotropy.hlsl_rev` (66 lines after
register normalisation) differs by FXC 6.3 lowering one `sqrt()` as `rsq` plus
`mul` where 10.1 emits `sqrt`, and by the final clamp being one vector
`sqrt`/`mul`/`max`/`min` group in 6.3 versus three scalar groups in 10.1.
The whole `SolveShapes` family — `SolveShapes.hlsl_rev` (61),
`SolveShapesPlasticDeformation.hlsl_rev` (71) and the six `*NV` variants (65 to
83) — shares one set of causes. FXC 10.1 folds the `cross()` calls against a
literal basis vector inside `ExtractRotation` differently and packs the
quaternion rotate into `dp3`/`mad`/`dp4` where 6.3 emits a nine-instruction
scalar `mad` chain; the groupshared covariance clear is written `xyzw`/`xyzw`/`x`
at offsets 0/16/32 instead of `xyz` at 0/12/24 (the same 36 bytes); and 10.1
folds a duplicated `t7` load of the same index (`r3.y`) into one, which is the
only resource-access count that differs anywhere in the family. The `*NV`
variants add one more: 10.1 feeds `bfi` and `if_z` from `vThreadIDInGroup.x`
directly and computes the lane split once as `and l(31)` plus `ushr l(5)`, where
6.3 copies the value into a register and recomputes `and l(31)` / `ishr l(5)` at
each use. Control flow, atomics (`imm_atomic_alloc` 128, `imm_atomic_cmp_exch` 0)
and every `store_raw` / `store_structured` / `sync` / `ld_raw` count are equal on
both sides for all six.

Behaviour worth knowing, preserved because the DXBC is authoritative:

- `g_Flex_SolveVelocities` ends the sleep clamp with `mov r3.xyz, -r1.xxxx`,
  i.e. the delta is `-velocity.x` broadcast to all three components rather than
  `-velocity`. `SolveVelocities.hlsl_rev` reproduces this with `-velocity.xxx`.
- `g_Flex_SolveVelocities` scales the diffuse potential by
  `1 - 2 * kInvRestDensity * density` (emitted as a `dp2` of two equal pairs),
  not `1 - kInvRestDensity * density`. Both `SolveVelocities` quirks carry an
  in-source comment naming the DXBC instruction they come from, so they are not
  "simplified" away by a later reader.
- `g_Flex_ClampDiffuseParticleCount` clamps through `float` (`itof` / `min` /
  `ftoi`) rather than an integer `imin`.
- `g_Flex_CollideShapes` orders the shape dispatch box, convex mesh, sphere,
  capsule, SDF, and calls the contact store inside each branch.
- `g_Flex_ClearInt` and `g_Flex_ClearFloat4` compare the thread index against
  the raw `gLength` constant; neither scales it. `Library::ClearBufferFloat4`
  passes an element count, which matches. `Library::ClearBufferInt` passes
  `sizeInBytes` while dispatching only `sizeInBytes / 4` threads, so its bound is
  four times larger than the buffer and never binds — harmless, but the C++ field
  name `lengthInWords` does not describe what either shader reads.
- `g_Flex_UpdateTriangles` averages the three vertex velocities with a literal
  `0.3333`, not `1.0 / 3.0`.

| Family | DXBC shader group | `src/shaders` source | Status |
| --- | --- | --- | --- |
| Flex | `g_Flex_ApplyDeltas` | `ApplyDeltas.hlsl` | Exact |
| Flex | `g_Flex_CalculateAnisotropy` | `CalculateAnisotropy.hlsl_rev` | Equivalent |
| Flex | `g_Flex_CalculateBounds` | `CalculateBounds.hlsl` | Exact |
| Flex | `g_Flex_CalculateBoundsAMD` | `CalculateBounds.hlsl` | Exact |
| Flex | `g_Flex_CalculateBoundsFinalize` | `CalculateBoundsFinalize.hlsl` | Exact |
| Flex | `g_Flex_CalculateBoundsFinalizeAMD` | `CalculateBoundsFinalize.hlsl` | Exact |
| Flex | `g_Flex_CalculateBoundsFinalizeNV` | `CalculateBoundsFinalize.hlsl` | Exact |
| Flex | `g_Flex_CalculateBoundsGroup` | `CalculateBoundsGroup.hlsl` | Exact |
| Flex | `g_Flex_CalculateBoundsGroupAMD` | `CalculateBoundsGroup.hlsl` | Exact |
| Flex | `g_Flex_CalculateBoundsGroupNV` | `CalculateBoundsGroup.hlsl` | Exact |
| Flex | `g_Flex_CalculateBoundsNV` | `CalculateBounds.hlsl` | Exact |
| Flex | `g_Flex_CalculateDensity` | `CalculateDensity.hlsl` | Exact |
| Flex | `g_Flex_CalculateDensitySurfaceTension` | `CalculateDensitySurfaceTension.hlsl_rev` | Equivalent |
| Flex | `g_Flex_CalculateInflatableVolume` | `CalculateInflatableVolume.hlsl` | Equivalent |
| Flex | `g_Flex_CalculateInflatableVolumeAMD` | `CalculateInflatableVolume.hlsl` | Equivalent |
| Flex | `g_Flex_CalculateInflatableVolumeNV` | `CalculateInflatableVolume.hlsl` | Equivalent |
| Flex | `g_Flex_CalculateParticleHash` | `CalculateParticleHash.hlsl` | Exact |
| Flex | `g_Flex_CalculateVorticity` | `CalculateVorticity.hlsl` | Equivalent |
| Flex | `g_Flex_ClampDiffuseParticleCount` | `ClampDiffuseParticleCount.hlsl` | Exact |
| Flex | `g_Flex_ClearCellBuckets` | `ClearCellBuckets.hlsl` | Exact |
| Flex | `g_Flex_ClearFloat4` | `ClearFloat4.hlsl` | Exact |
| Flex | `g_Flex_ClearInt` | `ClearInt.hlsl` | Exact |
| Flex | `g_Flex_CollideParticles` | `CollideParticles.hlsl_rev` | Equivalent |
| Flex | `g_Flex_CollideShapes` | `CollideShapes.hlsl_rev` | Partial |
| Flex | `g_Flex_CollideTriangles` | `CollideTriangles.hlsl_rev` | Partial |
| Flex | `g_Flex_CompactDiffuseParticles` | `CompactDiffuseParticles.hlsl` | Exact |
| Flex | `g_Flex_ComputeTriangleBounds` | `ComputeTriangleBounds.hlsl` | Exact |
| Flex | `g_Flex_ContinuousShockPropagation` | `ContinuousShockPropagation.hlsl` | Equivalent |
| Flex | `g_Flex_CreateDiffuseParticles` | `CreateDiffuseParticles.hlsl` | Exact |
| Flex | `g_Flex_CreateGrid` | `CreateGrid.hlsl` | Equivalent |
| Flex | `g_Flex_Finalize` | `Finalize.hlsl` | Exact |
| Flex | `g_Flex_NormalizeVertexNormals` | `NormalizeVertexNormals.hlsl` | Exact |
| Flex | `g_Flex_Predict` | `Predict.hlsl` | Equivalent |
| Flex | `g_Flex_ReorderParticles` | `ReorderParticles.hlsl` | Exact |
| Flex | `g_Flex_SmoothPositions` | `SmoothPositions.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveContactsAccumulate` | `SolveContactsAccumulate.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveContactsAveraged` | `SolveContactsAveraged.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveContactsSequential` | `SolveContactsSequential.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveDensities` | `SolveDensities.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveDensitiesNonFluid` | `SolveDensitiesNonFluid.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveDensitiesSurfaceTension` | `SolveDensitiesSurfaceTension.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveInflatableVolume` | `SolveInflatableVolume.hlsl` | Equivalent |
| Flex | `g_Flex_SolveInflatableVolumeNV` | `SolveInflatableVolume.hlsl` | Equivalent |
| Flex | `g_Flex_SolveShapes` | `SolveShapes.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveShapes128NV` | `SolveShapes128NV.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveShapes32NV` | `SolveShapes32NV.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveShapesNV` | `SolveShapesNV.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveShapesPlasticDeformation` | `SolveShapesPlasticDeformation.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveShapesPlasticDeformation128NV` | `SolveShapesPlasticDeformation128NV.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveShapesPlasticDeformation32NV` | `SolveShapesPlasticDeformation32NV.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveShapesPlasticDeformationNV` | `SolveShapesPlasticDeformationNV.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveSprings` | `SolveSprings.hlsl` | Equivalent |
| Flex | `g_Flex_SolveSpringsNV` | `SolveSprings.hlsl` | Equivalent |
| Flex | `g_Flex_SolveVelocities` | `SolveVelocities.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SpringsGenerateIndices` | `SpringsGenerateIndices.hlsl` | Exact |
| Flex | `g_Flex_SpringsParticleRange` | `SpringsParticleRange.hlsl` | Exact |
| Flex | `g_Flex_SpringsReorder` | `SpringsReorder.hlsl` | Exact |
| Flex | `g_Flex_TransformShapeBounds` | `TransformShapeBounds.hlsl_rev` | Equivalent |
| Flex | `g_Flex_UpdateDiffuseParticles` | `UpdateDiffuseParticles.hlsl_rev` | Equivalent |
| Flex | `g_Flex_UpdateTriangles` | `UpdateTriangles.hlsl` | Equivalent |
| Flex | `g_Flex_UpdateTrianglesInit` | `UpdateTrianglesInit.hlsl` | Exact |
| Flex | `g_Flex_UpdateTrianglesNV` | `UpdateTriangles.hlsl` | Equivalent |
| Flex | `g_Flex_UpdateVelocities` | `UpdateVelocities.hlsl` | Exact |
| Flex | `g_Flex_UpdateVertexNormals` | `UpdateVertexNormals.hlsl` | Exact |
| Flex | `g_Flex_UpdateVertexNormalsInit` | `UpdateVertexNormalsInit.hlsl` | Exact |
| Flex | `g_Flex_UpdateVertexNormalsNV` | `UpdateVertexNormals.hlsl` | Exact |
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
| BVH | `g_bvh_ComputeTotalInvEdges` | `bvh/ComputeTotalInvEdges.hlsl` | Exact |

Shared shader support files:

| File | Role | Status |
| --- | --- | --- |
| `KernelParams.hlsli` | Shared Flex kernel parameter declarations. | Support |
| `Utils.hlsli` | Shared shader helper code. | Support |
| `bvh/BVHCommon.hlsli` | Shared BVH shader helper code. | Support |
| `Shaders.cfg` | Build manifest for recovered shader compilation, including all `.hlsl_rev` sources. | Support |
