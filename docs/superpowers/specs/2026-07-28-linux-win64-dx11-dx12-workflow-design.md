# Linux-to-Win64 DX11/DX12 Workflow Design

## Goal

Migrate the complete Linux-hosted Win64 Direct3D development workflow from
WaveWorks into FleX. The resulting FleX-owned procedure configures and builds
Debug and Release Windows x64 binaries with native Linux LLVM, generates HLSL
headers with Windows SDK tools through Wine, launches and debugs the demo
through DXVK or vkd3d-proton, and verifies both rendering paths with bounded
startup smoke tests.

## Scope

The workflow covers:

- validation and optional provisioning of the Windows cross-toolchain;
- CMake configure, build, and workflow presets;
- Windows x64 compilation and linking with native LLVM 19;
- FXC and target helper execution through Wine;
- Debug and Release builds of `NvFlexRev`, `NvFlexExt`, and `DemoAppD3D`;
- DX11 and DX12 demo launchers;
- WineDbg/GDB launch configurations and matching VS Code tasks;
- static workflow contract tests;
- Windows artifact inspection; and
- bounded DX11 and DX12 startup smoke tests.

The migration does not add Vulkan support to FleX, provision ISPC or DXC, alter
the shipped binaries in `bin/` or `lib/`, or redesign the demo's renderer
selection.

## Architecture

FleX owns its workflow under `scripts/wine/`, with FleX-specific `NVFLEX_*`
environment variables. The scripts reuse the shared default 64-bit Wine prefix
at `$HOME/.wineprefixes/dev-x64`, but users may select another prefix through
`NVFLEX_WINEPREFIX`. Project downloads and integration files remain below the
ignored `.toolchains/` directory.

The CMake toolchain file at
`cmake/toolchains/windows-clang-cl.cmake` targets
`x86_64-pc-windows-msvc`. Native Linux `clang-cl-19`, `lld-link-19`,
`llvm-lib-19`, `llvm-rc-19`, and `llvm-mt-19` compile and link against the MSVC
14.44 and Windows SDK 10.0.26100 headers and libraries installed in the Wine
prefix. The Windows SDK `fxc.exe` runs through Wine.

FleX's `ShaderTool` is a target executable that participates in the build by
driving FXC and generating headers. Cross-compilation therefore cannot invoke
it directly as a Linux process. CMake assigns a Wine cross-compiling emulator
to `ShaderTool`, and its FXC argument names the FleX FXC wrapper. This keeps the
target helper, FXC, generated headers, and dependency files in the existing
shader pipeline without introducing a second native-host ShaderTool build.

`CMakePresets.json` exposes one `wine-clang` configure preset and Debug and
Release build/workflow presets. All generated build output remains in
`build/wine-clang`.

## Build Compatibility

The cross-build retains the MSVC ABI required by FleX's checked-in import
libraries:

- Windows x64 target triple;
- dynamic multithreaded MSVC runtime;
- `_ITERATOR_DEBUG_LEVEL=0` for configurations consuming packaged libraries;
- Debug-to-Release imported-library mapping where only a release-compatible
  dependency is available; and
- DWARF debug information for Wine/GDB debugging.

The implementation will make only the CMake changes required by the
cross-build. Native Visual Studio builds remain supported by the existing
project commands and output layout.

The demo build stages its project-produced DLLs and checked-in runtime DLLs
next to `NvFlexDemoDebugD3D_win64.exe` or
`NvFlexDemoReleaseD3D_win64.exe`. Runtime checks name each required DLL and
fail before launch when one is unavailable.

## Toolchain and Prefix Workflow

`scripts/wine/common.sh` centralizes the repository root, toolchain root, Wine
prefix, Visual Studio root, Windows SDK root, command resolution, and diagnostic
helpers.

`scripts/wine/bootstrap-toolchain.sh --check` validates:

- CMake, Ninja, LLVM 19, Wine, WinePath, WineDbg, GDB, Git, Python, curl, tar,
  unzip, and the `msvc-wine` integration;
