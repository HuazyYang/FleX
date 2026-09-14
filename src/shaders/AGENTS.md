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

- The round trip through FXC is the only way to judge bytecode equivalence. On
  Windows the SDK compiler is used directly:
  ```
  fxc=$(find "/c/Program Files (x86)/Windows Kits/10/bin" -path '*/x64/fxc.exe' \
      | sort -Vr | head -1)
  "$fxc" -nologo -T cs_5_0 -E <Entry> -Iexternal/nvapi/include -Fh out.h \
      src/shaders/<Name>.hlsl_rev
  ```
  Under Git Bash, export `MSYS2_ARG_CONV_EXCL='*'` and `MSYS_NO_PATHCONV=1`
  first: MSYS otherwise rewrites `/nologo` into a path and FXC reports
  `Too many files specified`. With path conversion off, give `-Fh` a Windows
  path (forward slashes are fine) and keep the source path relative to the
  repository root.

  On Linux the same command runs under Wine:
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
  The shipped `.asm` files were disassembled by 3Dmigoto, which prints float
  literals with eight decimals where FXC prints six, so collapse them first
  (`sed -E 's/([0-9]+[.][0-9]{6})[0-9]+/\1/g'`) or `1.0e-9` reads as a
  difference. A second pass with register names normalised away
  (`sed -E 's/\br[0-9]+\.[xyzw]+/R/g; s/\br[0-9]+\b/R/g'`) separates real
  differences from register-allocation noise; a third pass that also drops
  `mov` lines isolates control-flow and arithmetic differences from FXC 6.3's
  copy noise, which dominates the large shaders.

- Vendor extension variants use the real vendor header, never a local
  transcription: `#include <nvHLSLExtns.h>` from `external/nvapi/include`, which
  `src/CMakeLists.txt` already puts on the shader include path, plus
  `-DNV_SHADER_EXTN_SLOT=u7` in `Shaders.cfg`. Read the opcode the DXBC stores at
  byte 0 of the `u7` record against `nvShaderExtnEnums.h` before naming the
  intrinsic: opcode 3 is `NV_EXTN_OP_SHFL_DOWN`, and `NV_EXTN_OP_SHFL_XOR` is 4.
  Note `grep` can silently fail to match inside these headers because they are
  ISO-8859 rather than UTF-8; pipe through `tr -d '\r'` and use `LC_ALL=C`.

- Several apparent "compiler version" differences are in fact source-controlled.
  Before writing one off, try these levers, which between them took seven groups
  from `Equivalent` to `Exact`:

  - **Commutative operand order.** FXC 10.1 emits the operands of `mul` in the
    reverse of their source order, so `a * b` disassembles as `mul b, a`; write
    the HLSL the other way round to match the DXBC. `mad`, `add`, `min` and
    `and` behave the same way in most, though not all, positions, so confirm
    each swap with a round trip rather than assuming.
  - **Scheduling by hoisting.** FXC 6.3 emits loop-invariant work in source
    order ahead of the loop; 10.1 sinks it to first use. Binding the expression
    to a named local before the loop (`int lastContact = count - 1;`,
    `bool adhesionEnabled = gParams.kAdhesion != 0.0;`) restores the shipped
    order. The same trick fixes load placement inside a loop body.
  - **Vectorised selects.** Where the DXBC selects several values in one wide
    `movc`, write the selects as a single `float4`/`float2` ternary rather than
    as separate scalar ones.
  - **Basis-axis `cross()`.** 10.1 will not fold `cross(q.xyz, float3(1,0,0))`
    down to one masked `mul`. Supply the folded cross and dot to a `RotateBasis`
    helper (see `TransformShapeBounds.hlsl_rev`, `SolveShapes.hlsl_rev`) and the
    single instruction comes back.
  - **Gate shape.** An `a && b && c` chain compiles to `and`s feeding one
    `if_nz`; the DXBC's nested `if_nz` gates need nested `if` statements in the
    source. Likewise, where the DXBC performs a store inside a helper rather
    than gating on its return value, the helper has to do the store.
  - **Groupshared stores.** Clearing a `float3x3` by rows rather than columns
    reproduces the shipped three 12-byte `store_raw`s instead of 16/16/4.
  - **Signed versus unsigned shifts.** `threadIdx >> 5` on a `uint` emits
    `ushr`; the DXBC's `ishr` needs `int(threadIdx) >> 5`.

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
  its DXBC. Once its group reaches `Exact` or `Verified` in the status table
  below, rename it to `.hlsl` and update its `Shaders.cfg` line, its
  `src/Library.cpp` generated-header include, and its table row in the same
  change; the suffix marks work in progress, not provenance. A group that is
  still `Equivalent` keeps `.hlsl_rev` until runtime verification clears it.
  Every `.hlsl_rev` file in this folder is listed in `Shaders.cfg`.

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
(see the FXC recipe above), not just a reading of the source:

