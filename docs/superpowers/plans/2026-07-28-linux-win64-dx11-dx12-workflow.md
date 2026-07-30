# Linux-to-Win64 DX11/DX12 Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give FleX a complete, verified Linux-hosted workflow for building, running, and debugging its Win64 DX11 and DX12 targets through Wine.

**Architecture:** FleX-local Bash wrappers and a CMake clang-cl toolchain reuse the shared `$HOME/.wineprefixes/dev-x64` MSVC/Windows SDK and DXVK/vkd3d-proton environment. Native LLVM 19 compiles Windows x64 targets, Wine runs FXC and the cross-built shader helper, CMake presets produce Debug and Release artifacts, and bounded launch scripts verify DX11 and DX12 startup.

**Tech Stack:** CMake 3.25+, Ninja Multi-Config, clang-cl/LLD/LLVM 19, MSVC 14.44 ABI, Windows SDK 10.0.26100, Wine, DXVK, vkd3d-proton, Bash, VS Code cppdbg/GDB.

## Global Constraints

- Preserve all pre-existing user changes in the dirty FleX worktree.
- Do not edit shipped binaries or libraries under `bin/` or `lib/`.
- Keep generated output under ignored `build/wine-clang`, `.toolchains`, and `.run`.
- Support only Windows x64 DX11 and DX12; do not add Vulkan, ISPC, or DXC.
- Use `$HOME/.wineprefixes/dev-x64` only as a default selected by project scripts; do not export `WINEPREFIX` globally.
- Use native LLVM 19 for compilation/linking and Windows SDK FXC through Wine.
- Use the dynamic multithreaded MSVC runtime and `_ITERATOR_DEBUG_LEVEL=0`.
- Runtime verification must launch each backend briefly and terminate only the process started by the smoke runner.

---

### Task 1: Executable Workflow Contract

**Files:**
- Create: `test/TestWineWorkflow.sh`
- Create: `test/fakes/fake-wine.sh`

**Interfaces:**
- Consumes: the approved design at `docs/superpowers/specs/2026-07-28-linux-win64-dx11-dx12-workflow-design.md`
- Produces: an executable black-box contract for all files and command-line behavior added by later tasks

- [ ] **Step 1: Write the failing contract test**

Create a strict Bash test that:

```bash
set -euo pipefail
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
```

It must check script executability and `bash -n`, JSON validity, the
`wine-clang` configure/build/workflow presets, Windows x64 toolchain settings,
`NVFLEX_*` naming, absence of `WAVEWORKS_*`, missing-toolchain diagnostics,
fake win64 prefix acceptance, invalid RHI rejection, DX11 omission of
`--d3d12`, DX12 inclusion of `--d3d12`, `--dev=1`, default window/vsync
arguments, bounded-smoke success, early nonzero smoke failure, and two cppdbg
WineDbg launch configurations.

The fake Wine program must support both behaviors without launching Wine:

```bash
case "${FAKE_WINE_MODE:-timeout}" in
    timeout) trap 'exit 0' TERM INT; while :; do sleep 1; done ;;
    fail) exit "${FAKE_WINE_EXIT_CODE:-7}" ;;
esac
```

- [ ] **Step 2: Run the contract and verify it fails**

Run:

```bash
./test/TestWineWorkflow.sh
```

Expected: failure naming the first missing `scripts/wine` script or
`CMakePresets.json`.

- [ ] **Step 3: Commit the test contract**

```bash
git add test/TestWineWorkflow.sh test/fakes/fake-wine.sh
git commit -m "Test FleX Wine workflow"
```

### Task 2: FleX Toolchain and Presets

**Files:**
- Create: `scripts/wine/common.sh`
- Create: `scripts/wine/bootstrap-toolchain.sh`
- Create: `scripts/wine/clang-cl.sh`
- Create: `scripts/wine/lld-link.sh`
- Create: `scripts/wine/llvm-lib.sh`
- Create: `scripts/wine/llvm-mt.sh`
- Create: `scripts/wine/llvm-rc.sh`
- Create: `scripts/wine/fxc.sh`
- Create: `scripts/wine/wine-shader-tool.sh`
- Create: `cmake/toolchains/windows-clang-cl.cmake`
- Create: `CMakePresets.json`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `$NVFLEX_WINEPREFIX`, `$NVFLEX_TOOLCHAIN_ROOT`, optional individual tool overrides, MSVC 14.44, and Windows SDK 10.0.26100
- Produces: `wine-clang`, `wine-clang-debug`, and `wine-clang-release`; compiler, linker, librarian, resource, manifest, FXC, and shader-helper entry points

- [ ] **Step 1: Implement centralized paths and native LLVM wrappers**

`common.sh` must define `nvflex_repo_root`, `nvflex_toolchain_root`,
`nvflex_wineprefix`, `nvflex_vs_root`, `nvflex_windows_sdk_root`,
`nvflex_activate_msvc_environment`, `nvflex_find_command`,
`nvflex_require_file`, and `nvflex_print_command`.

The compiler wrapper must execute:

```bash
exec "$clang_cl" \
    --driver-mode=cl \
    --target=x86_64-pc-windows-msvc \
    -fms-compatibility-version=19.44 \
    -fuse-ld=lld \
    "$@"
```

