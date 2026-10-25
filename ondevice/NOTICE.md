# NextBSD-toolchain: licences

The licences of what the `NextBSD-toolchain` package ships, checked against each pinned tarball
(`sources.env`, `../llvm/source.env`). The repo's own scripts are under its BSD 2-Clause `LICENSE`.

NextBSD-toolchain is an optional package: it's installed by default on Gershwin images only and isn't part of
`NextBSD-everything` (E24 D11). The GPL programs in it are build tools a user runs on their own machine. Nothing
in base links them, and base doesn't depend on them.

| Component | Version | Licence | Licence file in the tarball |
|---|---|---|---|
| clang, lld, LLVM binutils | 19.1.7 | Apache-2.0 WITH LLVM-exception | `llvm/LICENSE.TXT`, `clang/LICENSE.TXT`, `lld/LICENSE.TXT` |
| GNU make (`gmake`) | 4.4.1 | GPL-3.0-or-later | `COPYING` |
| pkgconf | 2.5.1 | ISC | `COPYING` |
| Git (Apple's `Git-155`) | 2.50.1 | GPL-2.0-only (some files LGPL-2.1, see Git's `COPYING`) | `src/git/COPYING`, `src/git/LGPL-2.1` |
| GNU m4 (`gm4`) | 1.4.21 | GPL-3.0-or-later | `COPYING` |
| Perl (private to autotools) | 5.44.0 | Artistic-1.0-Perl OR GPL-1.0-or-later | `Artistic`, `Copying` |
| perl-cross (build only, nothing of it is installed) | 1.6.5 | Artistic-1.0-Perl OR GPL-1.0-or-later | upstream `LICENSE` (not in the release tarball) |
| GNU Autoconf | 2.73 | GPL-3.0-or-later; `configure` scripts it generates fall under the Autoconf Configure Script Exception | `COPYINGv3`, `COPYING.EXCEPTION` |
| GNU Automake | 1.19 | GPL-2.0-or-later; the files it copies into packages (`install-sh`, `Makefile.in` fragments, `aclocal` macros, ...) carry their own permissive notices or the Autoconf exception | `COPYING` |
| GNU Libtool (`libtool`, `libtoolize`, macros) | 2.6.2 | GPL-2.0-or-later with the Libtool exception for the files `libtoolize` copies into packages (`ltmain.sh`, `libtool.m4`, ...) | `COPYING` |
| CMake (`cmake`, `ctest`, `cpack`) | 4.4.4 | BSD-3-Clause | `LICENSE.rst` (installed as `/usr/share/doc/cmake-4.4/LICENSE.rst`) |

CMake builds in its bundled copies of the libraries base doesn't provide:

| Bundled in CMake | Licence | File |
|---|---|---|
| KWSys, KWIML, cmelf, llpkgc | BSD-3-Clause (cmelf: BSD-2-Clause, from FreeBSD) | `Source/kwsys/Copyright.txt`, `Utilities/KWIML/Copyright.txt` |
| expat | MIT | `Utilities/cmexpat/COPYING` |
| libuv | MIT | `Utilities/cmlibuv/LICENSE` |
| JsonCpp | MIT (or public domain) | `Utilities/cmjsoncpp/LICENSE` |
| librhash | 0BSD | `Utilities/cmlibrhash/COPYING` |
| cppdap | Apache-2.0 | `Utilities/cmcppdap/LICENSE` |

CMake links these from the system instead: base's libarchive (BSD-2-Clause) and zlib (Zlib), and
nextbsd-userland's libcurl (Apple's curl, curl licence). Its bundled curl, nghttp2, libarchive, zlib, bzip2,
liblzma and zstd aren't built.
