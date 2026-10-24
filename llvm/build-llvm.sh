#!/bin/sh
# Build the NextBSD cross toolchain (clang + lld + the llvm binutils the
# downstream builds call) from the pinned upstream llvmorg-19.1.7 source with
# CMake, and install it into <prefix> (the image uses /usr/lib/llvm-19, the
# path the apt.llvm.org packages used, so CROSS_BINDIR is unchanged).
#
# Only X86 and AArch64 are built (NextBSD's two targets), Release, no
# assertions, statically linked against the LLVM libraries, stripped.
#
# What is installed, and who uses it:
#   clang, clang++, clang-cpp  make.py XCC/XCXX/XCPP (--cross-bindir), the
#                              nextbsd-userland CMake cross files, nextbsd-contrib
#   clang resource headers     every cross compile (stddef.h, stdarg.h, ...)
#   ld.lld (lld)               make.py XLD, --ld-path= in userland/contrib
#   llvm-ar, llvm-ranlib,      nextbsd-contrib libtool/autoconf builds
#   llvm-strip (llvm-objcopy)
#   llvm-nm                    nextbsd-kernel symbol checks
#   llvm-readelf (llvm-readobj) nextbsd-userland/nextbsd-contrib DT_NEEDED checks
#
# No local patches: FreeBSD's two cherry-picks on top of 19.1.7 are an
# llvm-objcopy fix (the kernel and world builds use their own bootstrapped
# elftoolchain objcopy, not this one) and a PowerPC fix (not built here).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/source.env"

prefix=${1:?usage: build-llvm.sh <install-prefix>}
work=${LLVM_WORKDIR:-/tmp/llvm-work}
jobs=${JOBS:-$(nproc)}

start=$(date +%s)
"$here/fetch-llvm.sh" "$work"
src="$work/llvm-project-$LLVM_VERSION.src"

# LLVM_FORCE_VC_*: a release tarball has no .git, so name the exact upstream
# revision explicitly; `clang --version` then reports it like base clang does.
cmake -G Ninja -S "$src/llvm" -B "$work/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
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
    -DLLVM_ENABLE_ZSTD=FORCE_ON \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_INSTALL_BINUTILS_SYMLINKS=OFF \
    -DLLVM_USE_LINKER=gold \
    -DLLVM_PARALLEL_LINK_JOBS=2 \
    -DCLANG_INCLUDE_TESTS=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DLLVM_DISTRIBUTION_COMPONENTS="clang;clang-resource-headers;lld;llvm-ar;llvm-ranlib;llvm-nm;llvm-objcopy;llvm-strip;llvm-readobj;llvm-readelf"

ninja -C "$work/build" -j"$jobs" install-distribution-stripped

rm -rf "$work"
end=$(date +%s)
echo "LLVM $LLVM_VERSION build+install took $(( (end - start) / 60 )) min $(( (end - start) % 60 )) s on $jobs jobs"
"$prefix/bin/clang" --version
"$prefix/bin/ld.lld" --version
ls -l "$prefix/bin"
