#!/usr/bin/env bash
# =============================================================================
# build-tools.sh: gmake, pkgconf and Apple's Git that run ON NextBSD
# (nextbsd-toolchain#16)
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
# is built; the series are empty today (nothing needs patching).
#
# EXECUTION CONTEXT
#   Inside the nextbsd-kernel-toolchain container, with compat's `continuous`
#   base and nextbsd-userland's `continuous` tree (for libcurl, which Git's
#   http/https transport links) extracted together in $SYSROOT.
#
# USAGE
#   ./build-tools.sh                 gmake pkgconf git
#   ./build-tools.sh git             one component
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
    "$READELF" -h "$1" | grep -q 'OS/ABI:.*FreeBSD' || fail "$1 is not a FreeBSD ELF"
    note "$(basename "$1"): $("$READELF" -h "$1" | sed -n 's/^ *Machine: *//p')"
}
needed_check() {
    "$READELF" -d "$1" | grep -q "NEEDED.*$2" || fail "$1 missing DT_NEEDED $2"
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
    strings "$DESTDIR/usr/bin/pkgconf" | grep -qx "$pcpath" \
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
    strings "$g" | grep -qx /usr/share/git-core/gitconfig \
        || fail "git's system config is not /usr/share/git-core/gitconfig"
    note "git-core: $(find "$x" -type f | wc -l) files, $(find "$x" -type l | wc -l) links"
    return 0
}

COMPONENTS="gmake pkgconf git"
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
rm -rf "$BUILD"
