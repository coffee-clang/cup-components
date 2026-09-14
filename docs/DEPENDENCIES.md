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

## Build environments

The repository keeps platform build environments separate from package ownership. Their installed package sets provide compilers, build systems, headers and libraries from which a producer may build a tool; only files selected by the producer and required by runtime closure become package content.

### Linux

Linux builds use two Ubuntu 24.04 images owned by the repository:

- `docker/toolchain-builder.Dockerfile` for GCC, GNU ld, GDB and Valgrind;
- `docker/llvm-builder.Dockerfile` for LLVM-family tools.

The toolchain image provides the GNU build stack plus the development libraries needed by GDB/Valgrind and GCC-family builds. The LLVM image provides CMake/Ninja, Clang/LLVM build prerequisites and the Python/SWIG/XML/terminal/compression development inputs needed by LLDB and the other selected LLVM projects. Architecture-specific additions, such as Intel Processor Trace support on Linux x64, remain build-environment details rather than package-wide dependencies.

The Dockerfiles are the source of truth for the exact installed package set. Keeping that inventory there avoids duplicating a list that must otherwise be synchronized with the actual builder image.

### Windows

Windows workflows use MSYS2 through `msys2/setup-msys2` with two deliberate environments:

- `UCRT64` for GCC, GNU ld and GDB;
- `CLANG64` for LLVM-family tools.

`scripts/setup/setup-windows-msys2.sh` installs the corresponding repository-owned package list. The exact lists are maintained in `scripts/setup/msys2-ucrt64-packages.txt` and `scripts/setup/msys2-clang64-packages.txt`. UCRT64 supplies the GNU-oriented compiler/build environment and debugger dependencies; CLANG64 supplies the LLVM-oriented compiler/runtime environment, CMake/Ninja, Python/SWIG and the libraries needed by LLVM/LLDB.

For Windows Clang, selected MSYS2 files have an additional role: the producer materializes the MinGW target headers, CRT and winpthreads into the package-owned target sysroot and records their provider/version provenance. That deliberate target payload is distinct from treating the whole CLANG64 environment as package content.

### macOS

macOS LLVM-family builds use GitHub-hosted macOS runners plus `scripts/setup/setup-macos-builder.sh`. The setup installs the CMake/Ninja build stack and the Python/SWIG, compression, XML and terminal-editing dependencies required by the selected LLVM/LLDB configuration, then exports the relevant Homebrew prefixes through `CMAKE_PREFIX_PATH`, `PKG_CONFIG_PATH` and the workflow path.

The setup script is the source of truth for the exact Homebrew formula set. The active macOS SDK is selected with `xcrun`. Homebrew installation paths are temporary build-environment paths: a finished package cannot rely on an absolute Homebrew location for a required non-system runtime library.

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

LLDB additionally uses Python, SWIG, libxml2, LZMA and terminal-editing support according to the selected platform recipe. Windows LLD also enables libxml2 for its COFF configuration; any resulting non-system runtime DLLs are handled by the normal Windows runtime-closure mechanism rather than by copying the build environment wholesale.

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
