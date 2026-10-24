# Static LLVM for Mesa's llvmpipe

The tiny LLVM that nextbsd-mesa links statically into `libgallium` (nextbsd-toolchain#12; E23 plan step 2,
decision D3). It is built for the NextBSD **target** (amd64 and arm64), from the same pinned
`llvmorg-19.1.7` as the image's clang/lld (`../llvm/source.env`, fetched by `../llvm/fetch-llvm.sh`).
Nothing LLVM ships on its own: the archives only end up inside Mesa's DSOs.

## What is built

`build-llvm-static.sh` (run by `.github/workflows/build-llvm-static.yml`, one job per arch):

- **Host tools:** `llvm-tblgen`/`llvm-min-tblgen` from the same source, with the host compiler.
- **Cross build:** CMake, inside the per-arch toolchain image, with its clang/lld and compat's `continuous` base
  as the sysroot (as nextbsd-contrib builds). Triple `x86_64-unknown-freebsd15.1` / `aarch64-unknown-freebsd15.1`.
  - **Native target only:** `X86` on amd64, `AArch64` on arm64. No AMDGPU (D8).
  - **Static, PIC**, `-ffunction-sections -fdata-sections` (so Mesa's `--gc-sections` drops what it doesn't use),
    Release, no assertions.
  - **RTTI on**, exceptions off, **libc++/libcxxrt** from the sysroot.
  - No zlib, zstd, libxml2, libedit, libffi or libpfm.
- **Only the libraries these components need** (and their dependencies):
  `core bitwriter engine executionengine mcjit orcjit mcdisassembler scalaropts transformutils instcombine
  native coroutines lto`.
  That is Mesa 26.2's module list for llvmpipe with AMD's LLVM path off: the required modules, plus its optional
  `coroutines` and `lto` (on LLVM >= 15, gallivm's `LLVMRunPasses` lives in the Passes library that `lto` brings).
  `orcjit` is extra, so `-Dllvm-orcjit=true` stays possible; its archives are only linked if asked for.
- **`bin/llvm-config`:** an x86_64 Linux program that answers for the NextBSD target. It is upstream's
  `llvm-config.cpp`, compiled for the build host against this cross build's `BuildVariables.inc` and a component
  table trimmed (`llvm-components.py`) to what is shipped. LLVM's own cross-built `llvm-config` is not used: it is
  a FreeBSD binary, and its `NATIVE` twin describes the Linux build (and X86 on arm64). Paths come from where the
  binary sits, so the tree can be unpacked anywhere. The build checks the answers meson and Mesa rely on and
  records them in `BUILD-INFO`.

## Where it lives

A release asset, not the toolchain image: release **`llvm-static-19.1.7`** of nextbsd-toolchain, files
`nextbsd-llvm-static-19.1.7-<arch>.tar.xz` (+ `.sha256`), each unpacking to `llvm-19-nextbsd-<arch>/`
(`bin/llvm-config`, `include/`, `lib/libLLVM*.a`, `BUILD-INFO`).

- It needs compat's base as the sysroot, and compat is built *with* the toolchain image; baking it into the image
  would make the image depend on its own downstream.
- It changes only when the pin or this recipe changes. The image is rebuilt from scratch on every upstream sync.
- The kernel, compat, userland and contrib jobs pull the image and don't need it.

A merge to main that touches the pin or `llvm-static/` republishes the release. PR runs only upload workflow
artifacts. Nothing is dispatched.

## Using it from nextbsd-mesa

Inside the toolchain image, with the same compat sysroot:

```sh
gh release download llvm-static-19.1.7 -R nextbsd/nextbsd-toolchain \
    -p "nextbsd-llvm-static-19.1.7-$T.tar.xz" -p "nextbsd-llvm-static-19.1.7-$T.tar.xz.sha256"
sha256sum -c "nextbsd-llvm-static-19.1.7-$T.tar.xz.sha256"
tar -C /opt -xJf "nextbsd-llvm-static-19.1.7-$T.tar.xz"     # -> /opt/llvm-19-nextbsd-$T
```

In the meson cross file:

```ini
[binaries]
llvm-config = '/opt/llvm-19-nextbsd-amd64/bin/llvm-config'
```

and configure with `-Dllvm=enabled -Dshared-llvm=disabled -Damd-use-llvm=false`. Leave `cpp_rtti` at its default
(`true`, matching `--has-rtti YES`) and `-Dllvm-orcjit` at its default (MCJIT on both arches). Build Mesa's C++ with
the same clang and FreeBSD triple, which uses libc++. Meson then links the archives from `--libs --link-static`
plus `--system-libs`.
