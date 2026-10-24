# Host libraries for Mesa's `mesa_clc`

Mesa's Intel drivers (iris, crocus) compile their internal OpenCL C shaders to SPIR-V while Mesa builds. The
compiler is `mesa_clc`, followed by `vtn_bindgen2`. Both run on the **build host**. `mesa_clc` links clang, LLVM,
SPIRV-LLVM-Translator and SPIRV-Tools (nextbsd-toolchain#11; E23 plan step 1, decision D7). This directory builds
those libraries for the x86_64 Linux build host into `/opt/mesa-clc` in the toolchain image. Nothing here ships, and
nothing is built for the NextBSD target.

## What is built

| Piece | Pin | How |
|---|---|---|
| LLVM + clang | `llvmorg-19.1.7` (`../llvm/source.env`, the cross clang's pin) | shared `libLLVM.so.19.1` and `libclang-cpp.so.19.1`, X86 only, Release, RTTI on, no zlib/zstd/libxml2/libedit/libffi |
| SPIRV-LLVM-Translator | `v19.1.23` | static `libLLVMSPIRVLib.a`, built against the shared LLVM; `LLVMSPIRVLib.pc` version `19.1.7.0` |
| SPIRV-Tools | `v2026.4` (= `vulkan-sdk-1.4.363.0`) | static, PIC, no executables; `SPIRV-Tools.pc` version `2026.4` |
| SPIRV-Headers | `vulkan-sdk-1.4.363.0` | build input of the two above, not installed |

The pins live in `sources.env`. Every download is a GitHub release/tag archive checked against its SHA-256.
LLVM/clang move with `../llvm/source.env`; the translator stays on its `v19.1.x` line, because Mesa requires
`LLVMSPIRVLib >= <LLVM major.minor>, < <major>.<minor+1>`.

- `build-llvm.sh` (stage `mesa-clc-llvm`): LLVM/clang with the static archives and CMake config the translator build
  needs, plus a hand-installed `llvm-config`.
- `build-spirv.sh` (stage `mesa-clc`): translator, then SPIRV-Tools. It then prunes the tree to what Mesa uses
  (`llvm-config`, the two DSOs, headers, clang's resource headers, the SPIR-V archives and `.pc` files) and runs
  `check-clc.cpp`. That program compiles one OpenCL C kernel the way `mesa_clc` does: libclang-cpp, then LLVMSPIRVLib,
  then the SPIRV-Tools linker. The build fails if the kernel does not come out as linked SPIR-V.

Both stages are identical in `Dockerfile.amd64` and `Dockerfile.arm64` (the arm64 image also runs on x86_64). The
`mesa-clc` job of `build-toolchain.yml` keeps them in the GitHub Actions cache (scope `nextbsd-mesa-clc`). The
`llvm` stage and its cache are separate and unaffected. The final image copies `/opt/mesa-clc`. It adds
`/opt/mesa-clc/lib` to the loader path (`/etc/ld.so.conf.d/mesa-clc.conf`), so an installed `mesa_clc` runs without
an rpath.

### `/opt/mesa-clc`

```
bin/llvm-config                  19.1.7, --shared-mode shared, --has-rtti YES
include/{llvm,llvm-c,clang,clang-c,LLVMSPIRVLib,spirv-tools}
lib/libLLVM.so.19.1, libLLVM-19.so, libLLVM.so
lib/libclang-cpp.so.19.1, libclang-cpp.so
lib/clang/19/include             clang resource headers (opencl-c.h, opencl-c-base.h, ...)
lib/libLLVMSPIRVLib.a
lib/libSPIRV-Tools*.a (+ libSPIRV-Tools-shared.so, lib/cmake/SPIRV-Tools*)
lib/pkgconfig/{LLVMSPIRVLib,SPIRV-Tools,SPIRV-Tools-shared}.pc
BUILD-INFO
```

## Using it from nextbsd-mesa

Use a two-step build, which the E23 Mesa audit calls option (b). First build `mesa_clc` and `vtn_bindgen2` natively
from the **same Mesa tarball** as the target build. Then cross-build Mesa with `-Dmesa-clc=system`. The target
build then needs neither clang nor SPIRV-Tools.

1. Native host build (only these two tools). Use a native file:

   ```ini
   [binaries]
   llvm-config = '/opt/mesa-clc/bin/llvm-config'

   [built-in options]
   pkg_config_path = '/opt/mesa-clc/lib/pkgconfig'
   ```

   ```sh
   meson setup build-clc --native-file mesa-clc.ini --prefix "$PWD/clc-host" \
       -Dmesa-clc=enabled -Dinstall-mesa-clc=true \
       -Dllvm=enabled -Dshared-llvm=enabled \
       -Dgallium-drivers= -Dvulkan-drivers= -Dplatforms= \
       -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false \
       -Dgles1=disabled -Dgles2=disabled \
       -Dzlib=disabled -Dexpat=disabled -Dxmlconfig=disabled
   ninja -C build-clc install    # -> clc-host/bin/{mesa_clc,vtn_bindgen2}
   ```

   Leave `cpp_rtti` at its default (`true`, matching `--has-rtti YES`). `-Dshared-llvm=enabled` makes Mesa take
   `libclang-cpp` (and `-lLLVM-19` from `llvm-config`) instead of the static clang libraries, which are not
   installed. `precomp-compiler` stays at `auto` (off): it is for asahi/panfrost/imagination/kosmickrisp, not
   Intel. libclc is not needed (only rusticl and microsoft-clc use it).

2. Cross build for NextBSD. Add to the cross build's native file:

   ```ini
   [binaries]
   mesa_clc = '/path/to/clc-host/bin/mesa_clc'
   vtn_bindgen2 = '/path/to/clc-host/bin/vtn_bindgen2'
   ```

   and configure with `-Dmesa-clc=system` (keep `precomp-compiler` at `auto`). Mesa then runs these for
   `src/intel/shaders` instead of building its own.

The native options above (in particular the `-D...=disabled` set that keeps the native build free of target
dependencies) are what Mesa 26.2.5's `meson.build` asks for. nextbsd-mesa (nextbsd-mesa#1) owns the actual
invocation.
