#!/usr/bin/env bash
# =============================================================================
# build-tools.sh: gmake, pkgconf, Apple's Git, GNU m4, autoconf, automake,
# libtool, cmake and autotools' private Perl that run ON NextBSD
# (nextbsd-toolchain#16, #27)
# =============================================================================
#
# Cross-builds the non-LLVM half of the NextBSD-toolchain package for ONE
# architecture into $DESTDIR, from the pinned tarballs in sources.env, the way
# nextbsd-contrib builds base's third-party programs: upstream's own build in
# cross mode (--host=<triple>), the toolchain image's clang, --sysroot to the
# staged base. Configure checks that would run a test program get their
# FreeBSD answers as cache variables (listed at each one).
#
# Each component's patches/<name>/*.patch series is applied in order before it
# is built; the series are empty today (nothing needs patching). The one
# addition to an upstream tree is perl/freebsd.hints, perl-cross's hints for
# NextBSD (perl-cross has none for FreeBSD).
#
# EXECUTION CONTEXT
#   Inside the nextbsd-kernel-toolchain container, with compat's `continuous`
#   base and nextbsd-userland's `continuous` tree (for libcurl, which Git's
#   http/https transport links) extracted together in $SYSROOT.
#
# USAGE
#   ./build-tools.sh                 every component, in COMPONENTS order
#   ./build-tools.sh git             one component
#   ./build-tools.sh m4 perl autoconf automake libtool
#                                    the autotools (the build checks that
#                                    autoconf/automake's modules are in the
#                                    shipped Perl when perl, autoconf and
#                                    automake are built in the same run)
# =============================================================================
set -euo pipefail

: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged base (+ userland) sysroot}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${DESTDIR:=/stage}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${TOOLS_WORKDIR:-/tmp/ondevice-tools-$T}"
. "$ROOT/sources.env"

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd15.1 ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd15.1 ;;
    *) echo "unknown target $T" >&2; exit 1 ;;
esac
CROSS_CC="$CROSS_BINDIR/clang --target=$CROSS_TRIPLE --sysroot=$SYSROOT"
CROSS_LDFLAGS="--ld-path=$CROSS_BINDIR/ld.lld"
BUILD_TRIPLE="$(uname -m)-pc-linux-gnu"
JOBS=-j"$(nproc 2>/dev/null || echo 2)"
AR="$CROSS_BINDIR/llvm-ar"
RANLIB="$CROSS_BINDIR/llvm-ranlib"
STRIP="$CROSS_BINDIR/llvm-strip"
READELF="$CROSS_BINDIR/llvm-readelf"

comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# fetch <name> <url> <sha256>: download, verify, unpack into $BUILD/<name>-src
# (top directory stripped), then apply patches/<name>/*.patch in order.
fetch() {
    local name="$1" url="$2" sha="$3" tarball p
    SRCDIR="$BUILD/$name-src"
    tarball="$BUILD/$(basename "$url")"
    rm -rf "$SRCDIR"; mkdir -p "$SRCDIR"
    curl -fsSL --retry 5 --retry-delay 10 -o "$tarball" "$url"
    echo "$sha  $tarball" | sha256sum -c -
    tar -xf "$tarball" -C "$SRCDIR" --strip-components=1
    rm -f "$tarball"
    for p in "$ROOT/patches/$name"/*.patch; do
        [ -f "$p" ] || continue
        note "patch $(basename "$p")"
        patch -d "$SRCDIR" -p1 --forward --batch < "$p"
    done
}

fresh_build() {
    COMP_BUILD="$BUILD/$1-build"
    COMP_ROOT="$BUILD/$1-root"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# A target executable must be a FreeBSD ELF for the right machine.
elf_check() {
    "$READELF" -h "$1" | grep 'OS/ABI:.*FreeBSD' >/dev/null || fail "$1 is not a FreeBSD ELF"
    note "$(basename "$1"): $("$READELF" -h "$1" | sed -n 's/^ *Machine: *//p')"
}
needed_check() {
    "$READELF" -d "$1" | grep "NEEDED.*$2" >/dev/null || fail "$1 missing DT_NEEDED $2"
    note "DT_NEEDED ok: $(basename "$1") -> $2"
}

