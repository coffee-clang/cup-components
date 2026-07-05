# Dependencies

This document describes the dependencies used by `cup-components` to build, package, test and publish component archives.

End users of `cup` do not need these dependencies. They install prebuilt archives through `cup`. The dependencies listed here are required by CI workflows and by developers running component builds manually.

## 1. Dependency groups

The repository uses separate dependency groups:

```text
workflow dependencies
  GitHub Actions, Docker, MSYS2 and macOS runners

shared packaging dependencies
  tools used by all package scripts

per-tool build dependencies
  compilers, build systems, libraries and language runtimes required by each upstream project

package test dependencies
  tools used to validate produced archives

publishing dependencies
  tools used to upload release assets
```

## 2. Shared packaging tools

The shared packaging scripts require common command-line tools:

```text
bash
curl
tar
gzip
bzip2
xz
zip
unzip
patch
file
find
sed
grep
awk
```

Build scripts also use:

```text
make
cmake
ninja
pkg-config or pkgconf
python
```

The exact dependency set depends on the selected tool and host platform.

## 3. Linux Docker environments

Linux builds run inside Docker containers based on Ubuntu 24.04.

### 3.1 toolchain-builder image

`docker/toolchain-builder.Dockerfile` is used for GCC, GDB and Valgrind builds.

It installs general build tools:

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
```

It also installs toolchain libraries used by GCC/GDB/Valgrind builds:

```text
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
openmpi-bin
libopenmpi-dev
libc6-dbg
```

On amd64 runners it also installs:

```text
libipt-dev
```

### 3.2 llvm-builder image

`docker/llvm-builder.Dockerfile` is used for LLVM tool builds on Linux.

It installs:

```text
build-essential
ca-certificates
cmake
curl
file
ninja-build
patch
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

## 4. Windows MSYS2 environments

Windows builds use MSYS2 through `msys2/setup-msys2`.

Two environments are used:

```text
UCRT64
  GCC and GDB packages

CLANG64
  LLVM tool packages
```

### 4.1 UCRT64 packages

`scripts/setup/msys2-ucrt64-packages.txt` installs packages for GCC/GDB style builds:

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

### 4.2 CLANG64 packages

`scripts/setup/msys2-clang64-packages.txt` installs packages for LLVM builds:

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
mingw-w64-clang-x86_64-doxygen
```

The CLANG64 environment is used because LLVM runtime packages are built with Clang, LLD, compiler-rt, libc++ and libunwind semantics rather than GCC/libstdc++ semantics.

## 5. macOS build environment

macOS LLVM builds run on GitHub-hosted macOS runners.

`scripts/setup/setup-macos-builder.sh` requires Homebrew and installs:

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

The setup script also populates:

```text
CMAKE_PREFIX_PATH
PKG_CONFIG_PATH
GITHUB_PATH
```

with Homebrew prefixes required by the LLVM build.

macOS builds use the active macOS SDK through `xcrun` when configuring LLVM runtime builds.

## 6. Upstream source archives

The shared packaging helpers download upstream source releases from the corresponding project release locations.

Current source families are:

```text
GCC
GDB
Binutils
MinGW-w64
LLVM project monorepo
Valgrind
```

Default stable versions configured in the scripts are:

```text
GCC       16.1.0
GDB       17.1
Binutils  2.46.0
MinGW-w64 14.0.0
LLVM      22.1.5
Valgrind  3.27.0
```

But can be specified before building.

Downloaded source archives are cached under:

```text
.cup-build/src
```

## 7. GCC dependencies

GCC builds require:

```text
C and C++ host compilers
make
Autoconf-style build tools supplied by the source tree
GMP
MPFR
MPC
ISL where used by the build
zlib
Binutils
MinGW-w64 for Windows targets
```

The GCC package configuration focuses on:

```text
C frontend
C++ frontend
LTO
OpenMP runtime when available
sanitizer runtime files when available
no multilib
no NLS
release checking
```

Windows target packages require MinGW-w64 headers, CRT and winpthreads.

## 8. GDB dependencies

GDB builds require:

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

Linux builds also use optional libraries when available:

```text
debuginfod
source-highlight
xxhash
babeltrace
Intel PT on supported architectures
```

Windows packages copy required Python runtime files and non-system DLLs into the package root.

## 9. LLVM dependencies

LLVM tool builds require:

```text
CMake
Ninja
Clang or a platform compiler
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

