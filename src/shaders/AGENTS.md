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
    helper (see `TransformShapeBounds.hlsl`, `SolveShapes.hlsl_rev`) and the
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
  below, rename it to `.hlsl` and update its `Shaders.cfg` line (keep the flag
  column at 52), its `src/Library.cpp` generated-header include, and its table
  row in the same change; the suffix marks work in progress, not provenance. A
  group that is still `Equivalent` keeps `.hlsl_rev` until runtime verification
  clears it — `Equivalent` is not a passing grade, it is the absence of a
  finding. Every `.hlsl_rev` file in this folder is listed in `Shaders.cfg`.

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
- `Verified` — not byte-identical, but trustworthy. Reached one of two ways.
  Either a runtime differential test showed bit-identical output against the
  shipped blob on scenes with a zero noise floor (the strong form, and the only
  one that has ever caught a bug), or the structural audit passed on all five
  axes *and* the opcode histogram matched exactly *and* the constant-bit sweep
  came back clean, leaving nothing that could carry a semantic difference. The
  status table marks which; see the summary above.
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
- `Divergent` — a runtime differential test (see Runtime verification below)
  shows the recompiled bytecode producing different output from the shipped
  blob, with a signature that rules out floating-point rounding. The recovery is
  wrong somewhere and the group is back to being work in progress. No group
  currently carries this status; three did, and all three are fixed.
- `Partial` — some instruction blocks still differ in substance; the divergence
  is named in the notes under the table.

The `.hlsl` groups have now been through the same round trip and carry the same
three statuses. Only the BVH and radix-sort groups are still marked `Complete`,
meaning reviewed against the DXBC but not round-tripped here.

Summary: 84 DXBC shader groups, of which 67 have been round-tripped — 38
recompile exactly, 13 are `Verified` and 16 are `Equivalent`. Nothing is
`Divergent`. The remaining 17 (BVH, radix sort) stay `Complete`.

Both rounds of verification are finished. The structural audit came first and
the runtime differential test second, and the second round is what earned the
trust — of the 23 groups the audit had passed as `Equivalent`, **three were
wrong**, and none of the three could have been caught by reading disassembly:

- `CollideTriangles` — `cross(cv, d)` where the DXBC has `cross(d, cv)`, which
  silently disabled the tunneling test;
- `CollideShapes` — the contact sweep based at `localEnd` instead of
  `localStart`, plus a convex plane offset stored margin-adjusted;
- `CalculateAnisotropy` — a Jacobi convergence threshold of `1e-9` where the
  shipped blob has `1e-15`, invisible because both print as `l(0.000000)`.

A later round, on an NVIDIA device, found a fourth in code the audit had also
passed:

- the whole `SolveShapes` family — `QuatMul` written with the cross-product
  terms parenthesised, which FXC lowers to a balanced accumulation tree where
  the shipped blob is a flat left-to-right `mad` chain. Every term is correct
  and the products are identical; only the order of the three additions differs.
  On Rigid8 that moved 1886 of 192000 floats within frame 0, by up to 43 ulp,
  growing to 1.9 world units by frame 59.

