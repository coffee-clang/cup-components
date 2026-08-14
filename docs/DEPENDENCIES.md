# Dependencies

`cup-components` uses several different kinds of dependencies. They are intentionally kept separate because only some of them are part of a package's logical composition.

For package runtime-closure mechanics, see [Packages](PACKAGES.md#runtime-dependencies). For build operation, see [Build](BUILD.md).

## Dependency categories

| Category | Meaning | Revision-driving? |
| --- | --- | --- |
| Package composition component | Independently versioned component deliberately included in a logical tool package | Only when the package identity contract says so |
| Build dependency | Compiler, build tool, header or library needed to build the selected upstream tool | No |
| Runtime closure dependency | Non-base library/runtime file needed by the finished host process and packaged when required | No |
| Base/system dependency | ABI or library deliberately supplied by the host operating system | No |
| Builder environment | Docker, MSYS2, Homebrew and runner environment used to execute the build | No |
| Upstream source | Versioned source release from which a tool/component is built | Main tool version or selected composition component, as defined by package identity |

An ordinary dependency does not increment package revision. Revision is defined by the package identity model in [Specification](SPECIFICATION.md#revision-semantics).

## Package composition components

GCC is the current revision-bearing family. The concrete versions below describe the current `stable` composition; they are not a closed list of GCC versions that the operator may build.

```text
native Linux GCC
  GCC 16.1.0
  Binutils 2.46.0

Windows-target GCC
  GCC 16.1.0
  Binutils 2.46.0
  MinGW-w64 14.0.0
```

This composition is `rev1` for GCC 16.1.0. Other GCC main versions have distinct package identities, and revision distinguishes separately selected internal composition only within the same main version.

GDB's Python runtime, LLDB's Python runtime, runtime libraries copied during closure, Homebrew packages and MSYS2 packages are not revision-driving components.

LLVM subprojects such as Clang, LLD, LLDB, compiler-rt, libc++, libc++abi, libunwind and clang-tools-extra come from the same selected LLVM project release in this producer model; their presence does not create an independent package revision.

## Shared packaging tools

Common packaging and validation use standard platform tools. Depending on the host, these include:

```text
bash
curl
tar
xz
gzip
zip
unzip
find
file
sha256sum or shasum
```

Linux runtime closure also uses:

```text
readelf
ldd
realpath
patchelf
```

macOS runtime closure uses:

```text
file
otool
install_name_tool
codesign
```

Windows closure uses the MSYS2/MinGW inspection/runtime tools provided by the selected environment.

These are producer/build dependencies, not files that automatically become package payload.

## Linux builder environments

Linux builds use two Ubuntu 24.04 Docker images defined in the repository.

### GNU toolchain builder

`docker/toolchain-builder.Dockerfile` is used for GCC, GDB and Valgrind.

It installs:

```text
build-essential
ca-certificates
curl
wget
file
flex
bison
make
patch
patchelf
perl
python3
python3-dev
tar
texinfo
unzip
xz-utils
bzip2
zip
pkg-config
libgmp-dev
libmpfr-dev
libreadline-dev
libexpat1-dev
zlib1g-dev
libncurses-dev
liblzma-dev
libzstd-dev
libdebuginfod-dev
libsource-highlight-dev
libxxhash-dev
libbabeltrace-dev
libc6-dbg
```

On amd64 builders it also installs:

```text
libipt-dev
```

### LLVM builder

`docker/llvm-builder.Dockerfile` is used for LLVM-family builds on Linux.

It installs:

```text
build-essential
ca-certificates
cmake
curl
file
ninja-build
patch
patchelf
pkg-config
python3
python3-dev
swig
tar
unzip
xz-utils
bzip2
zip
zlib1g-dev
libzstd-dev
libxml2-dev
libedit-dev
libncurses-dev
liblzma-dev
libffi-dev
```

## Windows MSYS2 environments

Windows workflows use MSYS2 through `msys2/setup-msys2`.

`UCRT64` is used for GCC and GDB. `CLANG64` is used for LLVM-family tools.

The text files under `scripts/setup/` are the authoritative package lists consumed by the setup helper.

### UCRT64

`scripts/setup/msys2-ucrt64-packages.txt` contains:

```text
base-devel
git
curl
tar
gzip
bzip2
xz
zip
unzip
patch
texinfo
python
mingw-w64-ucrt-x86_64-gcc
mingw-w64-ucrt-x86_64-binutils
mingw-w64-ucrt-x86_64-make
mingw-w64-ucrt-x86_64-cmake
mingw-w64-ucrt-x86_64-ninja
mingw-w64-ucrt-x86_64-autotools
mingw-w64-ucrt-x86_64-pkgconf
mingw-w64-ucrt-x86_64-gmp
mingw-w64-ucrt-x86_64-mpfr
mingw-w64-ucrt-x86_64-mpc
mingw-w64-ucrt-x86_64-isl
mingw-w64-ucrt-x86_64-readline
mingw-w64-ucrt-x86_64-expat
mingw-w64-ucrt-x86_64-zlib
mingw-w64-ucrt-x86_64-ncurses
mingw-w64-ucrt-x86_64-xz
mingw-w64-ucrt-x86_64-zstd
mingw-w64-ucrt-x86_64-python
```

### CLANG64

`scripts/setup/msys2-clang64-packages.txt` contains:

```text
base-devel
git
curl
tar
gzip
bzip2
xz
zip
unzip
patch
python
mingw-w64-clang-x86_64-clang
mingw-w64-clang-x86_64-compiler-rt
mingw-w64-clang-x86_64-libc++
mingw-w64-clang-x86_64-libunwind
mingw-w64-clang-x86_64-lld
mingw-w64-clang-x86_64-llvm-tools
mingw-w64-clang-x86_64-cmake
mingw-w64-clang-x86_64-ninja
mingw-w64-clang-x86_64-pkgconf
mingw-w64-clang-x86_64-swig
mingw-w64-clang-x86_64-python
mingw-w64-clang-x86_64-zlib
mingw-w64-clang-x86_64-zstd
mingw-w64-clang-x86_64-libxml2
mingw-w64-clang-x86_64-libffi
mingw-w64-clang-x86_64-sqlite3
mingw-w64-clang-x86_64-ncurses
mingw-w64-clang-x86_64-xz
mingw-w64-clang-x86_64-curl
perl
```

CLANG64 is used because the LLVM-family Windows environment is based on Clang/LLD, compiler-rt, libc++ and libunwind rather than the UCRT64 GCC/libstdc++ toolchain.

## macOS builder environment

macOS LLVM builds use GitHub-hosted macOS runners and Homebrew.

`scripts/setup/setup-macos-builder.sh` installs:

```text
bash
cmake
ninja
python
swig
xz
zstd
zlib
libxml2
ncurses
libedit
pkg-config
```

The setup exports the Homebrew prefixes needed through `CMAKE_PREFIX_PATH`, `PKG_CONFIG_PATH` and the workflow path. The active macOS SDK is selected through `xcrun` by the LLVM builder.

Homebrew packages are builder dependencies. Their absolute installation paths are not accepted as final non-system package runtime locations.

## Upstream sources

The producer acquires versioned upstream source archives for:

```text
GCC
Binutils
MinGW-w64
GDB
LLVM project
Valgrind
```

The current `stable` defaults and the operator-selected version model are documented in [Specification](SPECIFICATION.md#tools-and-version-selection).

Downloaded source archives are cached under:

```text
.cup-build/src
```

The repository uses configured official versioned HTTPS source locations and local cached archives. It does not maintain a repository-locked digest/signature table for every accepted explicit source version. `SHA256SUMS` applies to the finished CUP package archives, not to upstream-source authentication.

## GCC build dependencies

GCC builds use C/C++ host compilers, make and the build tooling required by the upstream source tree. The GCC source build also uses the upstream prerequisite set prepared by `contrib/download_prerequisites` (including GMP, MPFR, MPC and ISL). Windows-native preparation instead resolves the corresponding MSYS2 libraries from the UCRT64 environment.

Binutils is a logical GCC package-composition component, not merely a builder utility. Windows targets additionally use MinGW-w64 headers, CRT and winpthreads as part of the target toolchain composition.

The current recipe provides the C and C++ frontends, LTO, OpenMP, no multilib and no NLS. Native Linux builds include the sanitizer runtime files selected by the recipe; the Windows-target recipe does not enable that same sanitizer payload.

## GDB build dependencies

GDB builds use:

```text
C and C++ host compilers
make
readline
expat
zlib
lzma
zstd
Python
ncurses/TUI support
```

The controlled Linux builder also provides:

```text
debuginfod
source-highlight
xxhash
babeltrace
Intel PT support on amd64
```

Python is both a build integration and a deliberate GDB runtime capability. The final package carries the runtime material required by that capability; see [Python runtime](PACKAGES.md#python-runtime).

## LLVM build dependencies

LLVM-family builds use:

```text
CMake
Ninja
Clang or the platform compiler
Python
SWIG for LLDB-related builds
zlib
zstd
libxml2
libedit
ncurses
liblzma
libffi
```

Project selection depends on the requested package:

```text
clang        -> clang;lld
clang-format -> clang
clang-tidy   -> clang;clang-tools-extra
clangd       -> clang;clang-tools-extra
lld          -> lld
lldb         -> clang;lld;lldb
```

Clang package runtime construction also builds:

```text
compiler-rt
libunwind
libc++abi
libc++
```

These LLVM subprojects share the selected LLVM release and are not independent revision-driving components in the current package identity model.

## Valgrind build dependencies

Valgrind is built only on Linux using the GNU toolchain builder. The image supplies the compiler/build tools, Perl and libc debug symbols required by the current build and tests.

MPI development support is not required by the core package because the build uses `--without-mpicc`. The optional GDB Python front-end is not part of the package; core `vgdb` functionality remains included.

## Runtime and base dependencies

Runtime closure may copy non-base dependencies into a package after the upstream tool has been installed into staging. Those copied libraries remain runtime dependencies, not revision-driving composition components.

The deliberate external base is:

- Linux: glibc and loader facilities;
- macOS: Apple system libraries;
- Windows: Windows system DLLs.

The closure algorithms and relocation rules are documented in [Runtime dependencies](PACKAGES.md#runtime-dependencies).

## Test and publication dependencies

Package tests use shell on Linux/macOS and PowerShell on Windows, together with the produced package and normal platform tooling needed by each capability check.

GitHub publication uses the repository workflows, the GitHub token and the GitHub CLI available on the runner. Publication behavior is documented in [Build](BUILD.md#publication).
