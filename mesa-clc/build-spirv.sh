#!/bin/sh
# Step 2 of the mesa_clc host libraries (nextbsd-toolchain#11), run after
# build-llvm.sh into the same prefix:
#   1. SPIRV-LLVM-Translator v19.1.x (LLVMSPIRVLib), static, against the
#      shared LLVM 19.1.7 from step 1, with the pinned SPIRV-Headers.
#   2. SPIRV-Tools + its matching SPIRV-Headers, static, PIC.
#   3. Prune the prefix to what Mesa's native mesa_clc build consumes:
#      llvm-config, libLLVM/libclang-cpp, headers, clang resource headers,
#      libLLVMSPIRVLib.a, the SPIRV-Tools archives and their .pc files.
#   4. Check the result: compile one OpenCL C kernel to SPIR-V along the path
#      mesa_clc takes (clang -> LLVM IR -> LLVMSPIRVLib -> SPIRV-Tools linker).
# Pins: sources.env (SHA-256 checked) and ../llvm/source.env.
#
# Usage: build-spirv.sh <install-prefix>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../llvm/source.env"
. "$here/sources.env"

prefix=${1:?usage: build-spirv.sh <install-prefix>}
work=${SPIRV_WORKDIR:-/tmp/mesa-clc-spirv-work}
jobs=${JOBS:-$(nproc)}

fetch() { # <name> <url> <sha256>: unpack to $work/<name>
    mkdir -p "$work/$1"
    curl -fsSL --retry 5 --retry-delay 10 -o "$work/$1.tar.gz" "$2"
    echo "$3  $work/$1.tar.gz" | sha256sum -c -
    tar -xzf "$work/$1.tar.gz" -C "$work/$1" --strip-components=1
    rm -f "$work/$1.tar.gz"
}

start=$(date +%s)
rm -rf "$work"
fetch spirv-headers "$SPIRV_HEADERS_URL" "$SPIRV_HEADERS_SHA256"
fetch spirv-tools "$SPIRV_TOOLS_URL" "$SPIRV_TOOLS_SHA256"
fetch translator "$SPIRV_LLVM_TRANSLATOR_URL" "$SPIRV_LLVM_TRANSLATOR_SHA256"

# --- 1. SPIRV-LLVM-Translator ---------------------------------------------------
# Built first, so it does not pick up SPIRV-Tools (that only adds
# --spirv-tools-dis to the llvm-spirv tool, which is not kept). With
# LLVM_LINK_LLVM_DYLIB from step 1, LLVMSPIRVLib links libLLVM. Its .pc
# version is BASE_LLVM_VERSION.0 = 19.1.7.0, inside Mesa's >= 19.1, < 19.2.
cmake -G Ninja -S "$work/translator" -B "$work/translator-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DLLVM_DIR="$prefix/lib/cmake/llvm" \
    -DBASE_LLVM_VERSION="$LLVM_VERSION" \
    -DLLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR="$work/spirv-headers" \
    -DLLVM_SPIRV_INCLUDE_TESTS=OFF \
    -DCCACHE_ALLOWED=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_SPIRV-Tools=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_SPIRV-Tools-tools=ON
ninja -C "$work/translator-build" -j"$jobs" install

# --- 2. SPIRV-Tools ---------------------------------------------------------------
# Static (SPIRV-Tools.pc: -lSPIRV-Tools-opt -lSPIRV-Tools -lSPIRV-Tools-link),
# PIC, no executables or tests. Its version comes from CHANGES (no git here).
cmake -G Ninja -S "$work/spirv-tools" -B "$work/spirv-tools-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSPIRV-Headers_SOURCE_DIR="$work/spirv-headers" \
    -DSPIRV_SKIP_EXECUTABLES=ON \
    -DSPIRV_SKIP_TESTS=ON \
    -DSPIRV_WERROR=OFF \
    -DSPIRV_TOOLS_BUILD_STATIC=ON
ninja -C "$work/spirv-tools-build" -j"$jobs" install

# --- 3. Prune to what Mesa consumes ---------------------------------------------------
# The LLVM/clang static archives and CMake package config were only for the
# translator build above. Mesa finds LLVM with llvm-config (shared mode),
# clang with find_library(clang-cpp) and the rest with pkgconf.
find "$prefix/lib" -maxdepth 1 -name 'lib*.a' \
    ! -name 'libLLVMSPIRVLib.a' ! -name 'libSPIRV-Tools*.a' -delete
rm -rf "$prefix/lib/cmake/llvm" "$prefix/lib/cmake/clang" \
       "$prefix"/lib/libclang.so* "$prefix"/lib/libLTO.so* \
       "$prefix"/lib/libRemarks.so* "$prefix/libexec" "$prefix/share"
find "$prefix/bin" -mindepth 1 ! -name llvm-config -exec rm -rf {} +

# --- 4. Check -------------------------------------------------------------------------
lc="$prefix/bin/llvm-config"
# shellcheck disable=SC2046
c++ -std=c++17 -O1 $("$lc" --cppflags) \
    -DRESOURCE_DIR="\"$prefix/lib/clang/$LLVM_MAJOR\"" \
    "$here/check-clc.cpp" -o "$work/check-clc" \
    -L"$prefix/lib" -Wl,-rpath,"$prefix/lib" \
    -lLLVMSPIRVLib -lclang-cpp $("$lc" --libs --link-shared) \
    -lSPIRV-Tools-link -lSPIRV-Tools-opt -lSPIRV-Tools
"$work/check-clc"

cat > "$prefix/BUILD-INFO" <<EOF
NextBSD host libraries for Mesa's mesa_clc (nextbsd-toolchain#11).
Build-host (x86_64 Linux) only; nothing here ships.
LLVM/clang:             $LLVM_TAG ($LLVM_REVISION), shared, X86 only, RTTI on
SPIRV-LLVM-Translator:  v$SPIRV_LLVM_TRANSLATOR_VERSION (LLVMSPIRVLib $(sed -n 's/^Version: //p' "$prefix/lib/pkgconfig/LLVMSPIRVLib.pc"), static)
SPIRV-Tools:            v$SPIRV_TOOLS_VERSION ($(sed -n 's/^Version: //p' "$prefix/lib/pkgconfig/SPIRV-Tools.pc"), static)
SPIRV-Headers:          $SPIRV_HEADERS_VERSION
EOF
cat "$prefix/BUILD-INFO"

rm -rf "$work"
end=$(date +%s)
echo "SPIR-V libraries build+check took $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s on $jobs jobs"
du -sh "$prefix" "$prefix/lib" "$prefix/include"
ls -l "$prefix/bin" "$prefix/lib" "$prefix/lib/pkgconfig"
