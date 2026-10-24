#!/bin/sh
# Build the tiny static LLVM that Mesa's llvmpipe links (nextbsd-toolchain#12,
# E23 plan step 2, decision D3) for ONE NextBSD architecture, from the same
# pinned llvmorg-19.1.7 source as the image's clang/lld (llvm/source.env,
# fetched by llvm/fetch-llvm.sh).
#
# Output, in <prefix> (relocatable; the CI packs it as llvm-19-nextbsd-<arch>):
#   lib/libLLVM*.a     static archives for the NextBSD target: only the
#                      libraries the components below pull in, native target
#                      only (X86 on amd64, AArch64 on arm64), PIC,
#                      -ffunction-sections/-fdata-sections, RTTI on, libc++
#   include/llvm{,-c}  the headers, including the generated ones
#   bin/llvm-config    a HOST (x86_64 Linux) llvm-config that answers for the
#                      NextBSD target: upstream llvm-config.cpp compiled
#                      against this cross build's BuildVariables.inc and a
#                      component table trimmed to what is shipped. LLVM's own
#                      cross-built llvm-config is not used: it is a FreeBSD
#                      binary, and its NATIVE twin describes the Linux build
#                      (X86 even for arm64). Paths are derived from where the
#                      binary sits, so the tree can be unpacked anywhere.
#
# Environment (as nextbsd-contrib's build-contrib.sh, inside the toolchain
# image): T=amd64|arm64, SYSROOT=<compat base>, CROSS_BINDIR=<clang/lld dir>.
#
# Usage: build-llvm-static.sh <install-prefix>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../llvm/source.env"

: "${T:?set T to amd64 or arm64}"
: "${SYSROOT:?set SYSROOT to the staged compat base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
prefix=${1:?usage: build-llvm-static.sh <install-prefix>}
work=${LLVM_WORKDIR:-/tmp/llvm-static-work}
jobs=${JOBS:-$(nproc)}

case "$T" in
    amd64) triple=x86_64-unknown-freebsd15.1;  proc=amd64;   target=X86 ;;
    arm64) triple=aarch64-unknown-freebsd15.1; proc=aarch64; target=AArch64 ;;
    *) echo "unknown T=$T" >&2; exit 1 ;;
esac

# What Mesa 26.2's meson asks llvm-config for when llvmpipe is on and AMD's
# LLVM path is off (D6/D8): its required modules (bitwriter engine
# mcdisassembler core executionengine scalaropts transformutils instcombine
# native mcjit) and optional ones (coroutines; lto, which brings the Passes
# library behind LLVMRunPasses, used by gallivm on LLVM >= 15). orcjit is
# added so -Dllvm-orcjit=true stays possible; it costs a few archives that are
# only linked if asked for. No AMDGPU (D8).
COMPONENTS="core bitwriter engine executionengine mcjit orcjit mcdisassembler
scalaropts transformutils instcombine native coroutines lto"

start=$(date +%s)
rm -rf "$work" "$prefix"
"$here/../llvm/fetch-llvm.sh" "$work"
src="$work/llvm-project-$LLVM_VERSION.src"

# --- 1. Host tools ------------------------------------------------------------
# llvm-tblgen/llvm-min-tblgen must be exactly 19.1.7, so they are built here
# from the same source with the host compiler, along with the three host
# libraries the host llvm-config (step 4) links.
cmake -G Ninja -S "$src/llvm" -B "$work/host" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=cc -DCMAKE_CXX_COMPILER=c++ \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF
ninja -C "$work/host" -j"$jobs" \
    llvm-tblgen llvm-min-tblgen LLVMSupport LLVMTargetParser LLVMDemangle

# --- 2. Configure the NextBSD cross build ---------------------------------------
tc="$work/nextbsd-$T.cmake"
cat > "$tc" <<EOF
set(CMAKE_SYSTEM_NAME FreeBSD)
set(CMAKE_SYSTEM_VERSION 15.1)
set(CMAKE_SYSTEM_PROCESSOR $proc)
set(CMAKE_SYSROOT "$SYSROOT")
set(CMAKE_C_COMPILER "$CROSS_BINDIR/clang")
set(CMAKE_CXX_COMPILER "$CROSS_BINDIR/clang++")
set(CMAKE_ASM_COMPILER "$CROSS_BINDIR/clang")
set(CMAKE_C_COMPILER_TARGET $triple)
set(CMAKE_CXX_COMPILER_TARGET $triple)
set(CMAKE_ASM_COMPILER_TARGET $triple)
set(CMAKE_AR "$CROSS_BINDIR/llvm-ar")
set(CMAKE_RANLIB "$CROSS_BINDIR/llvm-ranlib")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# RTTI on: Mesa's cpp_rtti must equal llvm-config --has-rtti, and Mesa's
# default is on. libc++/libcxxrt from the sysroot, the C++ runtime Mesa uses
# with the same clang and a FreeBSD triple. No zlib/zstd/libxml2/libedit:
# nothing llvmpipe needs, and --system-libs stays short.
cmake -G Ninja -S "$src/llvm" -B "$work/build" \
    -DCMAKE_TOOLCHAIN_FILE="$tc" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" \
    -DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections" \
    -DLLVM_HOST_TRIPLE="$triple" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$triple" \
    -DLLVM_TARGETS_TO_BUILD="$target" \
    -DLLVM_ENABLE_PROJECTS= \
    -DLLVM_NATIVE_TOOL_DIR="$work/host/bin" \
    -DLLVM_TABLEGEN="$work/host/bin/llvm-tblgen" \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_ENABLE_LIBCXX=ON \
    -DLLVM_ENABLE_PIC=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_APPEND_VC_REV=ON \
    -DLLVM_FORCE_VC_REVISION="$LLVM_REVISION" \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git