- `Exact` — the recovered source recompiles to disassembly identical to the
  shipped `.asm` once the binding/`dcl_*` declarations and the trailing
  instruction-count comment are removed.
- `Verified` — not byte-identical, but the structural audit below passes on all
  five axes *and* the opcode histogram matches exactly. Every remaining
  difference is register naming, in-block scheduling, or the operand order of a
  commutative instruction. Accepted as trustworthy without a runtime check.
- `Equivalent` — control flow, `dcl_*` bindings, constant-buffer fields and
  memory effects are identical, and every remaining arithmetic difference has
  been individually accounted for as an FXC 6.3 vs 10.1 artifact (register
  allocation, in-block scheduling, commutative operand order, write masks,
  vector packing, and folding of `cross()` against a literal basis vector).
  It does **not** promise equal opcode counts — see the audit below for what is
  actually checked, and for the cases where counts legitimately differ. These
  groups are **pending runtime verification**: the structural audit rules out
  every divergence that changes control flow, memory effects or bindings, but it
  is not a proof, and one mislabelled group (see below) shows why that matters.
- `Partial` — some instruction blocks still differ in substance; the divergence
  is named in the notes under the table.

The `.hlsl` groups have now been through the same round trip and carry the same
three statuses. Only the BVH and radix-sort groups are still marked `Complete`,
meaning reviewed against the DXBC but not round-tripped here.

Summary: 84 DXBC shader groups, of which 67 have been round-tripped — 38
recompile exactly, 6 are `Verified`, and 23 are `Equivalent` and awaiting
runtime verification. No group is `Partial` any more; the remaining 17 (BVH,
radix sort) stay `Complete`.

Eighteen hand-recovered groups have reached `Exact` or `Verified` and been
renamed from `.hlsl_rev` to `.hlsl`, leaving 15 `.hlsl_rev` sources, all
`Equivalent`.

The six `Verified` groups are `g_Flex_ContinuousShockPropagation`,
`g_Flex_CreateGrid`, `g_Flex_Predict`, `g_Flex_SolveSprings`,
`g_Flex_SolveSpringsNV` and `g_Flex_UpdateDiffuseParticles`. Their entire
residual is:

- `CreateGrid`, `SolveSprings`, `SolveSpringsNV`, `UpdateDiffuseParticles` —
  register naming only, plus one commutative `mul` order in
  `UpdateDiffuseParticles`; identical after register normalisation.
- `Predict` — one `rsq` scheduled two instructions later.
- `ContinuousShockPropagation` — one `ld_raw` scheduled one instruction later
  and one `add` with its operands the other way round.

Next round: runtime verification for the 23 `Equivalent` groups — run the
shipped bytecode and the recompiled bytecode over identical inputs and compare
the output buffers. Until that lands, treat `Equivalent` as "no structural
divergence found", not as "known to agree".

The two groups that were `Partial` are no longer so. Both were control-flow
*shape* differences, and both were fixed at the source level:

