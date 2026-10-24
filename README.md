# nextbsd-toolchain

Cross-compilation toolchain containers for NextBSD's build pipeline (kernel, kexts, base and userland).

> **Renamed** from `nextbsd-kernel-toolchain` (2026-10-24). The repo serves every NextBSD build, not only the kernel,
> and will build the pinned LLVM 19.1.7 toolchain itself (nextbsd/nextbsd#561, E23).
> **The container image keeps its old name for now:** `ghcr.io/nextbsd/nextbsd-kernel-toolchain`. Moving it to
> `ghcr.io/nextbsd/nextbsd-toolchain` is a separate, staged change. Never create a new repo named
> `nextbsd-kernel-toolchain`: that would break the redirect from the old name.

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
(Org → Packages → `nextbsd-kernel-toolchain` → Package settings → Change
visibility → Public).