# =============================================================================
# GNU make, installed as /usr/bin/gmake (as FreeBSD's ports name it; base's
# make is bmake). Only the program and its man page ship: no info manual, no
# gnumake.h (for loadable modules), no translations.
# =============================================================================
build_gmake() {
    comp "gmake $GMAKE_VERSION [autoconf cross]"
    fetch gmake "$GMAKE_URL" "$GMAKE_SHA256"
    fresh_build gmake
    (
        cd "$COMP_BUILD"
        # The two configure checks that run a program, answered for FreeBSD:
        # gettimeofday is standard, and posix_spawn reports a missing program
        # synchronously (ENOENT from the call), so make may use it.
        CC="$CROSS_CC" CFLAGS="-O2 -pipe" LDFLAGS="$CROSS_LDFLAGS" \
        AR="$AR" RANLIB="$RANLIB" \
        ac_cv_func_gettimeofday=yes \
        make_cv_synchronous_posix_spawn=yes \
        "$SRCDIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --prefix=/usr --mandir=/usr/share/man --program-prefix=g \
            --disable-nls --without-guile --without-dmalloc --without-customs \
            --disable-dependency-tracking
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/share/man/man1"
    install -m 0555 "$COMP_ROOT/usr/bin/gmake" "$DESTDIR/usr/bin/gmake"
    "$STRIP" "$DESTDIR/usr/bin/gmake"
    install -m 0444 "$COMP_ROOT/usr/share/man/man1/gmake.1" "$DESTDIR/usr/share/man/man1/gmake.1"
    elf_check "$DESTDIR/usr/bin/gmake"
}

# =============================================================================
# pkgconf (E24 D1), with /usr/bin/pkg-config linked to it. Its search path is
# where NextBSD puts .pc files: base and the support repos in
# /usr/libdata/pkgconfig (FreeBSD's place), the X stack in /usr/X11 (E23), then
# /usr/local. libpkgconf is linked in statically, so no library ships; bomtool
# (an SBOM generator) is not shipped.
# =============================================================================
build_pkgconf() {
    comp "pkgconf $PKGCONF_VERSION [autoconf cross]"
    fetch pkgconf "$PKGCONF_URL" "$PKGCONF_SHA256"
    fresh_build pkgconf
    local pcpath=/usr/libdata/pkgconfig:/usr/X11/lib/pkgconfig:/usr/X11/share/pkgconfig
    pcpath+=:/usr/local/libdata/pkgconfig:/usr/local/share/pkgconfig
    (
        cd "$COMP_BUILD"
        CC="$CROSS_CC" CFLAGS="-O2 -pipe" LDFLAGS="$CROSS_LDFLAGS" \
        AR="$AR" RANLIB="$RANLIB" \
        "$SRCDIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --prefix=/usr --mandir=/usr/share/man \
            --disable-shared --enable-static \
            --with-pkg-config-dir="$pcpath" \
            --with-system-libdir=/usr/lib \
            --with-system-includedir=/usr/include \
            --disable-dependency-tracking
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    local m
    mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/share/aclocal" \
             "$DESTDIR/usr/share/man/man1" "$DESTDIR/usr/share/man/man5" "$DESTDIR/usr/share/man/man7"
    install -m 0555 "$COMP_ROOT/usr/bin/pkgconf" "$DESTDIR/usr/bin/pkgconf"
    "$STRIP" "$DESTDIR/usr/bin/pkgconf"
    ln -sfn pkgconf "$DESTDIR/usr/bin/pkg-config"
    install -m 0444 "$COMP_ROOT/usr/share/aclocal/pkg.m4" "$DESTDIR/usr/share/aclocal/pkg.m4"
    for m in man1/pkgconf.1 man5/pc.5 man7/pkg.m4.7; do
        install -m 0444 "$COMP_ROOT/usr/share/man/$m" "$DESTDIR/usr/share/man/$m"
    done
    ln -sfn pkgconf.1 "$DESTDIR/usr/share/man/man1/pkg-config.1"
    elf_check "$DESTDIR/usr/bin/pkgconf"
    strings -a "$DESTDIR/usr/bin/pkgconf" | grep -F "$pcpath" >/dev/null \
        || fail "pkgconf's default search path is not $pcpath"
    [ -e "$DESTDIR/usr/bin/bomtool" ] && fail "bomtool was staged"
    return 0
}

# =============================================================================
# Apple's Git (E24 D9), client only. Built from src/git with Git's own
# Makefile (Apple's Xcode Makefile needs xcrun/xcode-select), with the options
# Apple's sets where they apply: no gettext, no gitweb, symlinks rather than
# hard links. Then:
#   - no Perl, Python or Tcl/Tk parts (NO_PERL, NO_PYTHON, NO_TCLTK), so no
#     git-svn, git-p4, send-email, cvs bridges, archimport, gitk or git-gui;
#   - no expat (NO_EXPAT), so no git-http-push (WebDAV push); fetch and push
#     over https use the smart protocol through git-remote-https and libcurl;
#   - the server parts are removed after install: git-daemon,
#     git-http-backend, git-shell, git-instaweb, and git-quiltimport (an
#     importer). upload-pack and receive-pack are built into git and stay:
#     they are what ssh:// and file:// remotes run;
#   - NO_PERL/NO_PYTHON leave "not available" stubs for the Perl and Python
#     commands; those are removed too.
# SSH is base OpenSSH's ssh; https goes through libcurl from nextbsd-userland
# (Apple's curl, base OpenSSL). The system config is
# /usr/share/git-core/gitconfig, where Apple's Command Line Tools keep theirs,
# with Apple's settings minus the macOS Keychain helper (git/gitconfig here);
# Apple's gitattributes ships beside it. Apple's man pages (prebuilt in
# src/git-manpages) and contrib files (completion, git-prompt.sh, git-subtree)
# ship as Apple ships them, less the pages of what is left out.
# =============================================================================
build_git() {
    comp "git $GIT_VERSION ($GIT_APPLE_TAG) [Makefile cross]"
    fetch git "$GIT_URL" "$GIT_SHA256"
    fresh_build git
    local gsrc="$SRCDIR/src/git" mansrc="$SRCDIR/src/git-manpages"
    local r="$COMP_ROOT" f m
    local uname_m
    case "$T" in amd64) uname_m=amd64 ;; arm64) uname_m=arm64 ;; esac
    # Git's FreeBSD settings (config.mak.uname) add -I/usr/local/include and
    # -L/usr/local/lib, which would be the build host's in a cross build, and
    # link -liconv, which FreeBSD has in libc since 10.x. config.mak is read
    # after config.mak.uname, so it takes them back out.
    cat > "$gsrc/config.mak" <<'EOF'
BASIC_CFLAGS := $(filter-out -I/usr/local/include,$(BASIC_CFLAGS))
BASIC_LDFLAGS := $(filter-out -L/usr/local/lib,$(BASIC_LDFLAGS))
NEEDS_LIBICONV =
EOF
    local -a gitmake=(
        -C "$gsrc" $JOBS
        uname_S=FreeBSD uname_R=15.1-RELEASE uname_M="$uname_m" uname_P="$uname_m"
        uname_O=FreeBSD uname_V=15.1
        CC="$CROSS_CC" AR="$AR" CFLAGS="-O2 -pipe" LDFLAGS="$CROSS_LDFLAGS"
        GIT_VERSION="$GIT_VERSION"
        prefix=/usr sysconfdir=/etc mandir=/usr/share/man
        gitexecdir=libexec/git-core template_dir=share/git-core/templates
        ETC_GITCONFIG=/usr/share/git-core/gitconfig
        ETC_GITATTRIBUTES=/usr/share/git-core/gitattributes
        PAGER_ENV="LESS=FRX LV=-c MORE=FRX"
        SHELL_PATH=/bin/sh
        CURL_CFLAGS="-I$SYSROOT/usr/include" CURL_LDFLAGS=-lcurl
        NO_PERL=YesPlease NO_PYTHON=YesPlease NO_TCLTK=YesPlease
        NO_GETTEXT=YesPlease NO_EXPAT=YesPlease NO_GITWEB=YesPlease
        INSTALL_SYMLINKS=YesPlease SKIP_DASHED_BUILT_INS=YesPlease
        NO_INSTALL_HARDLINKS=YesPlease
        V=1
    )
    make "${gitmake[@]}" all
    make "${gitmake[@]}" DESTDIR="$r" install

    # Left out (D9): server parts, importers/bridges, and the Perl/Python stubs.
    rm -f "$r/usr/bin/git-shell" "$r/usr/bin/git-cvsserver"
    for f in git-daemon git-http-backend git-shell git-instaweb git-quiltimport \
             git-archimport git-cvsexportcommit git-cvsimport git-cvsserver \
             git-send-email git-svn git-p4 git-http-push git-gui git-citool; do
        rm -f "$r/usr/libexec/git-core/$f"
    done
    rm -rf "$r/usr/share/gitweb" "$r/usr/share/git-gui" "$r/usr/share/gitk" \
           "$r/usr/share/perl5" "$r/usr/share/git-core/perl" "$r/usr/bin/gitk"

    # Apple's system config (less osxkeychain) and attributes, and the contrib
    # files Apple installs. git-subtree is a shell script.
    mkdir -p "$r/usr/share/git-core"
    install -m 0444 "$ROOT/git/gitconfig" "$r/usr/share/git-core/gitconfig"
    install -m 0444 "$SRCDIR/gitattributes" "$r/usr/share/git-core/gitattributes"
    for f in git-completion.bash git-completion.tcsh git-completion.zsh git-prompt.sh; do
        install -m 0444 "$gsrc/contrib/completion/$f" "$r/usr/share/git-core/$f"
    done
    install -m 0555 "$gsrc/contrib/subtree/git-subtree.sh" "$r/usr/libexec/git-core/git-subtree"

    # Apple's prebuilt man pages, less the left-out commands and the Perl
    # library pages (man3).
    mkdir -p "$r/usr/share/man"
    for m in man1 man5 man7; do
        mkdir -p "$r/usr/share/man/$m"
        cp "$mansrc/$m"/* "$r/usr/share/man/$m/"
    done
    for f in git-daemon git-http-backend git-shell git-instaweb git-quiltimport \
             git-archimport git-cvsexportcommit git-cvsimport git-cvsserver \
             git-send-email git-svn git-p4 git-http-push gitk git-gui git-citool \
             gitweb git-credential-osxkeychain; do
        rm -f "$r/usr/share/man/man1/$f.1"
    done
    rm -f "$r/usr/share/man/man5/gitweb.conf.5"
    chmod 0444 "$r"/usr/share/man/man*/*

    # Strip the executables (not the shell scripts or symlinks).
    find "$r/usr/bin" "$r/usr/libexec/git-core" -type f -perm -u+x | while read -r f; do
        if "$READELF" -h "$f" >/dev/null 2>&1; then "$STRIP" "$f"; fi
    done

    (cd "$r" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)

    local g="$DESTDIR/usr/bin/git" x="$DESTDIR/usr/libexec/git-core"
    elf_check "$g"
    needed_check "$g" libz
    needed_check "$x/git-remote-http" libcurl
    [ -e "$x/git-remote-https" ] || fail "git-remote-https not staged"
    for f in git-daemon git-http-backend git-shell git-instaweb git-http-push \
             git-send-email git-svn git-p4 git-cvsserver; do
        [ -e "$x/$f" ] && fail "$f was staged (left out by D9)"
    done
    [ -e "$DESTDIR/usr/bin/git-shell" ] && fail "/usr/bin/git-shell was staged"
    [ -d "$DESTDIR/usr/share/gitweb" ] && fail "gitweb was staged"
    if grep -rlE '^#!.*(perl|python|wish)' "$x" "$DESTDIR/usr/bin" 2>/dev/null; then
        fail "a Perl/Python/Tcl script was staged"
    fi
    strings -a "$g" | grep -F /usr/share/git-core/gitconfig >/dev/null \
        || fail "git's system config is not /usr/share/git-core/gitconfig"
    note "git-core: $(find "$x" -type f | wc -l) files, $(find "$x" -type l | wc -l) links"
    return 0
}