The link/archive/resource/manifest wrappers resolve versioned LLVM 19 commands
first and exit with a targeted diagnostic if unavailable.

- [ ] **Step 2: Implement toolchain validation and provisioning**

Port the WaveWorks license-gated `msvc-wine` provisioner with FleX names,
retaining only MSVC, Windows SDK, FXC, and host tools used by this workflow.
`--check` must not mutate external state. `--install` must require
`--accept-msvc-license`.

- [ ] **Step 3: Implement Windows-tool argument translation**

`fxc.sh` converts absolute input/output/include paths with `winepath -w` and
runs SDK FXC under the selected prefix.

`wine-shader-tool.sh` receives the cross-built `ShaderTool.exe`, converts
`--fxc=`, `--depfile=`, and every absolute semicolon-delimited member of
`--options=`, then executes:

```bash
exec env WINEPREFIX="$wineprefix" WINEARCH=win64 WINEDEBUG=-all \
    "$wine_bin" "$shader_tool" "${converted_arguments[@]}"
```

- [ ] **Step 4: Add the CMake toolchain**

Set `CMAKE_SYSTEM_NAME Windows`, `CMAKE_SYSTEM_PROCESSOR AMD64`, the six FleX
wrappers, `CMAKE_*_COMPILER_TARGET`, `MultiThreadedDLL`, Debug DWARF flags,
`CMAKE_MAP_IMPORTED_CONFIG_DEBUG Release ""`, `NVFLEX_WINDOWS_CLANG_CROSS=ON`,
`FXC_COMPILER` to SDK FXC, and find-root modes to `NEVER`. Fail configuration
with the bootstrap remediation command when required files are missing.

- [ ] **Step 5: Add configure, build, and workflow presets**

Use `Ninja Multi-Config`, `build/wine-clang`, Debug/Release configurations,
and targets:

```json
["NvFlexRev", "NvFlexExt", "DemoAppD3D"]
```

- [ ] **Step 6: Run the contract**

Run:

```bash
./test/TestWineWorkflow.sh
```

Expected: progress beyond toolchain/preset checks and failure on the missing
prefix/run workflow.

- [ ] **Step 7: Commit the toolchain**

```bash
git add .gitignore CMakePresets.json scripts/wine cmake/toolchains/windows-clang-cl.cmake
git commit -m "Add FleX Win64 cross toolchain"
```

### Task 3: Cross-Build CMake Integration

**Files:**
- Modify: `CMakeLists.txt`
- Modify: `cmake/ShaderTools.cmake`
- Modify: `demo/CMakeLists.txt`

**Interfaces:**
- Consumes: `NVFLEX_WINDOWS_CLANG_CROSS`, `NVFLEX_SHADER_TOOL_EMULATOR`, and `FXC_COMPILER` from Task 2
- Produces: buildable `NvFlexRev`, `NvFlexExt`, `DemoAppD3D`, generated shader headers, and a complete runtime directory

- [ ] **Step 1: Add cross-build ABI settings without overwriting user changes**

Inside an `if(MSVC)` block, apply `/D_ITERATOR_DEBUG_LEVEL=0`, retain the
dynamic runtime, and select DWARF flags only for
`NVFLEX_WINDOWS_CLANG_CROSS`. Preserve native MSVC behavior.

- [ ] **Step 2: Make ShaderTool executable through Wine**

When cross-building, set:

```cmake
set_property(
    TARGET ShaderTool
    PROPERTY CROSSCOMPILING_EMULATOR "${NVFLEX_SHADER_TOOL_EMULATOR}")
```

Use `$<TARGET_FILE:ShaderTool>` as before. Pass the Windows FXC executable to
the helper. Omit Ninja `DEPFILE` consumption in cross mode because emitted
Windows paths are not valid native Ninja dependency paths; retain the existing
depfile behavior for native Windows builds.

- [ ] **Step 3: Stage required runtime DLLs**

Extend the demo post-build command to copy `NvFlexRev`, `NvFlexExt`, SDL2,
NVTX, AGS, and the selected packaged NvFlex DLL beside the demo. Use CMake
target-file expressions where targets expose locations and explicit existing
paths only for checked-in runtime dependencies.

- [ ] **Step 4: Run configure and the shader build**

Run:

```bash
cmake --preset wine-clang
cmake --build --preset wine-clang-debug --target NvFlexShaders NvFlexExtShaders DemoAppD3DShaders
```

Expected: configuration succeeds and all generated shader headers are produced.

- [ ] **Step 5: Build Debug**

Run:

```bash
cmake --build --preset wine-clang-debug
```

Expected: all three target families link and the Debug runtime directory is
complete.

- [ ] **Step 6: Commit CMake integration**

```bash
git add CMakeLists.txt cmake/ShaderTools.cmake demo/CMakeLists.txt
git commit -m "Build FleX Win64 targets on Linux"
```

### Task 4: Prefix, Run, Smoke, and Debug Workflow

