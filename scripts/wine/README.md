# Linux-to-Win64 DX11/DX12 workflow

FleX can be cross-built on Linux with LLVM 19, the MSVC 14.44 headers and
libraries, Windows SDK 10.0.26100, and Ninja Multi-Config. Windows shader
tools run through Wine; the C and C++ compiler and linker run natively.

Validate the installed toolchain and configured 64-bit Wine prefix:

```bash
./scripts/wine/bootstrap-toolchain.sh --check
./scripts/wine/check-prefix.sh
```

Configure and build both supported configurations:

```bash
cmake --workflow --preset wine-clang-debug
cmake --workflow --preset wine-clang-release
```

The unified demo selects DX11 by default and DX12 with `--d3d12`:

```bash
./scripts/wine/run-demo.sh --config Debug --rhi d3d11 --dev 1
./scripts/wine/run-demo.sh --config Debug --rhi d3d12 --dev 1
```

For bounded verification, add `--smoke-seconds N`. The launcher treats an
early exit as failure and terminates only the process it started after the
interval:

```bash
./scripts/wine/run-demo.sh --config Debug --rhi d3d11 --dev 1 --smoke-seconds 5
./scripts/wine/run-demo.sh --config Debug --rhi d3d12 --dev 1 --smoke-seconds 5
```

Build products and packaged DLLs are under
`build/wine-clang/bin/{Debug,Release}`. Runtime logs and shader caches are
kept under `.run`. The launcher uses `bin/win64` as the working directory so
the demo's legacy `../../data` asset paths resolve correctly. Set
`NVFLEX_BUILD_ROOT`, `NVFLEX_WINEPREFIX`,
`NVFLEX_RUN_ROOT`, or `NVFLEX_WINE_BIN` to override their defaults.

Run the workflow contract test with:

```bash
./test/TestWineWorkflow.sh
```
