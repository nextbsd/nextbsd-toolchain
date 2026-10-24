#!/usr/bin/env bash
# =============================================================================
# build-clang.sh: clang and lld 19.1.7 that run ON NextBSD (nextbsd-toolchain#16)
# =============================================================================
#
# Cross-builds clang, lld and the LLVM binutils for ONE NextBSD architecture
# from the pinned llvmorg-19.1.7 source (../llvm/source.env, the pin the cross
# toolchain image and the base system's own compiler use), and stages them in
# $DESTDIR at FreeBSD's WITH_TOOLCHAIN paths:
#
#   /usr/bin/clang, clang++, clang-cpp (+ clang-19)   the compiler
#   /usr/bin/cc, c++, cpp                              -> clang
#   /usr/bin/ld.lld (+ lld), /usr/bin/ld               -> lld
#   /usr/lib/clang/19/include                          clang's resource headers
#   /usr/bin/llvm-{ar,ranlib,nm,objcopy,strip,readobj,readelf,size,objdump,
#                  symbolizer,addr2line,cxxfilt}       LLVM binutils, plus the
#   /usr/bin/{ar,ranlib,nm,objcopy,strip,readelf,size,objdump,addr2line,c++filt}
#                                                      plain names, as links
#
# Base already ships everything else a native build needs: the headers, libc++
# and libcxxrt, the crt*.o files, libgcc/libcompiler_rt and libgcc_s. Base has
# the /usr/lib/clang/19 directories but no resource headers (WITHOUT_TOOLCHAIN),
# so they come from here.
#
# How: CMake cross build (CMAKE_SYSTEM_NAME=FreeBSD) with the toolchain image's
# clang/lld and --sysroot set to compat's base. The tablegen tools LLVM runs
# during its own build are compiled for the build host first by LLVM's NATIVE
# sub-build (host gcc). The LLVM libraries are linked statically into each tool,
# as in base; the tools link base's libc, libc++, libthr, libz and libexecinfo.
# X86 and AArch64 are both built, so either architecture can cross-compile for
# the other, like the image's compiler. Release, no assertions, stripped.
#
# EXECUTION CONTEXT
#   Inside the nextbsd-kernel-toolchain container ($CROSS_BINDIR holds the
#   pinned clang/lld), with compat's `continuous` base extracted in $SYSROOT.
#
# USAGE
#   T=amd64 TA=amd64 SYSROOT=... DESTDIR=/stage ./build-clang.sh
# =============================================================================
set -euo pipefail

: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged compat base}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

here=$(cd "$(dirname "$0")" && pwd)
. "$here/../llvm/source.env"

case "$T" in
    amd64) triple=x86_64-unknown-freebsd15.1; proc=x86_64 ;;
    arm64) triple=aarch64-unknown-freebsd15.1; proc=aarch64 ;;
    *) echo "unknown target $T" >&2; exit 1 ;;
esac

work=${LLVM_WORKDIR:-/tmp/ondevice-llvm-$T}
jobs=${JOBS:-$(nproc)}
fail() { echo "FAIL: $*" >&2; exit 1; }

start=$(date +%s)
rm -rf "$work"
"$here/../llvm/fetch-llvm.sh" "$work"
src="$work/llvm-project-$LLVM_VERSION.src"

# Target toolchain. The linker is chosen by --ld-path in the *linker* flags
# only, so compile-only checks see no "argument unused" warning (CMake's flag
# checks treat that warning as a failure).
cat > "$work/nextbsd-$T.cmake" <<EOF
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
set(CMAKE_AR "$CROSS_BINDIR/llvm-ar" CACHE FILEPATH "")
set(CMAKE_RANLIB "$CROSS_BINDIR/llvm-ranlib" CACHE FILEPATH "")
set(CMAKE_NM "$CROSS_BINDIR/llvm-nm" CACHE FILEPATH "")
set(CMAKE_OBJCOPY "$CROSS_BINDIR/llvm-objcopy" CACHE FILEPATH "")
set(CMAKE_STRIP "$CROSS_BINDIR/llvm-strip" CACHE FILEPATH "")
set(CMAKE_READELF "$CROSS_BINDIR/llvm-readelf" CACHE FILEPATH "")
set(CMAKE_EXE_LINKER_FLAGS_INIT "--ld-path=$CROSS_BINDIR/ld.lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "--ld-path=$CROSS_BINDIR/ld.lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "--ld-path=$CROSS_BINDIR/ld.lld")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# The tools a native build calls, by their LLVM install components. ld.lld is
# lld's only link (no lld-link, ld64.lld or wasm-ld); clang's are clang++ and
# clang-cpp (no clang-cl).
components="clang;clang-resource-headers;lld"
components+=";llvm-ar;llvm-ranlib;llvm-nm;llvm-objcopy;llvm-strip"
components+=";llvm-readobj;llvm-readelf;llvm-size;llvm-objdump"
components+=";llvm-symbolizer;llvm-addr2line;llvm-cxxfilt"