- `CollideShapes.hlsl_rev` — `SdfContact` no longer returns a hit flag for the
  caller to gate on. The DXBC nests the contact store inside the gradient test,
  so `SdfContact` takes the store parameters and calls `StoreContact` itself.
  With that change every `if_nz` / `else` / `endif` / `switch` / `break` matches
  one for one, and the only opcodes whose counts still differ are `mul` (66 vs
  54), `mad` (63 vs 55) and `mov` (209 vs 50).
- `CollideTriangles.hlsl_rev` — the three tests that gate collecting a triangle
  shape are written as nested `if` statements again rather than one `&&` chain,
  which restores the DXBC's three `if_nz` gates. Control flow now matches
  exactly; `mul` (40 vs 32), `mad` (49 vs 41) and `mov` still differ.

What remains in the `Equivalent` group, largest first, and why:

- `CollideShapes.hlsl_rev` (231 lines after register normalisation, 64 once
  `mov` lines are also dropped) and `CollideTriangles.hlsl_rev` (128, 59). FXC
  6.3 emits a cross product as a two-wide `mul`/`mad` pair plus a scalar
  `mul`/`mad`, where 10.1 packs it three-wide; each such site costs two
  instructions. The rest is copy noise — `CollideShapes` carries 209 `mov`s
  against 50.
- The `SolveShapes` family (42 to 70). Three causes remain after the
  `RotateBasis`, row-wise groupshared clear and scalar `QuatMul` fixes: 10.1
  re-vectorises part of the quaternion multiply and lowers the normalise as
  `dp4`; it folds a duplicated `t7` load of the same index into one; and in the
  `*NV` variants it hoists the lane split out of the two inlined reductions
  where 6.3 recomputes `and l(31)` / `ishr l(5)` at each use.
- `CollideParticles.hlsl_rev` (20). 10.1 preloads
  `gParams.kMaxNeighborsPerParticle` into a register and then has to carry it
  through the three-deep cell loop, which costs six `mov`s that 6.3 avoids by
  reading the constant buffer at the use site.
- `TransformShapeBounds.hlsl_rev` (15). The centre rotate's `cross()` is split
  two-wide-plus-scalar by 6.3, and the two shape-position loads are sunk to
  their use sites there but hoisted by 10.1.
- `CalculateAnisotropy.hlsl_rev` (13). 6.3 packs the nine covariance entries
  into `r3.xyzw`/`r4.xyzw`/`r2.z` and accumulates them with four-wide `mad`s;
  10.1 keeps the `float3x3` as three separate rows.
- `SolveVelocities.hlsl_rev` (7). 6.3 shuffles the vorticity gradient into
  `r4.yzw` (`mov r4.xyzw, r4.yzzx`) and the split cross product that follows
  costs two instructions.
- `SmoothPositions.hlsl_rev` (4) is the clearest case of pure allocation noise:
  the shipped `.asm` carries an `else` arm whose only contents are `mov r, r`
  copies of the same value the `then` arm produces, and 10.1 coalesces the
  registers and drops the arm.
- The three `CalculateInflatableVolume` variants (58 to 78). The residual is
  the scalar-versus-vector read-modify-write of the 12 groupshared bytes that
  hold the running centre: FXC 6.3 emits three `ld_raw`/`add`/`store_raw`
  triples at byte offsets 0, 4 and 8 where 10.1 emits one three-component
  triple at offset 0. The block runs on thread 0 only, between two
  `sync_g_t`s, so the two forms are interchangeable.
- `UpdateTriangles` and `UpdateTrianglesNV` (17) carry the wind vector in
  reversed `zyx` component order through the averaging and the length test, and
  un-reverse it (`r5.wzyw`) before normalising, so the packing is undone before
  the value is used; plus tighter cross-product packing in 10.1.

Every recovered source is listed in `Shaders.cfg` exactly once with an entry
point equal to its file stem, and all of them compile with the Windows SDK FXC
as `cs_5_0`. The only FXC diagnostics are three intentional ones: the
`potentially uninitialized variable` warnings for `p0` in `CollideParticles`
and for `lower`/`upper` in `TransformShapeBounds`, which reproduce the DXBC's
habit of leaving an output unwritten on the miss path, and a register-pressure
performance note on `CollideTriangles`. No source in this folder contains a
decompiler placeholder.