# --- 3. Build and install only the libraries those components need -------------
cfgdir="$work/build/tools/llvm-config"
libdeps=$(find "$work/build" -name LibraryDependencies.inc | head -n 1)
[ -n "$libdeps" ] || { echo "LibraryDependencies.inc not generated" >&2; exit 1; }
# shellcheck disable=SC2086
libs=$(python3 -I "$here/llvm-components.py" libs "$libdeps" $COMPONENTS)
echo "Libraries for: $(echo $COMPONENTS)"
echo "$libs" | tr '\n' ' '; echo
# shellcheck disable=SC2086
ninja -C "$work/build" -j"$jobs" $libs llvm-headers
ninja -C "$work/build" install-llvm-headers
mkdir -p "$prefix/lib" "$prefix/bin"
for l in $libs; do
    install -m 0644 "$work/build/lib/lib$l.a" "$prefix/lib/"
done

# --- 4. The host llvm-config describing the shipped NextBSD build ----------------
mkdir -p "$work/llvm-config"
# shellcheck disable=SC2086
python3 -I "$here/llvm-components.py" trim "$libdeps" \
    "$work/llvm-config/LibraryDependencies.inc" $COMPONENTS
cp "$cfgdir/BuildVariables.inc" "$work/llvm-config/"
ext=$(find "$work/build" -name ExtensionDependencies.inc | head -n 1)
cp "$ext" "$work/llvm-config/"
# -fno-rtti like the host LLVMSupport it links; the target's llvm/Config
# headers come first so LLVM_HOST_TRIPLE etc. are NextBSD's.
c++ -std=c++17 -O2 -DNDEBUG -fno-rtti \
    -I"$work/llvm-config" -I"$work/build/include" -I"$src/llvm/include" \
    "$src/llvm/tools/llvm-config/llvm-config.cpp" \
    "$work/host/lib/libLLVMTargetParser.a" \
    "$work/host/lib/libLLVMSupport.a" \
    "$work/host/lib/libLLVMDemangle.a" \
    -lpthread -static-libstdc++ -static-libgcc \
    -o "$prefix/bin/llvm-config"
strip "$prefix/bin/llvm-config"

# --- 5. Check it answers what meson and Mesa ask -----------------------------------
lc="$prefix/bin/llvm-config"
# Every query exits non-zero on a problem (set -e stops the build).
# shellcheck disable=SC2086
$lc --libfiles --link-static $COMPONENTS > /dev/null
# shellcheck disable=SC2086
mesa_libs=$($lc --libs --ldflags --link-static --system-libs $COMPONENTS)
info="$work/llvm-config.txt"
{
    echo "llvm-config answers:"
    for q in --version --host-target --targets-built --has-rtti --shared-mode \
             --build-mode --assertion-mode --cppflags --cxxflags --components; do
        printf '  %-16s %s\n' "$q" "$($lc $q)"
    done
    printf '  %-16s %s\n' "--system-libs" "$($lc --link-static --system-libs)"
    printf '  %-16s %s\n' "--libs" "$mesa_libs"
} > "$info"
cat "$info"
[ "$($lc --version)" = "$LLVM_VERSION" ]
[ "$($lc --host-target)" = "$triple" ]
[ "$($lc --targets-built)" = "$target" ]
[ "$($lc --has-rtti)" = YES ]
[ "$($lc --shared-mode)" = static ]
[ "$($lc --libdir)" = "$(cd "$prefix/lib" && pwd -P)" ]

cat > "$prefix/BUILD-INFO" <<EOF
NextBSD static LLVM for Mesa's llvmpipe (nextbsd-toolchain#12)
source:      $LLVM_TAG ($LLVM_REVISION)
target:      $triple ($target only)
components:  $(echo $COMPONENTS)
rtti:        on    exceptions: off    C++ runtime: libc++/libcxxrt (sysroot)
sysroot:     ${SYSROOT_ID:-nextbsd-freebsd-compat continuous}
bin/llvm-config runs on the x86_64 Linux build host and answers for the target.
EOF
cat "$info" >> "$prefix/BUILD-INFO"

rm -rf "$work"
end=$(date +%s)
echo "Static LLVM $LLVM_VERSION ($T) build+install took $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s on $jobs jobs"
du -sh "$prefix" "$prefix/lib" "$prefix/include"
ls "$prefix/lib" | wc -l
