# Dependencies

`cup-components` uses dependencies for several different purposes. Keeping those purposes separate is important because a library needed to build a tool is not automatically a file that belongs in the final package.

For package runtime closure, see [Packages](PACKAGES.md#runtime-closure). For the package policy of each tool, see [Tool packages](TOOLS.md).

## Dependency categories

| Category | Meaning | Part of package identity? |
| --- | --- | --- |
| Main upstream source | Source release of the tool being packaged | Yes: its selected version is the package version |
| Logical composition component | Independently versioned component deliberately included in another logical package | Only where the package model says so |
| Build dependency | Compiler, build utility, header or library needed while building | No |
| Runtime dependency | Library or runtime file required by the finished host process | No; included in the package when required |
| Operating-system runtime | Runtime deliberately supplied by the host operating system | No |
| Build environment | Docker, MSYS2, Homebrew and runner configuration used to perform the build | No |

GCC is currently the only revision-bearing package family because its logical package composition contains independently versioned Binutils and, for Windows targets, MinGW-w64. The revision model is documented in [Specification](SPECIFICATION.md#gcc-composition-revision).

## GCC logical composition

The package relationship is:

```text
native Linux GCC
  selected GCC
  selected Binutils

Windows-target GCC
  selected GCC
  selected Binutils
  selected MinGW-w64
```

The current default versions are defined in [Specification](SPECIFICATION.md#tools-and-versions). They are not a compatibility table: GCC, Binutils and MinGW-w64 can be selected independently for a build. A different composition must be assigned the intended GCC package revision.

Standalone GNU ld uses Binutils as its main source rather than as an internal component of another package, so standalone ld is revisionless.

GDB/LLDB Python runtimes, runtime libraries copied during closure, Homebrew packages and MSYS2 packages are not revision-driving components.

LLVM subprojects such as Clang, LLD, LLDB, compiler-rt, libc++, libc++abi, libunwind and clang-tools-extra all come from the same selected LLVM project release in this repository.

## Common packaging tools

Common build/package handling uses normal platform utilities such as:

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

Windows runtime closure uses the PE/DLL inspection tools available in the selected MSYS2 environment.

These commands are build-machine dependencies. Their presence does not make them package payload.

## Linux build environments

Linux builds use two Ubuntu 24.04 Docker images stored in the repository.

### GNU toolchain image

`docker/toolchain-builder.Dockerfile` builds GCC, GNU ld, GDB and Valgrind.

It installs:

```text
build-essential
binutils
ca-certificates
curl
wget
file
flex
gawk
gettext
bison
libtool
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

On x64 Linux builders it also installs:

```text
libipt-dev
```

Some packages are used only by one of the tool families sharing this image. The image is a common build environment; its entire installed package set is not copied into each produced tool package.

### LLVM image

`docker/llvm-builder.Dockerfile` builds LLVM-family tools on Linux.

It installs:

```text
build-essential
binutils
ca-certificates
cmake
curl
file
ninja-build
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

These dependencies provide the CMake/Ninja build environment and the optional libraries used by selected LLVM/LLDB configurations.

## Windows build environments

Windows workflows use MSYS2 through `msys2/setup-msys2`.

Two environments are deliberate:

- `UCRT64` for GCC, GNU ld and GDB;
- `CLANG64` for LLVM-family tools.

`scripts/setup/setup-windows-msys2.sh` reads the corresponding package list from the repository.

### UCRT64 package list

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

### CLANG64 package list

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

CLANG64 is used for the LLVM-family Windows build so its compiler and C++ runtime model matches the selected LLVM-oriented environment.

## macOS build environment

macOS LLVM-family builds use GitHub-hosted macOS runners and Homebrew.

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

The setup exports the required Homebrew prefixes through `CMAKE_PREFIX_PATH`, `PKG_CONFIG_PATH` and the workflow path.

The active macOS SDK is selected with `xcrun`.

Homebrew installation paths are temporary build-environment paths. A finished package cannot rely on an absolute Homebrew location for a required non-system runtime library.

## Upstream sources

The repository downloads versioned source releases for:

```text
GCC
Binutils
MinGW-w64
GDB
LLVM project
Valgrind
```

The URL pattern for each family is implemented by `scripts/package/package-common.sh`.

Downloaded archives are cached under:

```text
.cup-build/src
```

The current stable source releases have built-in SHA-256 values. Other explicit numeric versions remain valid inputs and can optionally receive a `source_sha256` value at workflow start.

See [Build](BUILD.md#source-acquisition) for the acquisition sequence.

## GCC build dependencies

GCC uses a C/C++ host compiler, Make and the build tools required by the GCC source tree.

On Linux, GCC's own `contrib/download_prerequisites` helper prepares the upstream prerequisite source set used by GCC, including GMP, MPFR, MPC and ISL.

On Windows-native builds, the corresponding toolchain libraries are provided by the UCRT64 environment.

Binutils is not merely a temporary build dependency of the GCC package: it is a deliberate logical package-composition component. Windows-target GCC additionally includes MinGW-w64 target headers, CRT and winpthreads as part of the target toolchain.

The current GCC recipe builds C, C++, LTO and OpenMP support, disables multilib and NLS, and includes the selected native Linux sanitizer runtime files where applicable.

## GNU ld build dependencies

Standalone GNU ld is built from the selected Binutils source release with the normal GNU configure/Make build path.

The build requires a host C compiler, Make and the common archive/package utilities. The final package deliberately keeps the linker commands rather than the complete Binutils toolbox.

## GDB build dependencies

GDB uses a C/C++ host compiler, Make, Python and the platform libraries required by the configured debugger features.

The current Linux environment provides build inputs for capabilities such as:

```text
readline / terminal UI
Expat
zlib
LZMA
Zstandard
debuginfod
GNU Source Highlight
xxHash
Babeltrace
Intel Processor Trace on x64
```

Python and the text user interface are required capabilities in the current GDB recipe. Other integrations are enabled when the selected GDB source release exposes the corresponding configure option and the build environment provides the required input.

These development packages are not copied wholesale into GDB. After GDB's public/runtime package roots are selected, normal platform runtime closure includes only the required non-system runtime files.

## LLVM build dependencies

LLVM-family builds use CMake, Ninja, the platform compiler, Python and the build utilities required by the selected LLVM projects.

LLDB additionally uses Python, SWIG, libxml2, LZMA and terminal-editing support according to the selected platform recipe.

Each LLVM-family package configures only the LLVM projects needed to produce its declared payload. The exact per-tool project selection is owned by [Tool packages](TOOLS.md#llvm-project-selection).

Clang package construction also builds these LLVM runtime groups:

```text
compiler-rt
libunwind
libc++abi
libc++
```

Because these projects come from the same selected LLVM release, they do not create independent package revisions.

Windows Clang additionally materializes a MinGW target sysroot from the MSYS2 Clang64 environment. Package metadata records the provider and exact MSYS2 headers, CRT and winpthreads versions whose bytes are copied. These builder-provided component versions are provenance for the realized target sysroot; they are not independent CUP version-selection inputs or revision-driving source components. Linux Clang intentionally relies on the host native C/C++ development environment for its default system headers/libraries and platform linker, while macOS Clang relies on the Apple developer tools/SDK and uses xcselect SDK discovery.

## Valgrind build dependencies

Valgrind is built only on Linux with the GNU toolchain image.

The build uses the host compiler, Make, Perl and libc debug symbols required by the current recipe and package checks.

MPI support is disabled for the distributed package. The optional GDB Python front-end is not included, while core `vgdb` functionality remains part of the package when the selected release provides it.

## Runtime dependency ownership

The runtime-closure mechanism is shared by host platform, but each package starts from its own selected roots.

Examples:

| Package | Runtime responsibility |
| --- | --- |
| GCC | GCC runtimes, selected Binutils composition and target MinGW-w64 material where required |
| GNU ld | standalone linker commands and their required host runtime libraries |
| GDB | GDB command/data, package-owned Python and the libraries required by enabled debugger features |
| Clang | Clang resources, compiler runtimes, packaged C++ runtime capability, native LLD integration payload and the Windows MinGW target sysroot where applicable |
| LLD | the host-native LLD frontend (plus any private POSIX backing executable) and its required host runtime libraries |
| LLDB | LLDB commands, package-owned Python, Clang resources and required debugger libraries |
| clang-format | formatter command only; no Git/Python dependency for `git-clang-format` |
| clang-tidy | tidy commands plus `run-clang-tidy`/`clang-tidy-diff` and their package-owned Python runtime |
| clangd | language server and matching Clang built-in headers; the standalone indexer is outside the package contract |
| Valgrind | Valgrind runtime objects, `vgdb`, public client headers and relocatable pkg-config metadata |

The operating system supplies the base runtime defined in [Packages](PACKAGES.md#self-contained-package-boundary). Every other realized host runtime dependency must be package-owned if the tool requires it.