**Files:**
- Create: `scripts/wine/check-prefix.sh`
- Create: `scripts/wine/run-demo.sh`
- Create: `scripts/wine/debug-server.sh`
- Create: `scripts/wine/README.md`
- Modify: `.vscode/tasks.json`
- Modify: `.vscode/launch.json`
- Modify: `.vscode/settings.json`
- Modify: `.gitignore`
- Modify: `README.md`

**Interfaces:**
- Consumes: `build/wine-clang/bin/<Config>/NvFlexDemo<Config>D3D_win64.exe`, a valid win64 prefix, `--rhi`, `--dev`, `--smoke-seconds`, and extra demo arguments
- Produces: deterministic DX11/DX12 commands, `.run` logs/caches, bounded startup status, and WineDbg remote targets

- [ ] **Step 1: Implement prefix validation**

Require `#arch=win64`, native overrides for `d3d11`, `dxgi`, `d3d12`, and
`d3d12core`, and matching DLL files in `system32`.

- [ ] **Step 2: Implement run and bounded-smoke behavior**

Normalize DX aliases, select the configuration-specific executable, validate
runtime DLLs, and construct default demo arguments:

```bash
demo_arguments=("--dev=$dev_mode" "--windowed=1280x720" "--vsync=0")
[[ "$rhi" == d3d12 ]] && demo_arguments+=("--d3d12")
demo_arguments+=("${extra_arguments[@]}")
```

For smoke mode, start the exact command in the background, retain its PID,
poll until the deadline, fail on an early nonzero exit, then send `TERM` and
use `KILL` only for that PID after a short grace period. Inspect the selected
backend log for known initialization failures.

- [ ] **Step 3: Implement the WineDbg server**

Validate port and RHI, use the Debug executable, apply the same DX11/DX12
environment and arguments as the runner, and execute:

```bash
winedbg --gdb --no-start --port "$port" "$executable" "${demo_arguments[@]}"
```

- [ ] **Step 4: Add VS Code integration**

Preserve the existing native Windows launch configuration. Add Wine build,
run, check, and test tasks plus two `cppdbg` configurations named:

```text
Wine Debug: D3D11 (DXVK)
Wine Debug: D3D12 (vkd3d-proton)
```

Use ports 31337 and 31338, `launchCompleteCommand: "None"`, and
`symbolLoadInfo.loadAll: false`.

- [ ] **Step 5: Document the workflow**

Add concise host setup, provision/check, configure/build, run/smoke, and debug
commands to `scripts/wine/README.md`, and link it from the root README without
rewriting unrelated legacy documentation.

- [ ] **Step 6: Run the complete contract**

Run:

```bash
./test/TestWineWorkflow.sh
```

Expected: `FleX Wine workflow contract tests passed.`

- [ ] **Step 7: Commit runtime workflow**

```bash
git add -f .vscode/tasks.json .vscode/launch.json .vscode/settings.json
git add .gitignore README.md scripts/wine test/TestWineWorkflow.sh test/fakes/fake-wine.sh
git commit -m "Add FleX Wine run workflow"
```

### Task 5: End-to-End Verification

**Files:**
- Modify only if verification exposes a workflow defect in files from Tasks 1-4

**Interfaces:**
- Consumes: the complete workflow and actual host/prefix/GPU environment
- Produces: fresh build, artifact, DX11 smoke, and DX12 smoke evidence

- [ ] **Step 1: Validate the actual host and prefix**

Run:

```bash
./scripts/wine/bootstrap-toolchain.sh --check
./scripts/wine/check-prefix.sh
```

Expected: both commands report ready state with the exact selected paths.

- [ ] **Step 2: Build Debug and Release from presets**

Run:

```bash
cmake --workflow --preset wine-clang-debug
cmake --workflow --preset wine-clang-release
```

Expected: both commands exit zero and build all requested targets.

- [ ] **Step 3: Inspect produced artifacts**

Run `llvm-readobj-19 --file-headers --coff-imports` on the Debug and Release
demo executables plus `NvFlexRev.dll` and `NvFlexExt*.dll`. Confirm x86-64
PE/COFF format and expected D3D/runtime imports.

- [ ] **Step 4: Run the bounded DX11 smoke**

Run:

```bash
./scripts/wine/run-demo.sh \
    --config Debug --rhi d3d11 --dev 1 --smoke-seconds 10
```

Expected: the process remains alive through the smoke interval, is terminated
by the runner, and the DXVK log has no initialization failure.

- [ ] **Step 5: Run the bounded DX12 smoke**

Run:

```bash
./scripts/wine/run-demo.sh \
    --config Debug --rhi d3d12 --dev 1 --smoke-seconds 10
```

Expected: the process remains alive through the smoke interval, is terminated
by the runner, and the vkd3d-proton log has no initialization failure.

- [ ] **Step 6: Re-run the full contract and inspect the diff**

Run:

```bash
./test/TestWineWorkflow.sh
git diff --check
git status --short
```

Expected: zero contract failures, no whitespace errors, and only intended
workflow changes in addition to the user's pre-existing modifications.

- [ ] **Step 7: Commit verification fixes if any**

Stage only files changed to correct a verified defect, then:

```bash
git commit -m "Fix FleX Wine verification"
```
