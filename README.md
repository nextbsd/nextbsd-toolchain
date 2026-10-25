# nextbsd-toolchain

Cross-compilation toolchain containers for NextBSD's build pipeline (kernel, kexts, base and userland).

> **Renamed** from `nextbsd-kernel-toolchain` (2026-10-24). The repo serves every NextBSD build, not only the kernel,
> and will build the pinned LLVM 19.1.7 toolchain itself (nextbsd/nextbsd#561, E23).
> **The container image is `ghcr.io/nextbsd/nextbsd-toolchain`.** During the staged move (#15) it is also still
> pushed under the old name, `ghcr.io/nextbsd/nextbsd-kernel-toolchain`, with the same tags; that stops once no
> consumer pulls the old name. Never create a new repo named `nextbsd-kernel-toolchain`: that would break the
> redirect from the old name.

Each image bakes a **shallow, full-tree** checkout of
[`nextbsd/freebsd-src`](https://github.com/nextbsd/freebsd-src)
(`releng/15.1`) into `/usr/src`, pinned to an exact commit via the
`FREEBSD_SHA` build-arg, then runs `kernel-toolchain`. Downstream kernel and
module builds run *inside* this image, so they inherit the exact baked source —
no re-cloning, and the image itself (stored in GHCR) is the source artifact.

## Images

| Tag | Meaning |
|-----|---------|
| `amd64-latest` / `arm64-latest` | Most recent build for the arch |
| `amd64-fbsd-<sha>` | Source pinned to FreeBSD commit `<sha>` |
| `amd64-fbsd-tip` | Built from branch tip (manual / scheduled, no SHA) |

## Host build tools

Besides the cross clang/lld, the image carries the host tools the NextBSD X
stack, Mesa and GNUstep/Gershwin support repos build with (build-time only,
never shipped): meson 1.12.1 (pinned upstream tarball, SHA-256 checked), ninja,
CMake, **pkgconf** (never freedesktop's GPL `pkg-config`; the build fails if it
appears), autoconf/automake/libtool, X.Org util-macros 1.20.2 (pinned tarball,
SHA-256 checked), Python's mako, yaml and packaging for Mesa, and, built from
pinned upstream tarballs (SHA-256 checked) into `/usr/local`, NASM 3.02 (x86-64
SIMD/assembly in the GNUstep support libraries) and gperf 3.3 (fontconfig; GPL-3.0,
build host only).

## Host libraries for Mesa's `mesa_clc`

`/opt/mesa-clc` holds what Mesa's Intel drivers (iris, crocus) need on the build host to compile their internal
shaders with `mesa_clc`: LLVM/clang 19.1.7 as shared libraries (same `llvmorg-19.1.7` pin), SPIRV-LLVM-Translator
v19.1.23 and SPIRV-Tools v2026.4, with `llvm-config` and `.pc` files. Build-time only, never shipped. See
[`mesa-clc/README.md`](mesa-clc/README.md) for the pins and how nextbsd-mesa uses them.

## Static LLVM for Mesa

`llvm-static/` builds the tiny static LLVM (native target, MCJIT/ORC) that nextbsd-mesa links into llvmpipe, for
amd64 and arm64, from the same `llvmorg-19.1.7` pin. It is published as release `llvm-static-19.1.7`, not baked into
the image. See [`llvm-static/README.md`](llvm-static/README.md).

## Triggers

- `repository_dispatch: upstream-updated` — from the `freebsd-src` fork's daily
  sync, carrying the exact changed SHA in `client_payload[sha]`.
- `workflow_dispatch` — manual.
- `schedule` — weekly fallback (Mondays 06:00 UTC).

On success the **amd64** leg dispatches `toolchain-updated` to
`nextbsd-kernel`, passing the pinned `image_tag` forward.

## One-time setup

After the first successful build, set the GHCR package visibility to **public**
so downstream `container:` jobs can pull it without credentials
(Org → Packages → `nextbsd-toolchain` → Package settings → Change
visibility → Public).