# =============================================================================
# The build tools (nextbsd-toolchain#27, E24 D11): GNU m4, a private minimal
# Perl, autoconf, automake, libtool and cmake, for Gershwin's on-machine build
# (libobjc2 and libdispatch with CMake, the GNUstep libraries with autotools).
# =============================================================================

# autoconf and automake are Perl scripts. Their Perl is private to them: the
# interpreter is /usr/libexec/autotools/bin/perl, its library under
# /usr/libexec/autotools/lib/perl5, nothing on PATH and no /usr/bin/perl, so
# NextBSD doesn't advertise a general-purpose Perl. The scripts' #! lines name
# it directly.
AT_PREFIX=/usr/libexec/autotools
AT_PERL=$AT_PREFIX/bin/perl

# target_tools: $TB holds the cross compiler and binutils under the names they
# have on NextBSD (cc, c++, cpp, ld, nm, ar, ...), with the sysroot inside the
# wrappers (the image has no llvm-objdump; nothing here runs objdump on target
# objects). perl-cross and libtool record the tools they were configured with
# (in Config.pm and in the libtool script), so configuring them with these
# names records what is right on the machine. The linker is passed only when a
# wrapper links, so compile-only probes see no "argument unused" warning;
# -ffile-prefix-map keeps build paths out of __FILE__.
target_tools() {
    TB="$BUILD/target-bin"
    [ -x "$TB/cc" ] && return 0
    mkdir -p "$TB"
    local name drv t
    local common="--target=$CROSS_TRIPLE --sysroot=$SYSROOT -ffile-prefix-map=$BUILD=/usr/src"
    for name in cc c++; do
        case $name in cc) drv=clang ;; c++) drv=clang++ ;; esac
        cat > "$TB/$name" <<EOF
