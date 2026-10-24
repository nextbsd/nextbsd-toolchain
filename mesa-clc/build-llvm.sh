#!/bin/sh
# Step 1 of the mesa_clc host libraries (nextbsd-toolchain#11): LLVM and clang
# 19.1.7 as SHARED development libraries for the x86_64 Linux build host, from
# the one pin in ../llvm/source.env (fetched by ../llvm/fetch-llvm.sh).
#
# Mesa's mesa_clc is a build-host program: it compiles iris/crocus internal
# OpenCL C shaders to SPIR-V while Mesa builds. It links libclang-cpp, LLVM,
# LLVMSPIRVLib and SPIRV-Tools. This step provides the first two:
#   lib/libLLVM.so.19.1 (+ libLLVM-19.so)  every LLVM component, one DSO
#   lib/libclang-cpp.so.19.1               the clang C++ API, one DSO
#   include/{llvm,llvm-c,clang,clang-c}    headers, including generated ones
#   lib/clang/19/include                   clang's resource headers (opencl-c*.h)
#   bin/llvm-config                        answers `--shared-mode shared`
# The static component archives and CMake package config are installed too,
# because step 2 (build-spirv.sh) builds SPIRV-LLVM-Translator against them;
# step 2 removes them once that is done.
#
# Shared, not static: Mesa's clc path then needs only libclang-cpp instead of
# the 15+ static clang libraries, and the tree stays a fraction of the size.
# Host target only (X86): mesa_clc emits SPIR-V through the translator, not
# through an LLVM backend. RTTI on, so Mesa's default cpp_rtti=true matches
# `llvm-config --has-rtti`. No zlib/zstd/libxml2/libedit/libffi.
#
# This is separate from the image's cross clang/lld (/usr/lib/llvm-19, the
# "llvm" stage), which is static and installs no libraries or headers.
#
# Usage: build-llvm.sh <install-prefix>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../llvm/source.env"

prefix=${1:?usage: build-llvm.sh <install-prefix>}
work=${LLVM_WORKDIR:-/tmp/mesa-clc-llvm-work}
jobs=${JOBS:-$(nproc)}

start=$(date +%s)
"$here/../llvm/fetch-llvm.sh" "$work"
src="$work/llvm-project-$LLVM_VERSION.src"

# LLVM_BUILD_TOOLS/CLANG_BUILD_TOOLS off: no llvm-* or clang executables;
# llvm-config is built and installed by hand below.
cmake -G Ninja -S "$src/llvm" -B "$work/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DLLVM_ENABLE_PROJECTS=clang \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DCLANG_LINK_CLANG_DYLIB=ON \
    -DLLVM_ENABLE_RTTI=ON \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_APPEND_VC_REV=ON \
    -DLLVM_FORCE_VC_REVISION="$LLVM_REVISION" \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_USE_LINKER=gold \
    -DLLVM_PARALLEL_LINK_JOBS=2 \
    -DCLANG_BUILD_TOOLS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_DOCS=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF

ninja -C "$work/build" -j"$jobs" install/strip
ninja -C "$work/build" -j"$jobs" llvm-config
install -m 0755 "$work/build/bin/llvm-config" "$prefix/bin/llvm-config"
strip "$prefix/bin/llvm-config"

rm -rf "$work"
end=$(date +%s)
echo "LLVM/clang $LLVM_VERSION (shared, host) build+install took $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s on $jobs jobs"
lc="$prefix/bin/llvm-config"
for q in --version --shared-mode --has-rtti --targets-built --libs --system-libs; do
    printf '  %-16s %s\n' "$q" "$($lc $q)"
done
[ "$($lc --version)" = "$LLVM_VERSION" ]
[ "$($lc --shared-mode)" = shared ]
[ "$($lc --has-rtti)" = YES ]
ls -l "$prefix"/lib/libLLVM*.so* "$prefix"/lib/libclang-cpp.so*
test -f "$prefix/lib/clang/$LLVM_MAJOR/include/opencl-c-base.h"
test -f "$prefix/lib/cmake/llvm/LLVMConfig.cmake"
du -sh "$prefix"
