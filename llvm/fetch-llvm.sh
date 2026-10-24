#!/bin/sh
# Download the pinned llvm-project release tarball, verify its SHA-256 and
# unpack it. Usage: fetch-llvm.sh <dest-dir>; the source tree lands in
# <dest-dir>/llvm-project-$LLVM_VERSION.src. Shared by every LLVM build in
# this repo so they all use the one pin in source.env.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/source.env"

dest=${1:?usage: fetch-llvm.sh <dest-dir>}
mkdir -p "$dest"
tarball="$dest/llvm-project-$LLVM_VERSION.src.tar.xz"

curl -fsSL --retry 5 --retry-delay 10 -o "$tarball" "$LLVM_URL"
echo "$LLVM_SHA256  $tarball" | sha256sum -c -
tar -xJf "$tarball" -C "$dest"
rm -f "$tarball"