Twenty-five hand-recovered groups have now reached `Exact` or `Verified` and
carry the `.hlsl` suffix. Eight `.hlsl_rev` sources remain, all `Equivalent`:
the `SolveShapes` and `SolveShapesPlasticDeformation` variants. See [What the
remaining `.hlsl_rev` sources still
owe](#what-the-remaining-hlsl_rev-sources-still-owe) for why none of them can be
promoted yet.

The thirteen `Verified` groups fall into two tiers, and the distinction matters
when deciding how far to trust one:

- **Runtime bit-identical** (7): `g_Flex_CalculateAnisotropy`,
  `g_Flex_CollideParticles`, `g_Flex_CollideShapes`, `g_Flex_CollideTriangles`,
  `g_Flex_SmoothPositions`, `g_Flex_TransformShapeBounds`,
  `g_Flex_SolveVelocities`. All seven were swapped in together and produced
  bit-identical positions, smoothed positions and anisotropy over 60 frames on
  Rigid8, Shape Collision, Triangle Collision and Viscosity Med — four scenes
  whose noise floor is exactly zero. The first six were then re-run **on a
  second vendor**, an NVIDIA RTX 4050, alongside the eight `SolveShapes`
  variants, and stayed bit-identical on Viscosity Med, Surface Tension Med,
  Triangle Collision and Shape Collision over 60 frames. `SolveVelocities` was
  additionally isolated on Rigid8, Melting and Plastic Coarse for 60 frames each
  and was bit-identical in all five channels there too. This is the strongest
  evidence available anywhere in this tree.
- **Structural only** (6): `g_Flex_ContinuousShockPropagation`,
  `g_Flex_CreateGrid`, `g_Flex_Predict`, `g_Flex_SolveSprings`,
  `g_Flex_SolveSpringsNV`, `g_Flex_UpdateDiffuseParticles`. These passed all
  five audit axes *and* an exact opcode histogram, so their entire residual is
  register naming (`CreateGrid`, `SolveSprings`, `SolveSpringsNV`,
  `UpdateDiffuseParticles`, plus one commutative `mul` order in the last), one
  `rsq` scheduled two instructions later (`Predict`), or one `ld_raw` moved and
  one `add` reversed (`ContinuousShockPropagation`). They were accepted without
  a runtime check because nothing was left that could carry a semantic
  difference — but note that `CalculateAnisotropy` also had an exact opcode
  histogram and was still wrong, so this tier rests on the constant-bit sweep
  having come back clean, not on the histogram alone.

The two groups that were `Partial` are no longer so, and both have since gone
all the way to runtime bit-identical. The control-flow *shape* fixes that closed
`Partial` were: `SdfContact` performing the contact store itself rather than
returning a hit flag (`CollideShapes`), and the triangle-shape gate written as
three nested `if`s rather than one `&&` chain (`CollideTriangles`). Neither fix
was sufficient on its own — see the contacts section below for the two semantic
bugs that were still hiding behind matching control flow.

What remains in the `Equivalent` group, largest first, and why:

- The `SolveShapes` family (34 to 62 lines after register normalisation, down
  from 42 to 70 once `QuatMul` and `NormalizeQuat` were rewritten as flat
  chains). What is left is entirely SIMD lane packing: our build computes each
  quaternion component with its own scalar `mul`/`mad` chain where the shipped
  blob packs two or three components into each instruction; ours emits a negate
  modifier where the shipped blob multiplies by a `±1.0` literal; ours folds a
  duplicated `t7` load of the same index into one; and in the `*NV` variants it
  hoists the lane split out of the two inlined reductions where the shipped blob
  recomputes `and l(31)` / `ishr l(5)` at each use. This is a property of the
  source, not of FXC's version — both compilers emit these same bytes from it.
  Each was checked instruction by instruction: every
  per-component arithmetic chain now matches the shipped one in both operand
  order and fusion points.
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
- `CalculateVorticity` (small). Two `ine r, r, l(0)` that 10.1 folds away; both
  feed only an `if_z`.

For the record, the groups that used to be listed here and have since been
promoted to runtime bit-identical, with what it took: `CollideShapes` (231 after
register normalisation, still 207 today — the textual distance barely moved
while the behaviour went from wrong to exact), `CollideTriangles` (122),
`CollideParticles` (20), `TransformShapeBounds` (15), `SolveVelocities` (7,
promoted without any source change once it was isolated on NVIDIA),
`CalculateAnisotropy` (2) and `SmoothPositions` (4). That `CollideShapes` sits
at 207 differing lines and is nonetheless bit-identical at runtime is the single
most useful calibration point in this document: **textual distance from the
shipped disassembly and behavioural correctness are close to independent.** A
large diff is not evidence of a bug, and a small one is not evidence of
correctness. `SolveVelocities` is the mirror image: 7 differing lines, and the 7
turned out to be nothing. The corollary is that the *size* of a residual tells
you almost nothing about whether it hides a defect — only a runtime differential
test does.

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

All five axes, plus the full opcode histogram, match on the six structurally
`Verified` groups. Across the 23 groups that carried `Equivalent` when this
audit was written, axes 1, 2 and 4 match everywhere. The known and accepted
exceptions on the other two axes, each inspected individually, are listed below
— and it is worth saying plainly that this list was complete, correct as far as
it went, and still missed three real bugs, because none of the three perturbed
any of the five axes:

- **Redundant-load elimination.** The `SolveShapes` family loads
  `localNormals[entry]` (`t7`) twice in the shipped code and once in ours
  (`ld_structured_indexable` 18 vs 17, or 21 vs 20). `t7` is an SRV, read-only
  for the whole dispatch, and both loads use the same index, so the values are
  identical.
- **Scalar versus vector groupshared read-modify-write.** See the
  `CalculateInflatableVolume` note above: the same 12 bytes, the same addition,
  one thread, same barriers.
- **`cross()` packing.** The shipped blobs emit a cross product as a two-wide
  `mul`/`mad` pair plus a scalar `mul`/`mad`; our sources compile to a
  three-wide pack. Two extra instructions per site, identical per-component
  arithmetic. Originally read as an FXC 6.3 versus 10.1 difference, which is
  disproved — it is a source difference nobody has yet found the formulation
  for. This accounts for
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

## Runtime verification

The structural audit above is not a proof, so the 23 `Equivalent` groups were
also tested at runtime: the shipped `src/dxbc/g_Flex_<Entry>.txt` blob is
replaced with one compiled from the recovered source (`fxc -Fo`), `NvFlexRev` is
rebuilt, and the demo's playback facility compares particle positions frame by
frame against a baseline recorded with the original blobs. `git checkout --
src/dxbc` restores the originals afterwards.

    # A = original blobs, write mode; C = identical second run; B = one blob swapped
    demo --dev=1 --graphics=1 --vsync=0 --windowed=640x480 --disabletweak          "--scene=<Name>" --playback-mode=write --playback-range=0,30

Two things make this harder than it looks, and both change the answer:

1. **Do not use `--playback-mode=read`.** Its comparison uses `eps = 1e-3`, so
   what it reports is the frame at which a difference has *grown* past 1e-3, not
   the frame at which one appeared. Record both sides in `write` mode and diff
   the buffers offline at full precision instead.
2. **The simulation amplifies.** With identical binaries, Inflatables
   self-diverges from 1e-11 at frame 7 to 6.6e-4 by frame 53 — roughly 0.4
   orders of magnitude per frame. A single-ULP difference seeded at frame 0
   therefore reaches 1e-3 somewhere around frame 10-40 with no logic error at
   all. Always record a second baseline run (`d_AC`) as the noise floor.
   Shape Collision, Triangle Collision, Rigid8, Plastic Stack and DamBreak 5cm
   are bit-deterministic (`d_AC` is exactly 0); Inflatables and Flag Cloth are
   not.

With the per-frame curves in hand the two signatures separate cleanly, with no
ambiguous cases:

- **Rounding class** — first nonzero delta at frame 0 at about one ULP
  (2^-24 = 5.96e-08 relative), then smooth monotone growth. This is what
  `refactoringAllowed` mul/add fusion produces, and it upholds `Equivalent`.
- **Logic difference** — positions bit-identical for many frames, then a
  discontinuous jump straight to a percent-level delta. Re-association cannot
  produce exactly zero error for 26 frames and then 1e-2; a discrete decision is
  being taken differently.

The relative magnitude alone is **not** a sufficient discriminator, and reading
it as one is how the `SolveShapes` reassociation defect survived a full round.
A first-frame delta of 1.05e-07 was recorded as "rounding class" when it was in
fact a wrong summation tree. What actually separates the two is the **frame-0
ULP histogram** — how many values moved and by how much — which the
`scratchpad/runtime/ulp.py` helper prints:

- a reassociation in a hot path is *loud*. Swapping the last two accumulation
  terms of `NormalizeQuat` — the smallest possible reassociation, one level —
  moves 11630 of 192000 floats (6.06%) within frame 0 on Rigid8, with a tail to
  85 ulp.
- FXC lane packing is *quiet*. The non-NV `SolveShapes`, whose only remaining
  residual is packing, moves 8 of 192000 (0.004%), every one of them by exactly
  1 ulp.

Two orders of magnitude separate them. Measure the histogram before calling
anything "rounding".

Results:

| Group | Outcome |
| --- | --- |
| `CollideParticles`, `TransformShapeBounds` | Bit-identical on Rigid8 and Shape Collision, both zero-noise scenes. Each was first proved live with a no-op probe. |
| `SolveInflatableVolume`, `CalculateInflatableVolume`, `CalculateInflatableVolumeAMD` | Indistinguishable from the Inflatables noise floor, which is not zero (FP atomics). Cannot be bit-verified on any scene. The plain variant was reached with `--extensions=0`. |
| `CalculateVorticity`, `UpdateTriangles` | Rounding class; first delta at frame 0 at 6.2e-08 to 2.1e-07 relative. `Equivalent` upheld. |
| `SolveVelocities` | Was recorded here as rounding class at 6.2e-08. Re-tested in isolation on NVIDIA over 60 frames on Rigid8, Melting and Plastic Coarse: **bit-identical in all five channels**, with no source change. The earlier reading came from a run where another shader in the same batch carried the difference. Now `Verified`. |
| `SolveShapes`, `SolveShapesPlasticDeformation` and their six `*NV` variants | Was recorded as rounding class at 1.05e-07. That was wrong: a real reassociation defect in `QuatMul` was hiding at exactly that magnitude. Fixed; see below. Still not bit-identical, now at the FXC-lane-packing floor. |
| `CollideTriangles` | **Was** a logic difference; cause found and fixed (cross operand order in `SegmentIntersectsTriangle`). Now bit-identical over 60 frames. |
| `CollideShapes` | **Was** a logic difference; two defects found and fixed (convex plane offset, and the sweep base point in four places). Now bit-identical over 60 frames. |
| 6 `SolveShapes*NV` variants | **Now exercised.** All six run on the RTX 4050 via `--adapter=1`; see [Selecting the GPU](#selecting-the-gpu). Running them is what exposed the `QuatMul` defect. |
| `SolveInflatableVolumeNV`, `CalculateInflatableVolumeNV`, `UpdateTrianglesNV` | Still not exercised. Reachable on NVIDIA now, but no scene in this survey dispatches them on the tested paths. |
| `CalculateInflatableVolume` (plain) | Not exercised — the AMD variant is selected on this device. |
| `CalculateAnisotropy`, `SmoothPositions` | Bit-identical after the harness was extended to record the smoothed positions and the anisotropy buffers, and after a real defect was fixed in `CalculateAnisotropy`. See [Recording the render-only outputs](#recording-the-render-only-outputs). |

Both collision groups are now fixed; the diagnosis is in the next section. The
blob-size argument that was pursued for a while is recorded here because it was
a dead end worth not repeating: the recompiled `CollideShapes` blob is 4248
bytes smaller than the shipped one, but that is the 179-instruction gap already
measured above at roughly 24 bytes per instruction, 159 of them `mov`s that FXC
10.1 coalesces away. It was never evidence of missing code. Neither was the
`min`/`max` ordering around the clamps, which was the standing hypothesis for
two rounds and was wrong.

### Contacts are the right observable for the collision shaders

Positions only show the *effect* of a contact, several solver stages downstream
and after chaos has had a frame to work. `NvFlexGetContacts` exposes the direct
output of `CollideShapes`/`CollideTriangles`, and `--playback-contacts` records
per-particle contact counts, planes and velocities alongside the positions. The
contact velocity's `.w` carries the shape index, so a differing contact can be
mapped back to the shape and hence to the contact function that produced it.

This is what turned a six-month-old "logic difference, cause unknown" into two
located bugs in one pass. The distinction it draws is:

- **different contact COUNT** — a contact is being generated or dropped, so a
  predicate is flipping;
- **same count, different PLANE** — the contact is found but its normal or
  offset is computed differently.

`CollideTriangles` was the first kind. At frame 18 of Triangle Collision, one
frame before positions moved at all, 57 particles had count 1 on the shipped
side and 0 on ours, every one of them carrying the same triangle plane. The
cause was in `SegmentIntersectsTriangle`: the recovered source computed
`n0 = cross(cv, d)` where the DXBC puts the segment delta first, `cross(d, cv)`.
Reversed, `s0` and `s1` invert while `s2` does not, so the three signed volumes
no longer share a sign and the test can essentially never fire. Tunneling
contacts were silently dropped, which stays invisible until something actually
tunnels. With the operand order corrected the shader is bit-identical over 60
frames on a scene whose noise floor is exactly zero.

`CollideShapes` was the second kind: same count, different plane, one particle
at a time, and it took two fixes.

The first was narrow. `ConvexContact` stored the margin-adjusted plane offset
where the DXBC keeps the raw `invLength * p.w`; the adjusted one is used only
for the ray clip. Confirmed by the stored `w` moving by exactly
`kCollisionDistance + kCollisionThreshold`.

The second was systematic, and worth stating plainly because it is invisible to
any amount of staring at the instruction stream. **The contact functions base
the sweep at `localStart` and march toward `localEnd`; the recovered sources
based it at `localEnd`.** Both parametrise the same segment, so the clip test
`enter < exit` agrees and the arithmetic decodes instruction for instruction —
but `t` is mirrored, and the "closest feature" is then chosen relative to the
wrong endpoint. Whenever the particle had moved, a different convex plane, box
face or capsule axis point was selected.

The tell was in the register allocation, not the opcodes: in the shipped blob
the ray base point and the `localParticleEnd` handed to `StoreContact` live in
*different* registers, and in ours they were the same register. Four call sites
were affected — `IntersectSegmentAabb`, the `BoxContact` face selection,
`CapsuleContact`'s axis projection, and `ConvexContact`'s plane distance.

With all of it applied, Shape Collision, Rigid8 and Triangle Collision are
bit-identical over 60 frames on every channel. Shape Collision exercises all six
shape types -- sphere, capsule, box, convex mesh, triangle mesh and SDF -- so the
sphere and SDF paths are covered by the same result.

### Scenes are not all deterministic, and the noise floor must be measured per scene

Three of the scenes used here are not reproducible run to run, because the
shaders that feed them accumulate with floating-point atomics
(`InterlockedAddFp32`), whose ordering varies:

| Scene | Noise floor (same binary, two runs) |
| --- | --- |
| Triangle Collision | exactly zero, all channels, 60 frames |
| Rigid8, Shape Collision, Viscosity Med, Surface Tension High, Rock Pool | exactly zero, 30-40 frames |
| Inflatables | diverges at frame 7, 2.9e-11 growing to 3e-05 by frame 17 |
| Flag Cloth | diverges at frame 24, 5.8e-11 growing to 5e-05 by frame 55 |

Re-measured on the RTX 4050, 60 frames, all five channels, two runs per scene.
The floor is **not** a property of the scene alone — it has to be re-established
per device, and one scene that is deterministic on AMD is not on NVIDIA:

| Scene | Noise floor on RTX 4050 |
| --- | --- |
| Rigid8, Melting, Plastic Coarse, Plastic Very Coarse | exactly zero |
| Viscosity Med, Surface Tension Med, Triangle Collision, Shape Collision | exactly zero |
| Plastic Stack | exactly zero |
| Rigid2 | diverges at frame 59, 3.6e-07 — usable only below ~55 frames |

Measure this before interpreting any result. The inflatable group
(`SolveInflatableVolume`, `CalculateInflatableVolume`, `CalculateInflatableVolumeAMD`)
produces a difference whose onset frame and magnitude are *indistinguishable*
from the scene's own noise floor, which is the strongest statement obtainable
there -- they cannot be bit-verified on any scene, by construction. An earlier
round recorded this group as "bit-identical"; that was measured without a noise
floor and is withdrawn. Flag Cloth is likewise unusable for judging
`CollideTriangles`; Triangle Collision is the scene to use.

### Constants are invisible to every disassembly comparison

FXC prints float literals to six decimals and 3Dmigoto to eight, so two
different constants can disassemble to the same text. `1e-9` and `1e-15` both
print as `l(0.000000)`. `CalculateAnisotropy` was reconstructed with a Jacobi
convergence threshold of `1e-9` where the shipped blob has `1e-15`
(`0x3089705F` versus `0x26901D7D`), and **no** text-level check could see it:
the two disassemblies agreed instruction for instruction, operand for operand,
including the declaration block and `dcl_temps`.

The tell was behavioural, not textual. Two reconstructions with very different
register allocation and scheduling produced bit-identical output *to each other*
while both differed from the shipped blob in exactly the same way. Scheduling
noise cannot do that; only a semantic difference can.

Compare the constant bits directly, from the `SHEX` chunk of both blobs —
`scratchpad/constsweep.py` does this for every entry in `Shaders.cfg`. Sweeping
all 82 entries found this as the only value-level mismatch in the tree. Ten
shaders differ in the *count* of a shared constant (`1.0`, `-1.0`, `0.3333`),
which is instruction scheduling, not a different number. Run this check on any
shader before calling it `Exact` or `Verified`: byte-identical disassembly does
not imply byte-identical constants.

A too-loose threshold is invisible to inspection for a second reason: it is
correct on well-conditioned input and only diverges when the sweep would have
taken another rotation. The symptom was that eigenvalues agreed to ~7e-07
relative while ~20% of eigenvectors were completely different — a discrete
decision inside one dispatch, not chaos across frames.

**After the fix, the eigenvector difference is zero.** `CalculateAnisotropy`
was re-tested in isolation (its blob swapped in alone, so nothing upstream could
contaminate the result) on the RTX 4050 over 60 frames on Melting, Viscosity Med
and Surface Tension Med. All three anisotropy channels are bit-identical in
every frame, and so are `positions` and `smoothPositions`. The channels are
live, not vacuous: 206666 of 262144 floats nonzero on Viscosity Med, 196608 of
327680 on Surface Tension Med, 33180 of 33180 on Melting. There is no residual
eigenvector disagreement of any size, degenerate-basis or otherwise — the
~20% figure above describes the state *before* the `1e-15` threshold was
restored.

One caveat when reading a combined run: on Melting the anisotropy channels
*do* diverge when the whole candidate set is swapped in at once. That is
downstream, not `CalculateAnisotropy` — Melting dispatches `SolveShapes128NV`,
whose positions differ from frame 5, and the anisotropy of a different point
cloud is legitimately different. Isolating the shader is what separates the
two, and it is why single-shader runs are worth their cost.

### Recording the render-only outputs

`SmoothPositions` and `CalculateAnisotropy` write `mSmoothPositionsOriginal`
and the anisotropy buffers, which `NvFlexGetParticles` never returns, and
`mSortedPositions`, which is rewritten from `mPositions` at the top of every
substep. They are therefore invisible to a positions-only harness. The demo
already reads both back (`NvFlexGetSmoothParticles` / `NvFlexGetAnisotropy` in
`UpdateScene`), but only under `!g_interop && g_drawEllipsoids`.

`PlaybackContext` now records five channels per frame — `positions`,
`smoothPositions`, `anisotropy1..3` — behind a `FPB2` magic, and `UpdateScene`
fetches the extra buffers whenever playback is active, independent of the
render flags. Legacy positions-only archives still load; the reader dispatches
on the magic. Every channel is clamped to the live particle count, because the
four render buffers are allocated at `maxParticles` and their tails are never
written.

Two things this makes possible, both of which mattered:

- A **liveness** column. `anisotropy1..3` are zero on a scene with no fluid, and
  `positions` is zero on a scene that has not emitted yet — on `Adhesion` both
  are all-zero, so a "no difference" verdict there is vacuous. The differ prints
  nonzero counts per channel and flags this.
- A **noise floor of exactly zero**. Neither shader feeds back into the
  simulation, so unlike the position-based test there is no Lyapunov
  amplification: any difference is the shader's own. Confirmed empirically — a
  no-op `SmoothPositions` leaves `positions` bit-identical for 40 frames while
  moving `smoothPositions` by 2.63.

Verified bit-identical over `Viscosity Med` (40 frames), `Surface Tension High`
and `Rock Pool` (30 frames each), all five channels, against a baseline noise
floor of zero.

The nine `*NV` variants used to be unreachable on any GPU: `src/Library.cpp`
hard-coded `mSMCount = -1`, which forced `enableExtensions` false on NVIDIA and
zeroed `mIsSHFLSupported` / `mIsFP32ATOMICSupported`; on AMD the NV branches are
unreachable by vendor id anyway. Both device backends already queried the count
through `NvAPI_GPU_GetShaderSubPipeCount` and stored it in `m_SMcount`, but never
exposed it. It is now carried on `FlexDeviceCapabilities::smCount` and read by
`Library.cpp`, so the NV paths are selected on NVIDIA hardware. Combined with
`--adapter=N` below, the six `SolveShapes*NV` variants have since been run and
are no longer unexercised; `SolveInflatableVolumeNV`,
`CalculateInflatableVolumeNV` and `UpdateTrianglesNV` still are.

### Selecting the GPU

`Library::Init` refuses a null `renderDevice`, so Flex never creates an adapter
of its own — it is always handed the demo's D3D device. `NvFlexInitDesc::deviceIndex`
is therefore dead in this implementation (nothing in `src/` reads it), and
`-device=N` cannot move the solver. The adapter is decided where the *renderer*
is created, which used to be a hardcoded `AppGraphCtxCreate(0)` in
`demoContextD3D11.cpp` and `demoContextD3D12.cpp`.

`--adapter=N` now drives that, through `RenderInitOptions::adapterIndex`, for
both the D3D11 and D3D12 back ends. Every run prints the full adapter list and
marks the selection, and `NvFlexGetDeviceName` confirms what Flex actually got:

    demo --dev=1 --graphics=1 --adapter=1 --scene="Rigid8" ...
      adapter 0: AMD Radeon 780M Graphics (vendor 0x1002, 418 MB dedicated)
      adapter 1: NVIDIA GeForce RTX 4050 Laptop GPU (vendor 0x10DE, 5923 MB dedicated)   <= selected
      adapter 2: Microsoft Basic Render Driver (vendor 0x1414, 0 MB dedicated)
    Compute Device: NVIDIA GeForce RTX 4050 Laptop GPU

Interop stays enabled because render and compute are the same device. Pair it
with `--extensions=0` to force the non-NV kernels on an NVIDIA part, which is
how the plain `SolveShapes` was isolated from `SolveShapesNV`.

### Reaching every `SolveShapes` variant

`Solver::SolveShapes` picks among six kernels on two predicates: whether the
scene supplies plastic thresholds and creeps, and `avgWorkload = mNumRigidIndices
/ mNumRigids` bucketed at `<=32`, `33..127`, `>=128`. The stock scenes cover four
of the six; the two coarse plastic buckets were unreachable, so `Plastic Coarse`
and `Plastic Very Coarse` were added to `main.cpp` (a plastic bunny at
`mClusterSpacing` 3.0 and 8.0). Measured coverage:

| Kernel | Scene | rigids | indices | avgWorkload |
| --- | --- | --- | --- | --- |
| `SolveShapes32NV` | Rigid2, Rigid4, Bananas, Game Mesh Rigid | 1000 | 8000 | 8 |
| `SolveShapesNV` | Rigid8, Soft Bunny, Soft Teapot | 1000 | 48000 | 48 |
| `SolveShapes128NV` | Melting | 3 | 8295 | 2765 |
| `SolveShapesPlasticDeformation32NV` | Plastic Bunnies, Plastic Stack | 1176 | 20662 | 17 |
| `SolveShapesPlasticDeformationNV` | **Plastic Coarse** | 70 | 6648 | 94 |
| `SolveShapesPlasticDeformation128NV` | **Plastic Very Coarse** | 10 | 6618 | 661 |

`SolveShapes` and `SolveShapesPlasticDeformation` (non-NV) are reached by adding
`--extensions=0` to any of the above.

### The audit normaliser hides every declaration, including two that are semantic

`cmp.sh` strips all `dcl_*` lines before diffing, because bindings legitimately
differ between the shipped blob and ours. Two of those lines are not bindings:

- `dcl_thread_group` is the `[numthreads]` of the kernel. Get it wrong and the
  reduction reads lanes that were never written.
- `dcl_tgsm` is the groupshared allocation the reduction accumulates into.

Neither would show up anywhere else in the structural audit, and neither is a
constant, so the constant-bit sweep cannot see them either. Checked explicitly
for all eight `SolveShapes` variants:

| | shipped | ours |
| --- | --- | --- |
| `SolveShapes`, `SolveShapesNV`, both `PlasticDeformation` 64-wide forms | `64,1,1` | `64,1,1` |
| `SolveShapes32NV`, `SolveShapesPlasticDeformation32NV` | `32,1,1` | `32,1,1` |
| `SolveShapes128NV`, `SolveShapesPlasticDeformation128NV` | `128,1,1` | `128,1,1` |
| `dcl_tgsm` count, plain variants | 5 | 5 |
| `dcl_tgsm` count, plastic variants | 7 | 7 |

Comparing the complete declaration block, the only difference anywhere in the
eight is `dcl_temps 51` against our `52` on `SolveShapesNV` and
`SolveShapes128NV` — the temporary-register high-water mark, which is register
allocation. UAV, SRV, constant-buffer and `dcl_globalFlags` declarations are
identical everywhere. Re-run this check before trusting `cmp.sh` on any shader
with a groupshared reduction.

### Which kernel is actually live, proved rather than assumed

A blob swap replaces bytecode only; the variant is chosen by `Solver::
SolveShapes` in C++, which is the same code on both sides of every A/B. So the
two sides always dispatch the same entry point by construction. What that does
*not* establish is which entry point, and a differential test against a kernel
that never runs reports "no difference" for the wrong reason.

Established by stubbing one blob with a no-op and checking whether the
simulation moves:

| Stubbed | Scene | Flags | Result | Conclusion |
| --- | --- | --- | --- | --- |
| `SolveShapes` | Rigid8 | `--extensions=0` | diverges 2.6e-03 at frame 0 | non-NV kernel is live |
| `SolveShapes` | Rigid8 | `--extensions=1` | bit-identical, 8 frames | non-NV kernel is *not* used |
| `SolveShapesNV` | Rigid8 | `--extensions=1` | diverges 2.6e-03 at frame 0 | NV kernel is live |
| `SolveShapesNV` | Rigid8 | `--extensions=0` | bit-identical, 8 frames | NV kernel is *not* used |
| `SolveShapesNV` | Melting | `--extensions=1` | bit-identical, 8 frames | Melting is the 128 bucket |
| `SolveShapes128NV` | Melting | `--extensions=1` | diverges 4.0e-03 at frame 0 | 128 kernel is live |
| `SolveShapes128NV` | Rigid8 | `--extensions=1` | bit-identical, 8 frames | Rigid8 is the 64 bucket |
| `SolveShapes128NV` | Melting | `--extensions=0` | bit-identical, 8 frames | no NV kernel on the non-NV path |

The pattern is exactly complementary in both directions, so `--extensions=0`
really does disable the NV path rather than merely changing a flag, and the
avgWorkload bucketing selects what the table above claims. Note that a
`--extensions=0` run must be compared against a `--extensions=0` baseline; the
first attempt at the last row compared against an `--extensions=1` capture and
produced a spurious difference.

### How much do NVIDIA's own kernels disagree with each other?

This is the most useful number for deciding what a residual means. The NV and
non-NV `SolveShapes` kernels compute the same quantity by different reductions.
Both are NVIDIA's shipped bytecode, neither is ours. On Rigid8 at frame 0:

| Comparison | Floats differing of 192000 | Worst |
| --- | --- | --- |
| shipped `SolveShapesNV` vs shipped `SolveShapes` | 91775 (47.8%) | 411 ulp |
| **our** `SolveShapesNV` vs shipped `SolveShapesNV` | 141 (0.073%) | 49 ulp |
| **our** `SolveShapes` vs shipped `SolveShapes` | 8 (0.004%) | 1 ulp |

Our reconstruction differs from the shipped blob by roughly 650x less than two
shipped kernels differ from each other. Whatever tolerance the original design
was built to accept, the remaining residual is far inside it. That is an
argument about *significance*, not about *correctness*, and it does not promote
anything to `Verified` — but it does mean the residual cannot be a defect that
matters to the simulation, only one that matters to bit-exactness.

### FXC 6.3.9600.16384, fetched locally

The shipped blobs were built with the Windows 8.1 SDK compiler. It now lives at
`tools/fxc63/` (gitignored -- Microsoft binaries, fetched, never committed):

| file | version | sha256 |
| --- | --- | --- |
| `fxc.exe` | 6.3.9600.16384 (winblue_rtm.130821-1623) | `1a7fb5609b54f046835e55fe572b712d06d627750f2cffa60b5c4e4292e56420` |
| `d3dcompiler_47.dll` | 6.3.9600.16384 (winblue_rtm.130821-1623) | `0bea1620dd82f5e6be1650fbe84ce819ba9f32f4148308cf1e68c4d825d74937` |

No SDK was installed. Provenance, reproducible: the 8.1 SDK web installer
(`https://go.microsoft.com/fwlink/p/?LinkId=323507`) is a WiX bundle whose
embedded `BurnManifest` lists the `Installers/` payloads. `fxc.exe` is not in
the main SDK MSI -- it is in `Windows Software Development Kit for Windows Store
Apps-x86_en-us.msi`. Querying that MSI's `File`/`Media` tables through
`WindowsInstaller.Installer` (read-only, no install) puts the x64 `fxc.exe` at
sequence 74 and its `d3dcompiler_47.dll` at sequence 32, both inside
`69661e20556b3ca9456b946c2c881ddd.cab`. Downloading that one 9 MB cab and
extracting the two members by their File keys is the whole operation.

Both must sit in the same directory. `fxc.exe` resolves `d3dcompiler_47.dll` by
the normal search order, and `C:\Windows\System32` holds 10.0.19041.7663, which
would silently give 10.x codegen. The check that this is working: any `-Fc`
listing must carry `Generated by Microsoft (R) HLSL Shader Compiler
6.3.9600.16384`, exactly as the shipped `.asm` files do.

### The compiler was never the problem

The previous revision of this document named FXC 6.3 as the one remaining lever
on the `SolveShapes` family, on the reasoning that scalar-versus-packed
component chains and negate-modifier-versus-`mul l(-1.0)` are codegen choices
that differ between 6.3 and 10.1. **That was wrong, and the measurement is
unambiguous.** Compiling every recovered source with both compilers and
comparing the SHEX chunk byte for byte:

    code chunk identical between 6.3 and 10.1 : 66 of 66
    code chunk different                      :  0

Not one shader in this tree compiles differently under the two compilers. FXC
10.1 was never introducing anything, and no result obtained with it needs
revisiting. Every difference that remains against the shipped blobs is a
difference in **our source**, not in the toolchain -- which is better news than
the alternative, because a source difference is reachable and a compiler
difference would not have been.

### Compare bytes, not text

With the shipping compiler in hand, the disassembly text can be dropped from the
comparison entirely. The SHEX chunk is the executable bytecode; if it matches,
the source reproduces the shader, with nothing left to interpret. This is
strictly stronger than `cmp.sh`, and it costs less.

It also corrects the text comparison in both directions. The nine
`CalculateBounds*` shaders were recorded as *not* exact on a 4-line diff. Those
four lines are `FLT_MAX`: 3Dmigoto and FXC 10.1 print it as
`340282346638528859811704183484516925440.000000`, FXC 6.3 as
`340282346638528860000000000000000000000.000000`. Same bits, different printer.
All nine are byte-identical. Conversely, a text-`Exact` verdict on the BVH and
radix groups was only ever comparing against blobs the tool had resolved by
name, and the naming is not uniform (`g_Flex_`, `g_bvh_`, `g_` + capitalised
entry) -- a resolver bug that silently reported "missing" as "fine".

`scratchpad/bytecmp.py` runs the whole sweep. Current state, all 82 manifest
entries, zero compile failures:

| | count |
| --- | --- |
| full-file byte-identical, container included | 1 (`radixSort2CS`) |
| SHEX chunk byte-identical | 46 |
| **reproduce the shipped bytecode exactly** | **47 of 82** |
| code chunk differs | 35 |

Of the 35, ten produce an instruction stream of exactly the shipped length,
which bounds the residual to operand encoding -- register allocation -- rather
than to a different program. Those are the ones worth attacking first:

| Source | code bytes | differing dwords |
| --- | --- | --- |
| `CreateGrid` | 540 | 2 |
| `SolveSprings`, `SolveSpringsNV` | 2436 | 4 |
| `CalculateAnisotropy` | 6660 | 13 |
| `ContinuousShockPropagation` | 916 | 18 |
| `Predict` | 968 | 22 |
| `SolveInflatableVolume`, `SolveInflatableVolumeNV` | 3420 / 3976 | 24 |
| `UpdateDiffuseParticles` | 2944 | 81 |
| `CollideTriangles` | 16780 | 2175 |
| `ComputeTotalBoundsAMD`, `ComputeTotalBoundsGroupAMD` | 3404 / 3460 | (same length) |

`CreateGrid` is two dwords from exact. The `SolveShapes` family is not in this
list -- it is 60 to 276 bytes short of the shipped stream, so something is still
being expressed with fewer instructions, which is a source question and no
longer a compiler one.

### What the remaining `.hlsl_rev` sources still owe

Eight sources keep the `.hlsl_rev` suffix: `SolveShapes`,
`SolveShapesPlasticDeformation` and their six `*NV` variants. All eight are
`Equivalent`, which means the structural audit found nothing — and the whole
point of the runtime round is that the structural audit found nothing on four
groups that were wrong. Do not read `Equivalent` as "agrees with the shipped
shader". Read it as "no check run so far has distinguished it".

All eight have now **executed on real hardware**, which is new; the previous
revision of this document listed six of them as never having run on any GPU.
Doing so paid immediately: it exposed the `QuatMul` association defect described
under Current Work Status, which every structural axis had passed and which the
constant-bit sweep could not see either, because reassociation changes no
constants.

Current state on an RTX 4050, 60 frames, scenes whose noise floor is exactly
zero (verified by two baseline runs per scene):

| Source | Scene | Frame-0 footprint | First diff |
| --- | --- | --- | --- |
| `SolveShapes` (non-NV) | Rigid8, `--extensions=0` | 8 / 192000 floats, all 1 ulp | frame 0, 6.4e-08 rel |
| `SolveShapesNV` | Rigid8 | 141 / 192000, 90 of them 1 ulp | frame 0, 6.7e-08 rel |
| `SolveShapes128NV` | Melting | — | frame 5, 1.3e-07 rel |
| `SolveShapesPlasticDeformationNV` | Plastic Coarse | — | frame 56, 1.6e-07 rel |
| `SolveShapesPlasticDeformation128NV` | Plastic Very Coarse | — | frame 53, 6.0e-08 rel |

For scale, from the same scene and harness: before the `QuatMul` fix
`SolveShapesNV` moved **1886** floats with a tail to 43 ulp, and one deliberate
single-level reassociation moves **11630**. At 141 and 8, the remaining residual
is two orders of magnitude below a hot-path reassociation.

Why they are still not `Verified`:

**1. Not bit-identical, and the residual has no source-level explanation.**
Every per-component arithmetic chain has been compared against the shipped
disassembly instruction by instruction and matches in operand order and fusion
points. What differs is our build emitting scalar chains where the shipped blob
packs two or three components per instruction, and a negate modifier where it
multiplies by a `±1.0` literal. Both classes are bit-exact in IEEE 754, so on
paper the residual should be zero — and it is not. (This was previously
attributed to FXC 10.1 versus 6.3; that is disproved — both compilers emit the
same bytes from our source, so the packing difference comes from the source.) That gap is unexplained, and an
unexplained gap is exactly what the last four defects looked like before they
were found. It is small, but "small" was also true of the anisotropy threshold.

Two things have since been ruled out as hiding places for it. The declaration
block — `dcl_thread_group`, `dcl_tgsm` and the bindings, none of which the
audit normaliser or the constant sweep can see — matches the shipped blob
exactly on all eight variants, `dcl_temps` aside. And all eight kernels are
confirmed live in the configurations they were tested in, by no-op stubbing in
both directions, so none of the results is a false negative from testing a
kernel that never ran.

**2. Three hypotheses about the residual have already been falsified.** Recorded
so they are not re-run:

- *`dp4` versus the `mul`/`add`/`mad` chain.* Rewriting `NormalizeQuat` to emit
  the shipped chain removed the `dp4`, but a build differing **only** in that
  respect is bit-identical to one using `dot(q, q)` — zero floats differ over 60
  frames. The `dp4` never contributed anything; the entire improvement came from
  `QuatMul`. The chain form is kept anyway, because matching the shipped
  disassembly is worth more than the one-line source.
- *FP-atomic ordering.* `AccumulateDelta` uses `NvInterlockedAddFp32`, whose
  accumulation order is scheduling-dependent, which looked like a complete
  explanation. It is not: two blobs differing only in scheduling (the three
  `NvShflDown` calls reordered, per-component arithmetic untouched) produce
  bit-identical output over 60 frames. Atomic order is stable here.
- *Reduction tree shape.* The shuffle deltas were briefly misread as `16..1` in
  the shipped blob against `1..16` in ours. They are `1,2,4,8,16` in both.

**3. The `1.0` / `-1.0` constant count delta is explained, and is inert.** The
sweep reports the shipped blobs carrying 19-21 instances of `1.0` and 5-6 of
`-1.0` against our 16-18 and 2-3. This is `RotateBasis`: 6.3 folds the cross
against a literal basis vector into a masked `mul r9.xy, r2.zxzz, l(-1.0, 1.0,
0, 0)` where 10.1 uses a negate source modifier. Multiplication by `±1.0` and the
negate modifier agree bit-for-bit on every finite value, on both zeroes and on
infinities. Earlier revisions flagged this as the last open structural
discrepancy; it is closed, and it is not the residual.

What would promote them: find the source formulation that emits the missing
instructions. The compiler has been eliminated as an explanation — 6.3 and 10.1
produce byte-identical code for every shader here, so the packing differences
are ours, not the toolchain's. Byte comparison now puts a hard number on the
gap: the eight are 60 to 276 bytes *shorter* than the shipped instruction
stream, so ours is genuinely expressing something in fewer instructions rather
than merely arranging it differently. That is a concrete, bounded target, and
`scratchpad/bytecmp.py` measures progress against it directly without any
disassembly-text interpretation.

Until then these eight stay `Equivalent`. The honest summary is that they are
far closer than they were, that nothing known can distinguish them from the
shipped kernels at a magnitude the simulation cares about — the two *shipped*
kernels disagree with each other 650x more strongly than ours disagrees with
either — and that bit-exactness is still unproven.

Behaviour worth knowing, preserved because the DXBC is authoritative:

- `g_Flex_SolveVelocities` ends the sleep clamp with `mov r3.xyz, -r1.xxxx`,
  i.e. the delta is `-velocity.x` broadcast to all three components rather than
  `-velocity`. `SolveVelocities.hlsl` reproduces this with `-velocity.xxx`.
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
| Flex | `g_Flex_CalculateAnisotropy` | `CalculateAnisotropy.hlsl` | Verified |
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
| Flex | `g_Flex_CollideParticles` | `CollideParticles.hlsl` | Verified |
| Flex | `g_Flex_CollideShapes` | `CollideShapes.hlsl` | Verified |
| Flex | `g_Flex_CollideTriangles` | `CollideTriangles.hlsl` | Verified |
| Flex | `g_Flex_CompactDiffuseParticles` | `CompactDiffuseParticles.hlsl` | Exact |
| Flex | `g_Flex_ComputeTriangleBounds` | `ComputeTriangleBounds.hlsl` | Exact |
| Flex | `g_Flex_ContinuousShockPropagation` | `ContinuousShockPropagation.hlsl` | Verified |
| Flex | `g_Flex_CreateDiffuseParticles` | `CreateDiffuseParticles.hlsl` | Exact |
| Flex | `g_Flex_CreateGrid` | `CreateGrid.hlsl` | Verified |
| Flex | `g_Flex_Finalize` | `Finalize.hlsl` | Exact |
| Flex | `g_Flex_NormalizeVertexNormals` | `NormalizeVertexNormals.hlsl` | Exact |
| Flex | `g_Flex_Predict` | `Predict.hlsl` | Verified |
| Flex | `g_Flex_ReorderParticles` | `ReorderParticles.hlsl` | Exact |
| Flex | `g_Flex_SmoothPositions` | `SmoothPositions.hlsl` | Verified |
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
| Flex | `g_Flex_SolveVelocities` | `SolveVelocities.hlsl` | Verified |
| Flex | `g_Flex_SpringsGenerateIndices` | `SpringsGenerateIndices.hlsl` | Exact |
| Flex | `g_Flex_SpringsParticleRange` | `SpringsParticleRange.hlsl` | Exact |
| Flex | `g_Flex_SpringsReorder` | `SpringsReorder.hlsl` | Exact |
| Flex | `g_Flex_TransformShapeBounds` | `TransformShapeBounds.hlsl` | Verified |
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