Note that the DXC in the Windows 10.0.19041 SDK does not resolve the
angle-bracket `#include <nvHLSLExtns.h>` from `-I`, so the DXC syntax check
covers every recovered source except the six NV `SolveShapes` variants. FXC is
the authority for this work in any case.

## Equivalence audit

A diff of the disassembly is not by itself evidence of equivalence, so every
`Equivalent` group has been checked mechanically on five axes that a
register-allocation difference cannot disturb:

1. `dcl_*` — resource slots, buffer strides, raw vs structured vs typed kinds,
   UAV declarations, `dcl_tgsm` sizes, `dcl_thread_group`, `dcl_globalFlags`.
2. Control flow — counts of `if_nz` / `if_z` / `else` / `endif` / `loop` /
   `endloop` / `break` / `breakc_*` / `switch` / `case` / `ret` / `sync_*`.
3. Memory effects — counts of every `ld_*` / `store_*` / `imm_atomic_*` /
   `sample*`, and the number of references to each `t#` / `u#` / `g#`.
4. Constant-buffer fields — the set of distinct `cb0[n]` / `cb1[n]` slots read.
5. Literals — the multiset of immediate values.

All five axes, plus the full opcode histogram, match on the six `Verified`
groups. Across the 23 `Equivalent` groups axes 1, 2 and 4 match everywhere. The known and accepted exceptions on
the other two axes, each inspected individually, are:

- **Redundant-load elimination.** The `SolveShapes` family loads
  `localNormals[entry]` (`t7`) twice in the shipped code and once in ours
  (`ld_structured_indexable` 18 vs 17, or 21 vs 20). `t7` is an SRV, read-only
  for the whole dispatch, and both loads use the same index, so the values are
  identical.
- **Scalar versus vector groupshared read-modify-write.** See the
  `CalculateInflatableVolume` note above: the same 12 bytes, the same addition,
  one thread, same barriers.
- **`cross()` packing.** FXC 6.3 emits a cross product as a two-wide `mul`/`mad`
  pair plus a scalar `mul`/`mad`; 10.1 packs it three-wide. Two extra
  instructions per site, identical per-component arithmetic. This accounts for
  the bulk of the `mul`/`mad` deltas in `CollideShapes`, `CollideTriangles`,
  `TransformShapeBounds`, `CalculateVorticity`, `SolveInflatableVolume`,
  `UpdateTriangles` and `SolveVelocities`.
- **Common-subexpression elimination.** `CollideTriangles` computes a delta and
  its `dp3` twice in the shipped code, once with each operand order; since
  `dot(-D, -D) == dot(D, D)` bit for bit, 10.1 keeps one (`dp3` 22 vs 21). The
  normalised direction that follows uses the same operand order on both sides,
  so the contact normal does not flip.
- **Boolean materialisation.** `CalculateVorticity` has two `ine r, r, l(0)`
  that 10.1 folds away. Both results feed only an `if_z`, where the truth value
  is unchanged.
- **Literal component placement.** Differences such as `l(0,1,2,0)` versus
  `l(1,0,0,2)` are the same constants moved to different components to follow a
  different destination write mask.

Two caveats that the audit cannot remove, and which apply to the shipped
bytecode just as much as to ours:

- The `SolveShapes` family emits one `dp4` for the quaternion length where the
  shipped code emits a `mul`/`add`/`mad` chain. The summation order inside a
  dot-product opcode is implementation-defined, so this term can differ by
  roughly an ulp. It feeds a `> 0` test and an `rsqrt`, so nothing downstream
  is sensitive to it.
- Both builds declare `dcl_globalFlags refactoringAllowed`, which permits the
  driver to reassociate and to fuse `mul`/`add` into `mad`. Bit-exact results
  were therefore never guaranteed even for the shipped bytecode across two
  different GPUs; "same disassembly" is a stronger property than these shaders
  ever relied on.

