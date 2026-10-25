# NextBSD-toolchain: the on-machine toolchain

The contents of the **`NextBSD-toolchain`** package ([#16](https://github.com/nextbsd/nextbsd-toolchain/issues/16),
[#27](https://github.com/nextbsd/nextbsd-toolchain/issues/27), plan [E24](https://github.com/nextbsd/nextbsd-userland/wiki/E24-GNUstep-Gershwin-Requirements-Direction) D9, D11):
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
| CMake | 4.4.4 | `/usr/bin/cmake`, `ctest`, `cpack`; `/usr/share/cmake-4.4`, `/usr/share/aclocal/cmake.m4` |
| GNU m4 | 1.4.21 | `/usr/bin/gm4` (base's `/usr/bin/m4` is BSD m4) |
| GNU Autoconf | 2.73 | `/usr/bin/autoconf`, `autoheader`, `autom4te`, `autoreconf`, `autoscan`, `autoupdate`, `ifnames`; `/usr/share/autoconf` |
| GNU Automake | 1.19 | `/usr/bin/automake`, `aclocal` (+ `-1.19` names); `/usr/share/automake-1.19`, `/usr/share/aclocal-1.19` |
| GNU Libtool | 2.6.2 | `/usr/bin/libtool`, `libtoolize`, `libtool-next-version`; `/usr/share/libtool`, its macros in `/usr/share/aclocal` (no libltdl) |
| Perl, for autoconf/automake only | 5.44.0 (perl-cross 1.6.5) | `/usr/libexec/autotools/bin/perl`, `/usr/libexec/autotools/lib/perl5` (private, not on `PATH`) |

Base already has what a native build needs besides these: headers, libc++/libcxxrt, the `crt*.o` files and
libgcc/libcompiler_rt. Base has no clang resource headers (`WITHOUT_TOOLCHAIN`), so they ship here.

## Build

`.github/workflows/build-toolchain-pkg.yml` cross-builds both architectures on the x86_64 runner inside the
per-arch toolchain image, against compat's `continuous` base as the sysroot (and nextbsd-userland's for libcurl),
the way nextbsd-contrib builds:

- `build-clang.sh`: CMake cross build of clang, lld and the binutils; LLVM's own native sub-build makes the
  tablegen tools. Statically linked against the LLVM libraries, X86 and AArch64 targets, stripped. The staged
  result is cached per arch on the LLVM pin and the recipe.
- `build-tools.sh`: gmake, pkgconf, m4 and libtool with their `configure` in cross mode; Git with its own
  Makefile; Perl with perl-cross; cmake with its own CMake build (the image's cmake runs it); autoconf and automake
  (scripts only) configured with the paths they have on NextBSD. The workflow runs it as three sets per arch side
  by side: `gmake pkgconf git`, `m4 perl autoconf automake libtool` and `cmake`.

Checks: target executables are NextBSD ELFs for the right machine and link what they should. For cmake, m4,
Perl and the autotools, also: nothing staged names the build tree, the sysroot or the runner's LLVM, and every
script's `#!` names `/bin/sh` (or `/usr/bin/env sh`) or the private Perl. For the whole tools tree: nothing
staged replaces a file the sysroot (base, plus nextbsd-userland) already has.

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

## CMake

cmake, ctest and cpack, no `ccmake` (curses) or `cmake-gui` (Qt), no man pages (they need Sphinx). Libraries:
base's libarchive and zlib, nextbsd-userland's libcurl (Apple's curl, as Git uses). Base has no expat (only
`libbsdxml`, renamed), no public zstd and no libuv, jsoncpp, rhash or cppdap, so CMake builds its bundled copies
of those in; bzip2, liblzma and zstd come through base's libarchive. The Emacs and Vim modes aren't shipped.

## Autotools and their Perl

GNU m4 is installed as `gm4`, and autoconf's `autom4te` runs `/usr/bin/gm4`. autoconf and automake are Perl
scripts; libtool and libtoolize are shell scripts. Gershwin's build doesn't link libltdl (libs-base, -gui, -back
load bundles with `dlopen`), so it isn't installed; its sources stay in `/usr/share/libtool` for
`libtoolize --ltdl`.

The installed `libtool` script records the toolchain it was configured for. It's configured with `--host` and
wrappers named as the tools are on NextBSD (`cc`, `c++`, `ld`, `nm -B`, ...); the sysroot is stripped from the
paths clang reports, and the runner clang's resource directory becomes `/usr/lib/clang/19`. That makes it the
script a native configure on NextBSD would write.

**Perl is private to autoconf and automake.** NextBSD doesn't ship a general-purpose Perl, so there's no
`/usr/bin/perl` and nothing on `PATH`. The interpreter is `/usr/libexec/autotools/bin/perl` with its library in
`/usr/libexec/autotools/lib/perl5/5.44.0`, and the scripts' `#!` lines name it.

- **Build:** perl-cross 1.6.5 replaces Perl's `Configure` with one that only compiles and links its probes, so it
  runs with the cross compiler; `perl/freebsd.hints` gives it the values it can't probe (perl-cross has no FreeBSD
  hints). It builds without threads, and only the extensions autoconf and automake load are built, statically
  into the one binary: Fcntl, POSIX, Errno, File::Glob, Tie::Hash::NamedCapture, attributes, IO, PathTools (Cwd,
  File::Spec), Data::Dumper, Time::HiRes and Scalar-List-Utils (XS), plus constant, Exporter, Carp, XSLoader,
  base, parent, File::Find, File::Temp, File::Path, Getopt::Long and Text::ParseWords. Perl's own `lib/`
  (strict, warnings, Config, File::Basename, File::Copy, Class::Struct, ...) comes with it.
- **Left out:** the Perl utilities (`perldoc`, `cpan`, `pod2*`, ...), pods and man pages, `CORE/` (headers and
  `libperl.a`, for building XS), `unicore/` (only `charnames` and `Unicode::UCD` read it; the regex engine's
  tables are compiled in), the `re` pragma (its extension can't be linked statically, and autotools don't use
  it) and `.packlist`s. No CPAN, no ExtUtils::MakeMaker: you can't install modules into it.
- **Check:** the target perl can't run on the runner, so the build runs each autoconf and automake script
  (`--version`, which loads all of its modules) with the build host's Perl through the same `#!` path, and fails
  if any module it loads isn't in the shipped library.

## Sources and patches

Pinned in `sources.env` with SHA-256; clang/lld use `../llvm/source.env`. A component's patches go in
`patches/<name>/*.patch`, applied in order with `patch -p1`; the series are empty today. The one addition to an
upstream tree is `perl/freebsd.hints`, copied into perl-cross as `cnf/hints/freebsd`. Licences: `NOTICE.md`.

## Not included (yet)

- `yacc`, `lex`, `c89`/`c99`: part of FreeBSD's `WITH_TOOLCHAIN` in base, built from freebsd-src, not here.
- Sanitizer and profile runtimes (compiler-rt beyond base's builtins), clang-tools (`clang-format`, `clangd`),
  `lldb`.