# CLANG_VENDOR: `cc --version` says "NextBSD clang version 19.1.7 (...)", as
# base's says "FreeBSD clang version". The default target triple is the
# machine's own, as on base.
cmake -G Ninja -S "$src/llvm" -B "$work/build" \
    -DCMAKE_TOOLCHAIN_FILE="$work/nextbsd-$T.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCROSS_TOOLCHAIN_FLAGS_NATIVE="-DCMAKE_C_COMPILER=gcc;-DCMAKE_CXX_COMPILER=g++" \
    -DLLVM_HOST_TRIPLE="$triple" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="$triple" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD="X86;AArch64" \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_APPEND_VC_REV=ON \
    -DLLVM_FORCE_VC_REVISION="$LLVM_REVISION" \
    -DLLVM_FORCE_VC_REPOSITORY=https://github.com/llvm/llvm-project.git \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_ZLIB=FORCE_ON \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_FFI=OFF \
    -DLLVM_ENABLE_CURL=OFF \
    -DLLVM_ENABLE_HTTPLIB=OFF \
    -DLLVM_INSTALL_BINUTILS_SYMLINKS=OFF \
    -DLLVM_PARALLEL_LINK_JOBS=2 \
    -DCLANG_VENDOR=NextBSD \
    -DCLANG_LINKS_TO_CREATE="clang++;clang-cpp" \
    -DLLD_SYMLINKS_TO_CREATE="ld.lld" \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_PLUGIN_SUPPORT=OFF \
    -DLLVM_DISTRIBUTION_COMPONENTS="$components"

DESTDIR="$DESTDIR" ninja -C "$work/build" -j"$jobs" install-distribution-stripped

# FreeBSD's names for the same tools (base installs them as links to clang,
# lld and the LLVM binutils when WITH_TOOLCHAIN is set).
b="$DESTDIR/usr/bin"
ln -sfn clang "$b/cc"
ln -sfn clang++ "$b/c++"
ln -sfn clang-cpp "$b/cpp"
ln -sfn ld.lld "$b/ld"
for pair in ar:llvm-ar ranlib:llvm-ranlib nm:llvm-nm objcopy:llvm-objcopy \
            strip:llvm-strip readelf:llvm-readelf size:llvm-size \
            objdump:llvm-objdump addr2line:llvm-addr2line c++filt:llvm-cxxfilt; do
    ln -sfn "${pair#*:}" "$b/${pair%%:*}"
done

# What must be there, and what must not (the clang-cl / Mach-O / COFF / wasm
# driver names are not shipped).
for f in clang clang++ clang-cpp cc c++ cpp ld.lld ld llvm-ar ar ranlib nm \
         objcopy strip readelf size objdump addr2line c++filt; do
    [ -e "$b/$f" ] || fail "/usr/bin/$f was not staged"
done
for f in clang-cl ld64.lld lld-link wasm-ld; do
    [ -e "$b/$f" ] && fail "/usr/bin/$f was staged"
done
test -f "$DESTDIR/usr/lib/clang/$LLVM_MAJOR/include/stddef.h" \
    || fail "clang resource headers missing from /usr/lib/clang/$LLVM_MAJOR/include"
readelf="$CROSS_BINDIR/llvm-readelf"
"$readelf" -h "$b/clang-$LLVM_MAJOR" | grep -E 'OS/ABI|Machine'
"$readelf" -d "$b/clang-$LLVM_MAJOR" | grep NEEDED

rm -rf "$work"
end=$(date +%s)
echo "clang/lld $LLVM_VERSION for $T took $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s on $jobs jobs"
du -sh "$DESTDIR/usr/bin" "$DESTDIR/usr/lib/clang"
ls -l "$b"