One group that the audit caught. `CalculateInflatableVolumeNV` and
`CalculateInflatableVolumeAMD` used to sum all sixteen per-wave partials
unconditionally, where the DXBC sums only `min(numTrisInBlock, 512) >> 5` of
them, predicating the unrolled adds on a counter carried in the `.w` lane. The
partials past that count are zero except for the wave that straddles the end of
the block, so the shipped shader drops that wave's triangles whenever
`numTrisInBlock` is not a multiple of 32 — a rounding quirk it shares with the
generic path's `numTrisInBlock >> 1` tree. `ReduceCenter` and `ReduceVolume`
now take the bound from `numTrisInBlock`, as the parameter's presence in the
signature always implied, and `dcl_temps` on the NV variant went from 19 to the
shipped 34 as a result. This was a genuine behavioural divergence, not a
packing artifact, and it had been mislabelled `Equivalent`.

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
| Flex | `g_Flex_CalculateDensitySurfaceTension` | `CalculateDensitySurfaceTension.hlsl` | Exact |
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
| Flex | `g_Flex_CollideShapes` | `CollideShapes.hlsl_rev` | Equivalent |
| Flex | `g_Flex_CollideTriangles` | `CollideTriangles.hlsl_rev` | Equivalent |
| Flex | `g_Flex_CompactDiffuseParticles` | `CompactDiffuseParticles.hlsl` | Exact |
| Flex | `g_Flex_ComputeTriangleBounds` | `ComputeTriangleBounds.hlsl` | Exact |
| Flex | `g_Flex_ContinuousShockPropagation` | `ContinuousShockPropagation.hlsl` | Verified |
| Flex | `g_Flex_CreateDiffuseParticles` | `CreateDiffuseParticles.hlsl` | Exact |
| Flex | `g_Flex_CreateGrid` | `CreateGrid.hlsl` | Verified |
| Flex | `g_Flex_Finalize` | `Finalize.hlsl` | Exact |
| Flex | `g_Flex_NormalizeVertexNormals` | `NormalizeVertexNormals.hlsl` | Exact |
| Flex | `g_Flex_Predict` | `Predict.hlsl` | Verified |
| Flex | `g_Flex_ReorderParticles` | `ReorderParticles.hlsl` | Exact |
| Flex | `g_Flex_SmoothPositions` | `SmoothPositions.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SolveContactsAccumulate` | `SolveContactsAccumulate.hlsl` | Exact |
| Flex | `g_Flex_SolveContactsAveraged` | `SolveContactsAveraged.hlsl` | Exact |
| Flex | `g_Flex_SolveContactsSequential` | `SolveContactsSequential.hlsl` | Exact |
| Flex | `g_Flex_SolveDensities` | `SolveDensities.hlsl` | Exact |
| Flex | `g_Flex_SolveDensitiesNonFluid` | `SolveDensitiesNonFluid.hlsl` | Exact |
| Flex | `g_Flex_SolveDensitiesSurfaceTension` | `SolveDensitiesSurfaceTension.hlsl` | Exact |
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
| Flex | `g_Flex_SolveSprings` | `SolveSprings.hlsl` | Verified |
| Flex | `g_Flex_SolveSpringsNV` | `SolveSprings.hlsl` | Verified |
| Flex | `g_Flex_SolveVelocities` | `SolveVelocities.hlsl_rev` | Equivalent |
| Flex | `g_Flex_SpringsGenerateIndices` | `SpringsGenerateIndices.hlsl` | Exact |
| Flex | `g_Flex_SpringsParticleRange` | `SpringsParticleRange.hlsl` | Exact |
| Flex | `g_Flex_SpringsReorder` | `SpringsReorder.hlsl` | Exact |
| Flex | `g_Flex_TransformShapeBounds` | `TransformShapeBounds.hlsl_rev` | Equivalent |
| Flex | `g_Flex_UpdateDiffuseParticles` | `UpdateDiffuseParticles.hlsl` | Verified |
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