#!/bin/sh
for a in "\$@"; do
    case \$a in
    -c|-E|-S|-M|-MM|-fsyntax-only) exec $CROSS_BINDIR/$drv $common "\$@" ;;
    esac
done
exec $CROSS_BINDIR/$drv $common --ld-path=$CROSS_BINDIR/ld.lld "\$@"
EOF
    done
    printf '#!/bin/sh\nexec %s/clang %s -E "$@"\n' "$CROSS_BINDIR" "$common" > "$TB/cpp"
    printf '#!/bin/sh\nexec %s/ld.lld "$@"\n' "$CROSS_BINDIR" > "$TB/ld"
    for t in ar nm ranlib strip objcopy readelf; do
        printf '#!/bin/sh\nexec %s/llvm-%s "$@"\n' "$CROSS_BINDIR" "$t" > "$TB/$t"
    done
    chmod 0755 "$TB"/*
}

# host_autotools_paths: autoconf's and automake's builds run their own scripts
# (autom4te freezes the macro files), and their configure checks the Perl and
# GNU m4 they are given. So the paths the scripts use on NextBSD,
# /usr/libexec/autotools/bin/perl and /usr/bin/gm4, are made to exist in the
# (throwaway) build container too, pointing at its Perl and GNU m4. Nothing
# from the container is staged.
host_autotools_paths() {
    [ -e "$AT_PERL" ] || { mkdir -p "$(dirname "$AT_PERL")"; ln -s "$(command -v perl)" "$AT_PERL"; }
    [ -e /usr/bin/gm4 ] || ln -s "$(command -v m4)" /usr/bin/gm4
    "$AT_PERL" -e 'require 5.010' || fail "no build-host perl for $AT_PERL"
    /usr/bin/gm4 --version | grep 'GNU M4' >/dev/null || fail "no build-host GNU m4 for /usr/bin/gm4"
}

# no_build_paths <dir>: nothing staged may name the build tree, the sysroot,
# the wrappers or the runner's LLVM.
no_build_paths() {
    local hits
    hits=$(grep -rlaF -e "$BUILD" -e "$SYSROOT" -e "$CROSS_BINDIR" -e "${GITHUB_WORKSPACE:-/nonexistent-workspace}" "$1" || true)
    [ -z "$hits" ] || fail "build paths in: $hits"
    local d="${1#"$COMP_ROOT"}"; d="${d#"$DESTDIR"}"
    note "no build paths under ${d:-/}"
}

# script_check <dir> [<path to skip>...]: every script's #! line names /bin/sh,
# /usr/bin/env sh or the private Perl.
script_check() {
    local dir="$1" f l x bad=
    shift
    while IFS= read -r f; do
        for x in "$@"; do [ "${f#"$dir"}" = "$x" ] && continue 2; done
        l=$(head -n1 "$f")
        case "$l" in
            '#!'*) ;;
            *) continue ;;
        esac
        case "$(echo "$l" | tr -s ' ')" in
            '#! /bin/sh'|'#!/bin/sh'|'#! /bin/sh '*|'#!/bin/sh '*|'#! /usr/bin/env sh'|'#!/usr/bin/env sh') ;;
            "#!$AT_PERL"|"#! $AT_PERL"|"#!$AT_PERL "*|"#! $AT_PERL "*) ;;
            *) echo "unexpected interpreter: $f: $l" >&2; bad=1 ;;
        esac
    done < <(find "$dir" -type f -perm -u+x)
    [ -z "$bad" ] || fail "scripts with an interpreter NextBSD-toolchain does not ship"
    note "#! lines ok in $(basename "$dir")"
}

# stage <comp-root>: copy one component's install into $DESTDIR.
stage() { (cd "$1" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -); }

# =============================================================================
# GNU m4 as /usr/bin/gm4 (as FreeBSD's ports name it; base's m4 is BSD m4),
# which autoconf runs. The program and its man page, as for gmake.
# =============================================================================
build_m4() {
    comp "m4 $M4_VERSION [autoconf cross]"
    fetch m4 "$M4_URL" "$M4_SHA256"
    target_tools
    fresh_build m4
    (
        cd "$COMP_BUILD"
        CC="$TB/cc" CFLAGS="-O2 -pipe" AR="$TB/ar" RANLIB="$TB/ranlib" \
        "$SRCDIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --prefix=/usr --mandir=/usr/share/man --program-prefix=g \
            --with-syscmd-shell=/bin/sh --disable-nls \
            --disable-dependency-tracking
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/share/man/man1"
    install -m 0555 "$COMP_ROOT/usr/bin/gm4" "$DESTDIR/usr/bin/gm4"
    "$STRIP" "$DESTDIR/usr/bin/gm4"
    install -m 0444 "$COMP_ROOT/usr/share/man/man1/gm4.1" "$DESTDIR/usr/share/man/man1/gm4.1"
    elf_check "$DESTDIR/usr/bin/gm4"
    no_build_paths "$DESTDIR/usr/bin/gm4"
}

# =============================================================================
# A minimal Perl, private to autoconf and automake (see AT_PREFIX).
#
# Cross-built with perl-cross (its configure only compiles and links its probes;
# the values it can't probe for FreeBSD are in perl/freebsd.hints). No threads,
# and only the extensions autoconf and automake load, linked statically into
# the one perl binary:
#   XS:     Fcntl, POSIX, Errno, File::Glob, re, Tie::Hash::NamedCapture, IO,
#           Cwd/File::Spec (PathTools), Data::Dumper, Time::HiRes,
#           List::Util/Scalar::Util
#   pure:   constant, Exporter, Carp, XSLoader, base, parent, File::Find,
#           File::Temp, File::Path, Getopt::Long, Text::ParseWords
# plus Perl's own lib/ (strict, warnings, vars, overload, Config, File::Basename,
# File::Copy, File::Compare, File::stat, Class::Struct, Symbol, ...). Shipped:
# the interpreter and that library. Not shipped: the perl utilities (perldoc,
# cpan, ...), the pods and man pages, the headers and libperl.a for building XS
# (CORE/), the Unicode database files only charnames and Unicode::UCD read
# (unicore/: Perl's compiled-in tables cover the regex engine), and .packlists.
# autoconf/automake's build checks that what they load is all here.
# =============================================================================
PERL_MODS=ext/Fcntl,ext/POSIX,ext/Errno,ext/File-Glob,ext/File-Find,ext/re
PERL_MODS+=,ext/Tie-Hash-NamedCapture
PERL_MODS+=,dist/IO,dist/PathTools,dist/Data-Dumper,dist/Time-HiRes,dist/constant
PERL_MODS+=,dist/Exporter,dist/Carp,dist/XSLoader,dist/base
PERL_MODS+=,cpan/Scalar-List-Utils,cpan/parent,cpan/File-Temp,cpan/File-Path
PERL_MODS+=,cpan/Getopt-Long,cpan/Text-ParseWords

build_perl() {
    comp "perl $PERL_VERSION, perl-cross $PERLCROSS_VERSION [cross, minimal, $AT_PREFIX]"
    fetch perl "$PERL_URL" "$PERL_SHA256"
    local psrc="$SRCDIR"
    fetch perl-cross "$PERLCROSS_URL" "$PERLCROSS_SHA256"
    # perl-cross is unpacked over the Perl tree (its Makefile and configure
    # replace Perl's Configure) and builds in place.
    (cd "$SRCDIR" && tar -cf - .) | (cd "$psrc" && tar -xf -)
    rm -rf "$SRCDIR"; SRCDIR="$psrc"
    install -m 0644 "$ROOT/perl/freebsd.hints" "$SRCDIR/cnf/hints/freebsd"
    target_tools
    fresh_build perl
    local osvers=15.1
    # byteorder: perl-cross reads it from a test object with objdump, which the
    # image lacks for target objects; amd64 and arm64 are both 64-bit
    # little-endian. --sysroot (also inside the wrappers): the build's miniperl
    # runs with $^O = linux, so Errno_pm.PL reads $Config{sysroot}/usr/include/
    # errno.h, which must be NextBSD's. -fwrapv -fno-strict-aliasing: what
    # Perl's own Configure adds for gcc and clang (perl-cross adds it for gcc
    # only).
    (
        cd "$SRCDIR"
        ./configure \
            --target="$CROSS_TRIPLE" --sysroot="$SYSROOT" \
            --with-cc="$TB/cc" --with-cpp="$TB/cpp" --with-ar="$TB/ar" \
            --with-nm="$TB/nm" --with-ranlib="$TB/ranlib" \
            --with-readelf="$TB/readelf" --with-objdump=objdump \
            --prefix="$AT_PREFIX" \
            -Dosname=freebsd -Dosvers="$osvers" -Dbyteorder=12345678 \
            -Uusethreads -Uuseithreads -Uinstallusrbinperl \
            -Dman1dir=none -Dman3dir=none \
            -Dcf_by=NextBSD -Dcf_email=root@localhost -Dperladmin=root@localhost \
            -Dmyhostname=localhost -Dmydomain=.localdomain \
            -Doptimize="-O2 -pipe -fwrapv -fno-strict-aliasing" \
            --all-static --only-mod="$PERL_MODS"
        make $JOBS
        make DESTDIR="$COMP_ROOT" install.perl
    )

    local r="$COMP_ROOT$AT_PREFIX" priv arch f
    priv="$AT_PREFIX/lib/perl5/$PERL_VERSION"
    [ -f "$COMP_ROOT$priv/strict.pm" ] || fail "no privlib at $priv"
    arch=$(dirname "$(find "$COMP_ROOT$priv" -name Config.pm -path '*/Config.pm' | grep -v '/Encode/\|/Net/' | head -1)")
    arch="${arch#"$COMP_ROOT"}"
    note "privlib $priv, archlib $arch"

    # The interpreter, and nothing else in bin.
    find "$r/bin" -mindepth 1 ! -name perl -exec rm -f {} +
    [ -f "$r/bin/perl" ] && [ ! -L "$r/bin/perl" ] || fail "perl is not a file in $AT_PREFIX/bin"
    "$STRIP" "$r/bin/perl"
    rm -rf "$r/share" "$r/man" "$COMP_ROOT$arch/CORE" "$COMP_ROOT$priv/pod" "$COMP_ROOT$priv/unicore"
    find "$r" \( -name '*.pod' -o -name .packlist -o -name '*.h' \) -exec rm -f {} +
    find "$r" -type d -empty -delete

    # Config records the tools as configured; they were the target-named
    # wrappers, so drop the wrapper directory to leave cc, ar, nm, ... . The
    # --sysroot flags and value are the build's, not the machine's.
    for f in "$COMP_ROOT$arch"/Config*.p[lm]; do
        sed -i -e "s|$TB/||g" -e "s| *--sysroot=$SYSROOT||g" \
            -e "s|^sysroot='$SYSROOT'|sysroot=''|" -e "s|sysroot => '$SYSROOT'|sysroot => ''|" "$f"
    done
    grep -n "$SYSROOT" "$COMP_ROOT$arch"/Config*.p[lm] || true
    no_build_paths "$r"

    stage "$COMP_ROOT"
    local p="$DESTDIR$AT_PERL"
    elf_check "$p"
    "$READELF" -d "$p" | grep NEEDED | sed 's/^/    /'
    # Base libraries only (librt: Time::HiRes's build asks for it).
    "$READELF" -d "$p" | grep NEEDED | grep -v 'lib\(c\|m\|crypt\|util\|thr\|rt\|execinfo\|gcc_s\)\.so' \
        >/dev/null && fail "perl links a library besides libc, libm, libcrypt, libutil, librt"
    strings -a "$p" | grep -F "$priv" >/dev/null || fail "perl's @INC does not have $priv"
    grep -q "^osname='freebsd'" "$DESTDIR$arch/Config_heavy.pl" || fail "perl's osname is not freebsd"
    grep -q "^useithreads='undef'" "$DESTDIR$arch/Config_heavy.pl" || fail "perl was built with threads"
    for f in strict warnings Carp Exporter File/Temp Getopt/Long Data/Dumper POSIX Fcntl \
             Time/HiRes Cwd File/Spec IO/File Text/ParseWords Class/Struct; do
        [ -e "$DESTDIR$priv/$f.pm" ] || [ -e "$DESTDIR$arch/$f.pm" ] || fail "perl lacks $f.pm"
    done
    if [ -d "$DESTDIR$arch/auto" ] && find "$DESTDIR$arch/auto" -name '*.so' | grep . >/dev/null; then
        fail "perl staged loadable extensions; they should all be static"
    fi
    PERL_PRIVLIB=$priv PERL_ARCHLIB=$arch
    note "perl: binary $(du -h --apparent-size "$p" | cut -f1), library $(du -sh --apparent-size "$DESTDIR$AT_PREFIX/lib" | cut -f1), $(find "$DESTDIR$AT_PREFIX/lib" -type f | wc -l) files"
}

