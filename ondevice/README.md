# NextBSD-toolchain: the on-machine toolchain

The contents of the **`NextBSD-toolchain`** package ([#16](https://github.com/nextbsd/nextbsd-toolchain/issues/16),
plan [E24](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction) D9, D11):
the tools that run **on NextBSD**, so Gershwin can build GNUstep and itself on the machine. It's like Apple's
Command Line Tools: installed by default on Gershwin images only, not part of `NextBSD-everything`.

This is separate from the cross toolchain image (the repo's Dockerfiles), which runs on the Linux CI runner and
is unchanged. Both build clang from the same pin, `../llvm/source.env` (llvmorg-19.1.7, the revision base's own
compiler is).

| Component | Version / source | Installed as |
|---|---|---|
| clang, lld | 19.1.7 (`../llvm/source.env`) | `/usr/bin/clang`, `clang++`, `clang-cpp`, `cc`, `c++`, `cpp`, `ld.lld`, `ld`; resource headers in `/usr/lib/clang/19/include` |
| LLVM binutils | 19.1.7 | `llvm-{ar,ranlib,nm,objcopy,strip,readobj,readelf,size,objdump,symbolizer,addr2line,cxxfilt}`, plus `ar`, `ranlib`, `nm`, `objcopy`, `strip`, `readelf`, `size`, `objdump`, `addr2line`, `c++filt` |
| GNU make | 4.4.1 (`sources.env`) | `/usr/bin/gmake` |
| pkgconf | 2.5.1 (`sources.env`) | `/usr/bin/pkgconf`, `pkg-config` link, `/usr/share/aclocal/pkg.m4` |
| Git | Apple's `Git-155` = 2.50.1 (`sources.env`) | `/usr/bin/git`, `/usr/libexec/git-core`, `/usr/share/git-core` |

Base already has what a native build needs besides these: headers, libc++/libcxxrt, the `crt*.o` files and
libgcc/libcompiler_rt. Base has no clang resource headers (`WITHOUT_TOOLCHAIN`), so they ship here.

## Build

`.github/workflows/build-toolchain-pkg.yml` cross-builds both architectures on the x86_64 runner inside the
per-arch toolchain image, against compat's `continuous` base as the sysroot (and nextbsd-userland's for libcurl),
the way nextbsd-contrib builds:

- `build-clang.sh`: CMake cross build of clang, lld and the binutils; LLVM's own native sub-build makes the
  tablegen tools. Statically linked against the LLVM libraries, X86 and AArch64 targets, stripped. The staged
  result is cached per arch on the LLVM pin and the recipe.
- `build-tools.sh`: gmake and pkgconf with their `configure` in cross mode; Git with its own Makefile.

The result is `nextbsd-toolchain-<arch>.tar.gz`, a tree rooted at `/` owned by root. A merge to `main` or a
manual run on `main` publishes it to this repo's `continuous` release; nothing is dispatched downstream. PRs
build only.

## Git: client only (D9)

Apple's `Git-155` tag carries upstream Git 2.50.1 unmodified (`src/git`) and prebuilt man pages. Apple's Xcode
`Makefile` is replaced by a direct build with Git's Makefile and Apple's applicable options (no gettext, no
gitweb, symlinked builtins). Its one patch (CVE-2021-21300) is already upstream and isn't applied.

- **Ships:** `git`, `scalar`, the `git-remote-http`/`https`/`ftp`/`ftps` helpers (libcurl from nextbsd-userland:
  Apple's curl with base OpenSSL), the shell-script commands (`submodule`, `mergetool`, `filter-branch`, ...),
  Apple's contrib files (`git-subtree`, completion for bash/zsh/tcsh, `git-prompt.sh`). SSH remotes use base
  OpenSSH. `upload-pack`/`receive-pack` are built into `git` and stay: ssh:// and file:// remotes run them.
- **Left out:** `git-daemon`, `git-http-backend`, gitweb, `git-shell`, `git-instaweb`, `git-svn`, `git-cvs*`,
  `git-p4`, `git-archimport`, `git-quiltimport`, `send-email`, `gitk`, `git-gui`, `git-http-push` (WebDAV push,
  needs expat), and everything needing Perl, Python, Tcl or gettext.
- **System config:** `/usr/share/git-core/gitconfig` (where the Command Line Tools keep it), Apple's file minus
  the macOS Keychain helper: `init.defaultBranch = main`. Apple's `gitattributes` ships beside it.

## Sources and patches

Pinned in `sources.env` with SHA-256; clang/lld use `../llvm/source.env`. A component's patches go in
`patches/<name>/*.patch` (`gmake`, `pkgconf`, `git`), applied in order with `patch -p1`; the series are empty
today.

## Not included (yet)

- **cmake and autotools** (autoconf, automake, libtool): optional extras in the plan, a sub-package or a later
  step.
- `yacc`, `lex`, `c89`/`c99`: part of FreeBSD's `WITH_TOOLCHAIN` in base, built from freebsd-src, not here.
- Sanitizer and profile runtimes (compiler-rt beyond base's builtins), clang-tools (`clang-format`, `clangd`),
  `lldb`.