The LLVM monorepo build enables different projects depending on the selected tool:

```text
clang        -> clang;lld
lld          -> lld
lldb         -> clang;lld;lldb
clangd       -> clang;clang-tools-extra
clang-format -> clang
clang-tidy   -> clang;clang-tools-extra
```

Clang runtime packages also build:

```text
compiler-rt
libunwind
libc++abi
libc++
```

The runtime sequence is intentionally split into builtins, C++ runtimes and sanitizer/profile runtimes so the just-built compiler is used consistently.

## 10. Valgrind dependencies

Valgrind builds require Linux and the GNU toolchain image.

The Linux image provides:

```text
build-essential
make
perl
python3
libc debug symbols
OpenMPI development files
```

The package records support for Valgrind tools and MPI wrapper support when available.

## 11. Runtime packaging dependencies

Packages are intended to be self-contained for the selected host and target.

### 11.1 Windows DLL closure

Windows packages use MSYS2 tools to inspect executable imports and copy non-system runtime DLLs from allowed runtime directories.

The packaging helpers treat Windows system DLLs as external system dependencies and do not bundle them. Runtime DLLs from MSYS2/MinGW environments are bundled when required.

Python-based packages copy the Python runtime files and create `_pth` files so packaged executables can find the bundled Python library tree.

### 11.2 GCC target runtime

GCC Windows target packages include MinGW-w64 target files and binutils in the target layout.

GCC Linux native packages include the GCC target layout expected by the compiler. The internal GCC target name can be canonicalized by GCC/Binutils and may differ from the simpler platform triple used by the packaging script.

### 11.3 LLVM runtime files

Clang packages include compiler runtime files in Clang's resource directory. On Windows, sanitizer runtime DLLs are also copied where the packaged compiler and produced binaries can find them.

## 12. Test dependencies

Linux and macOS package tests use shell scripts under:

```text
scripts/test/
```

Windows package tests use PowerShell scripts under the same directory.

The tests require basic platform tools and the produced package itself. Compiler packages are tested by compiling and running small programs. Runtime-related tests cover features such as:

```text
C compilation
C++ compilation
pthread behavior
OpenMP behavior
LTO where applicable
AddressSanitizer where applicable
UndefinedBehaviorSanitizer where applicable
LLVM frontend availability
GDB/LLDB startup behavior
Valgrind tool execution
```

The package capability scripts read `info.txt` and compare metadata against the files found in the package root. `scripts/test/test-package-checksums.sh` separately verifies both the valid archive set and a deliberate tampering failure.

## 13. Publishing dependencies

GitHub Actions workflows use:

```text
actions/checkout
actions/upload-artifact
msys2/setup-msys2
gh release commands
```

The `publish` workflow input controls whether the build uploads workflow artifacts or creates/updates GitHub Release assets.

When publishing is enabled, the workflow uses the provided GitHub token to run:

```text
gh release view
gh release upload --clobber
gh release create
```

Final archives, `release.env` and the verified `SHA256SUMS` file are uploaded. The checksum file is produced with the platform SHA-256 utility and sorted by archive filename for deterministic output.

## 14. Relation to cup dependencies

The dependencies in this document are not dependencies of the installed `cup` executable.

`cup` needs libcurl/libarchive and its own bootstrap assets. `cup-components` needs large compiler/debugger build environments. This separation keeps end-user installation small and keeps the expensive tool builds inside CI or controlled developer environments.