# =============================================================================
# GNU Autoconf. Architecture-independent (Perl and m4 scripts), so it is
# configured on the build host with the paths it has on NextBSD: the private
# Perl and /usr/bin/gm4 (host_autotools_paths). No info manual, no Emacs modes.
# =============================================================================
build_autoconf() {
    comp "autoconf $AUTOCONF_VERSION [configure, scripts]"
    fetch autoconf "$AUTOCONF_URL" "$AUTOCONF_SHA256"
    host_autotools_paths
    fresh_build autoconf
    (
        cd "$COMP_BUILD"
        CONFIG_SHELL=/bin/sh PERL="$AT_PERL" M4=/usr/bin/gm4 AWK=awk \
        SED=/usr/bin/sed GREP=/usr/bin/grep EGREP='/usr/bin/grep -E' \
        /bin/sh "$SRCDIR/configure" \
            --prefix=/usr --mandir=/usr/share/man --infodir=/usr/share/info
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    rm -rf "$COMP_ROOT/usr/share/info" "$COMP_ROOT/usr/share/emacs"
    grep -q "'/usr/bin/gm4'" "$COMP_ROOT/usr/bin/autom4te" || fail "autom4te does not run /usr/bin/gm4"
    script_check "$COMP_ROOT"
    no_build_paths "$COMP_ROOT"
    stage "$COMP_ROOT"
}

# =============================================================================
# GNU Automake, the same way as autoconf. Its tutorial tarball (amhello) and
# info manual are not shipped.
# =============================================================================
build_automake() {
    comp "automake $AUTOMAKE_VERSION [configure, scripts]"
    fetch automake "$AUTOMAKE_URL" "$AUTOMAKE_SHA256"
    host_autotools_paths
    fresh_build automake
    (
        cd "$COMP_BUILD"
        CONFIG_SHELL=/bin/sh PERL="$AT_PERL" AWK=awk \
        SED=/usr/bin/sed GREP=/usr/bin/grep EGREP='/usr/bin/grep -E' FGREP='/usr/bin/grep -F' \
        /bin/sh "$SRCDIR/configure" \
            --prefix=/usr --mandir=/usr/share/man --infodir=/usr/share/info \
            --docdir=/usr/share/doc/automake
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    rm -rf "$COMP_ROOT/usr/share/info" "$COMP_ROOT/usr/share/doc"
    script_check "$COMP_ROOT"
    no_build_paths "$COMP_ROOT"
    stage "$COMP_ROOT"
    autotools_perl_check
}

# autotools_perl_check: the modules autoconf and automake load must all be in
# the shipped Perl. The target perl can't run on the runner, so each script is
# run (--version, which loads all of its modules) by the build host's Perl
# through the same #! path, with the shipped Autom4te::/Automake:: modules, and
# every other module it loads (%INC) must exist in the shipped library. threads
# and Thread::Queue are what automake loads only under a threaded Perl; the
# shipped one has no threads (checked in build_perl).
autotools_perl_check() {
    if [ -z "${PERL_PRIVLIB:-}" ] || [ ! -x "$DESTDIR/usr/bin/autoconf" ]; then
        note "(perl/autoconf not built in this run: module check skipped)"
        return 0
    fi
    local tr="$BUILD/inc-trace" t out mod missing=
    mkdir -p "$tr"; : > "$tr/inc.txt"
    cat > "$tr/NextBSDIncTrace.pm" <<'EOF'
package NextBSDIncTrace;
END {
    if (open(my $fh, '>>', $ENV{NEXTBSD_INC_TRACE})) {
        print $fh "$_\n" for grep { $_ ne 'NextBSDIncTrace.pm' } keys %INC;
    }
}
1;
EOF
    for t in autoconf autoheader autom4te autoreconf autoscan autoupdate ifnames aclocal automake; do
        out=$(NEXTBSD_INC_TRACE="$tr/inc.txt" PERL5OPT="-I$tr -MNextBSDIncTrace" \
              autom4te_perllibdir="$DESTDIR/usr/share/autoconf" \
              AUTOMAKE_UNINSTALLED=1 PERL5LIB="$DESTDIR/usr/share/automake-$AUTOMAKE_API" \
              "$DESTDIR/usr/bin/$t" --version) || fail "$t --version failed"
        note "$t --version: $(echo "$out" | head -n1)"
    done
    while read -r mod; do
        case "$mod" in
            Autom4te/*|Automake/*|threads.pm|threads/*|Thread/Queue.pm) continue ;;
        esac
        [ -e "$DESTDIR$PERL_PRIVLIB/$mod" ] || [ -e "$DESTDIR$PERL_ARCHLIB/$mod" ] || {
            echo "    MISSING from the shipped perl: $mod" >&2; missing=1; }
    done < <(sort -u "$tr/inc.txt")
    [ -z "$missing" ] || fail "autoconf/automake load modules the shipped perl lacks"
    note "autoconf/automake load $(sort -u "$tr/inc.txt" | grep -vcE '^(Autom4te|Automake)/') core modules; all shipped"
}

# =============================================================================
# GNU Libtool: libtool, libtoolize and the macros and helper files libtoolize
# copies into packages. libltdl is not installed.
#
# The installed libtool script carries the configuration of the system it was
# configured for: the compiler and binutils names, how the C++ compiler links
# (crt objects, -L paths, libraries), the library search path. It is configured
# here with --host and the target-named tools (target_tools), so the names are
# NextBSD's (cc, c++, ld, nm -B, ...); the paths clang reports through
# --sysroot have the sysroot removed, the runner clang's resource directory is
# mapped to /usr/lib/clang/<major> (NextBSD-toolchain's), and the build system
# lines say NextBSD's triple, so the script is what a native configure on
# NextBSD writes.
# =============================================================================
build_libtool() {
    comp "libtool $LIBTOOL_VERSION [autoconf cross]"
    fetch libtool "$LIBTOOL_URL" "$LIBTOOL_SHA256"
    target_tools
    host_autotools_paths
    fresh_build libtool
    local res major lt
    res=$("$CROSS_BINDIR/clang" -print-resource-dir)
    major=$("$CROSS_BINDIR/clang" -dumpversion | cut -d. -f1)
    (
        cd "$COMP_BUILD"
        export PATH="$TB:$PATH"
        CONFIG_SHELL=/bin/sh \
        CC=cc CXX=c++ LD=ld NM='nm -B' AR=ar RANLIB=ranlib STRIP=strip \
        OBJDUMP=objdump CFLAGS="-O2 -pipe" CXXFLAGS="-O2 -pipe" \
        M4=/usr/bin/gm4 SED=/usr/bin/sed GREP=/usr/bin/grep \
        EGREP='/usr/bin/grep -E' FGREP='/usr/bin/grep -F' \
        lt_cv_path_lt_DD=/bin/dd \
        /bin/sh "$SRCDIR/configure" \
            --build="$BUILD_TRIPLE" --host="$CROSS_TRIPLE" \
            --prefix=/usr --mandir=/usr/share/man --infodir=/usr/share/info \
            --disable-ltdl-install --disable-dependency-tracking
        make $JOBS
        make install DESTDIR="$COMP_ROOT"
    )
    rm -rf "$COMP_ROOT/usr/share/info"
    rm -f "$COMP_ROOT"/usr/include/ltdl.h "$COMP_ROOT"/usr/lib/libltdl*
    rm -rf "$COMP_ROOT/usr/include/libltdl"
    find "$COMP_ROOT" -type d -empty -delete

    lt="$COMP_ROOT/usr/bin/libtool"
    sed -i -e "s|$SYSROOT||g" -e "s|$res|/usr/lib/clang/$major|g" \
        -e "s|^build_alias=.*|build_alias=$CROSS_TRIPLE|" \
        -e "s|^build=.*|build=$CROSS_TRIPLE|" \
        -e "s|^build_os=.*|build_os=${CROSS_TRIPLE#*-*-}|" "$lt"
    # What the script now says about the toolchain, for the log.
    grep -E '^(host|build|build_os|LTCC|CC|LD|NM|AR|RANLIB|STRIP|OBJDUMP|SHELL|SED|GREP|predep_objects|postdep_objects|postdeps|compiler_lib_search_path|sys_lib_search_path_spec|sys_lib_dlsearch_path_spec)=' "$lt" \
        | sort -u | sed 's/^/    /'
    # Only the configuration sections (ltmain's own code has case patterns for
    # every OS, Linux included).
    if sed -n '/^# ### BEGIN LIBTOOL\( TAG\)* CONFIG/,/^# ### END LIBTOOL\( TAG\)* CONFIG/p' "$lt" \
            | grep -nE 'llvm-[0-9]|target-bin|linux-gnu|pc-linux'; then
        fail "libtool's configuration still names the build host"
    fi
    grep -qE '^CC="?cc"?$' "$lt" || fail "libtool's C compiler is not cc"
    [ -e "$COMP_ROOT/usr/lib/libltdl.so" ] && fail "libltdl was installed"
    script_check "$COMP_ROOT"
    no_build_paths "$COMP_ROOT"
    stage "$COMP_ROOT"
    note "libtool --version: $("$DESTDIR/usr/bin/libtool" --version | head -n1)"
    note "libtoolize --version: $("$DESTDIR/usr/bin/libtoolize" --version | head -n1)"
}

# =============================================================================
# CMake: cmake, ctest and cpack (no ccmake/curses or Qt GUI, no docs build),
# cross-built with CMake's own CMake build and the toolchain image's cmake.
# Libraries: base's libarchive and zlib and nextbsd-userland's libcurl (Apple's
# curl, as Git uses); base has no expat (only libbsdxml, renamed), no public
# zstd and no libuv, jsoncpp, rhash or cppdap, so CMake's bundled copies are
# built in (expat, libuv, jsoncpp, librhash, cppdap, kwiml). bzip2, liblzma and
# zstd come through base's libarchive.
# =============================================================================
build_cmake() {
    comp "cmake $CMAKE_VERSION [CMake cross]"
    fetch cmake "$CMAKE_URL" "$CMAKE_SHA256"
    fresh_build cmake
    local proc mm="${CMAKE_VERSION%.*}" b
    case "$T" in amd64) proc=x86_64 ;; arm64) proc=aarch64 ;; esac
    cat > "$COMP_BUILD/nextbsd-$T.cmake" <<EOF
set(CMAKE_SYSTEM_NAME FreeBSD)
set(CMAKE_SYSTEM_VERSION 15.1)
set(CMAKE_SYSTEM_PROCESSOR $proc)
set(CMAKE_SYSROOT "$SYSROOT")
set(CMAKE_C_COMPILER "$CROSS_BINDIR/clang")
set(CMAKE_CXX_COMPILER "$CROSS_BINDIR/clang++")
set(CMAKE_C_COMPILER_TARGET $CROSS_TRIPLE)
set(CMAKE_CXX_COMPILER_TARGET $CROSS_TRIPLE)
set(CMAKE_AR "$CROSS_BINDIR/llvm-ar" CACHE FILEPATH "")
set(CMAKE_RANLIB "$CROSS_BINDIR/llvm-ranlib" CACHE FILEPATH "")
set(CMAKE_NM "$CROSS_BINDIR/llvm-nm" CACHE FILEPATH "")
set(CMAKE_OBJCOPY "$CROSS_BINDIR/llvm-objcopy" CACHE FILEPATH "")
set(CMAKE_STRIP "$CROSS_BINDIR/llvm-strip" CACHE FILEPATH "")
set(CMAKE_READELF "$CROSS_BINDIR/llvm-readelf" CACHE FILEPATH "")
set(CMAKE_C_FLAGS_INIT "-ffile-prefix-map=$BUILD=/usr/src")
set(CMAKE_CXX_FLAGS_INIT "-ffile-prefix-map=$BUILD=/usr/src")
set(CMAKE_EXE_LINKER_FLAGS_INIT "--ld-path=$CROSS_BINDIR/ld.lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "--ld-path=$CROSS_BINDIR/ld.lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "--ld-path=$CROSS_BINDIR/ld.lld")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
    PKG_CONFIG_LIBDIR="$SYSROOT/usr/libdata/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
    cmake -G Ninja -S "$SRCDIR" -B "$COMP_BUILD/b" \
        -DCMAKE_TOOLCHAIN_FILE="$COMP_BUILD/nextbsd-$T.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_DATA_DIR="share/cmake-$mm" \
        -DCMAKE_DOC_DIR="share/doc/cmake-$mm" \
        -DCMAKE_MAN_DIR=share/man \
        -DCMAKE_XDGDATA_DIR=share \
        -DBUILD_TESTING=OFF \
        -DBUILD_CursesDialog=OFF \
        -DBUILD_QtDialog=OFF \
        -DSPHINX_MAN=OFF -DSPHINX_HTML=OFF \
        -DCMAKE_USE_SYSTEM_LIBRARIES=OFF \
        -DCMAKE_USE_SYSTEM_LIBRARY_LIBARCHIVE=ON \
        -DCMAKE_USE_SYSTEM_LIBRARY_CURL=ON \
        -DCMAKE_USE_SYSTEM_LIBRARY_ZLIB=ON
    ninja -C "$COMP_BUILD/b" $JOBS
    DESTDIR="$COMP_ROOT" ninja -C "$COMP_BUILD/b" install/strip
    rm -rf "$COMP_ROOT/usr/share/emacs" "$COMP_ROOT/usr/share/vim"

    b="$COMP_ROOT/usr/bin"
    for f in cmake ctest cpack; do
        elf_check "$b/$f"
    done
    [ -e "$b/ccmake" ] && fail "ccmake was staged"
    [ -e "$b/cmake-gui" ] && fail "cmake-gui was staged"
    needed_check "$b/cmake" libarchive
    needed_check "$b/cmake" libcurl
    needed_check "$b/cmake" libz
    "$READELF" -d "$b/cmake" | grep NEEDED | sed 's/^/    /'
    [ -f "$COMP_ROOT/usr/share/cmake-$mm/Modules/CMakeDetermineCCompiler.cmake" ] \
        || fail "CMake's modules are not in /usr/share/cmake-$mm"
    strings -a "$b/cmake" | grep -F "/share/cmake-$mm" >/dev/null || fail "cmake does not look in /usr/share/cmake-$mm"
    # The one bash script is the preprocessor wrapper for IBM's XL Fortran
    # compiler (AIX and Linux only), which CMake runs only with that compiler.
    script_check "$COMP_ROOT" "/usr/share/cmake-$mm/Modules/Compiler/XL-Fortran/cpp"
    no_build_paths "$COMP_ROOT"
    stage "$COMP_ROOT"
    note "cmake: $(du -sh --apparent-size "$COMP_ROOT" | cut -f1) ($(find "$COMP_ROOT" -type f | wc -l) files)"
}

# base_collision_check: nothing staged may replace a file the sysroot (base,
# plus nextbsd-userland where it is staged) already has.
base_collision_check() {
    local f hits=
    while IFS= read -r f; do
        if [ -e "$SYSROOT/$f" ] || [ -L "$SYSROOT/$f" ]; then
            [ -d "$SYSROOT/$f" ] && continue
            hits="$hits $f"
        fi
    done < <(cd "$DESTDIR" && find . ! -type d | sed 's|^\./||')
    [ -z "$hits" ] || fail "staged files the base sysroot already has:$hits"
    note "nothing staged replaces a base file"
}

COMPONENTS="gmake pkgconf git m4 perl autoconf automake libtool cmake"
if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $COMPONENTS " in *" $c "*) ;; *) fail "unknown component '$c' (known: $COMPONENTS)" ;; esac
    done
    COMPONENTS="$*"
fi

echo "NextBSD-toolchain tools: building [$COMPONENTS] for $T/$TA into $DESTDIR"
mkdir -p "$DESTDIR" "$BUILD"
for c in $COMPONENTS; do
    start=$(date +%s)
    "build_$c"
    note "$c took $(( $(date +%s) - start )) s"
done
base_collision_check
rm -rf "$BUILD"