- the pinned MSVC 14.44 and Windows SDK 10.0.26100 layout; and
- an x64 FXC executable.

`--install --accept-msvc-license` may provision missing MSVC and Windows SDK
files with the same explicit Microsoft-license gate used by WaveWorks. It is
idempotent and does not install host packages.

`scripts/wine/check-prefix.sh` requires a win64 prefix, native `d3d11`, `dxgi`,
`d3d12`, and `d3d12core` overrides, and the corresponding DLLs in
`drive_c/windows/system32`. The same prefix can be shared by WaveWorks and FleX
because neither project exports `WINEPREFIX` globally or writes project output
into the prefix.

## Run and Debug Behavior

`scripts/wine/run-demo.sh` accepts:

- `--config Debug|Release`, defaulting to `Debug`;
- `--rhi d3d11|dx11|d3d12|dx12`, defaulting to `d3d11`;
- `--dev 0|1`, defaulting to the reconstructed backend with `1`;
- `--smoke-seconds N` for a bounded startup test;
- `--dry-run`; and
- extra demo arguments after `--`.

DX11 uses the demo's default renderer selection. DX12 adds the existing
`--d3d12` option. Both modes pass `--dev=VALUE`, use a windowed resolution, and
disable vsync unless the caller overrides those values after `--`.

The launcher keeps the FleX repository root as its working directory so the
`data/` tree resolves correctly. It records DXVK and vkd3d-proton logs and
shader caches under `.run/`. Before launch it validates the prefix, executable,
project runtime DLLs, and MSVC runtime DLL availability.

Smoke mode starts the same command, observes it for the requested interval, and
fails if it exits nonzero before the interval or logs an identified backend
startup failure. Reaching the end of the interval causes a normal bounded
termination and counts as startup success. The process is first asked to
terminate, then force-stopped only if it does not exit promptly.

`scripts/wine/debug-server.sh` launches the Debug executable through WineDbg's GDB
remote proxy with matching DX11 or DX12 arguments. VS Code uses `cppdbg`, GDB,
separate backend ports, DWARF symbols, and restricted system-library symbol
loading.

## Error Handling and Safety

- Scripts use strict Bash mode and reject unknown or invalid arguments.
- Every missing tool, file, runtime, or prefix contract names its exact
  requirement and remediation command.
- Provisioning reuses valid existing packages and refuses partial layouts
  rather than silently replacing them.
- No recursive destructive operation targets a home directory, Wine prefix,
  repository root, `Program Files`, `bin/`, or `lib/`.
- The bounded smoke runner records and terminates only the Wine process it
  starts.
- Existing user changes are preserved. Workflow edits are confined to new
  files and narrowly required CMake, ignore, README, and VS Code integration.

## Verification

The procedure is complete only when all of these checks pass:

1. `TestWineWorkflow.sh` validates script syntax, preset JSON, required toolchain
   settings, launcher argument handling, prefix failure behavior, VS Code
   launch contracts, and smoke-run process handling with fakes.
2. `bootstrap-toolchain.sh --check` validates the actual host and Windows
   toolchain.
3. `check-prefix.sh` validates the actual shared win64 DXVK/vkd3d-proton prefix.
4. The `wine-clang-debug` and `wine-clang-release` workflows configure and build
   `NvFlexRev`, `NvFlexExt`, and `DemoAppD3D`.
5. LLVM inspection confirms the produced executable and project DLLs are
   Windows x86-64 PE/COFF artifacts with expected imports.
6. A bounded DX11 smoke launch starts the Debug demo through DXVK without an
   early nonzero exit or backend startup failure.
7. A bounded DX12 smoke launch starts the Debug demo with `--d3d12` through
   vkd3d-proton without an early nonzero exit or backend startup failure.

If the environment cannot provide display or GPU access, the build and static
checks remain useful but do not satisfy the requested end-to-end verification.
The final report must state the exact completed checks and any unmet runtime
condition without treating partial verification as success.
