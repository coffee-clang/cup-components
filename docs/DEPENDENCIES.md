# Dependencies

A dependency can be needed to **build** a tool without belonging to the package that
cup installs. `cup-components` keeps build inputs, logical package components, runtime
dependencies and operating-system responsibilities separate so the final package does
not accidentally inherit its builder environment.

For runtime closure, see [Packages](PACKAGES.md#runtime-closure). For tool-owned payload,
see [Tool packages](TOOLS.md).

## Dependency model

| Kind | Responsibility | Package payload? |
| --- | --- | --- |
| Primary upstream source | source release of the selected tool | source provenance only |
| Logical composition component | independently selected component deliberately bundled into one logical package | when that package model owns it |
| Build dependency | compiler, build system, headers, development libraries, utilities | no |
| Host runtime dependency | file required by the finished packaged process | yes when non-system and required |
| Operating-system runtime | runtime deliberately supplied by the host OS | no |
| Builder environment | Docker/MSYS2/Homebrew/runner configuration | no |

Package revision is a common producer dimension and is independent of dependency type.
GCC additionally owns independently selected Binutils and, for Windows targets,
MinGW-w64 as logical package composition. Those concrete component versions remain
explicit metadata; they do not create a second revision scheme.

LLVM subprojects such as Clang, LLD, LLDB, compiler-rt, libc++, libc++abi, libunwind and
clang-tools-extra all come from the same selected LLVM project release and therefore do
not form independently versioned package-composition components.

## Build environments

The environment files are the source of truth for exact build-machine packages. This
document describes their role rather than duplicating inventories that would have to be
kept synchronized manually.

### Linux

Linux builds use repository-owned Ubuntu 24.04 images:

- `docker/toolchain-builder.Dockerfile` for GCC, GNU `ld`, GDB and Valgrind;
- `docker/llvm-builder.Dockerfile` for LLVM-family tools.

They provide the compilers, build systems, development headers/libraries and packaging
utilities required by those families. Architecture-specific build inputs remain
builder details unless a selected tool explicitly owns them as package payload.

### Windows

Windows builds use MSYS2:

- UCRT64 for GCC, GNU `ld` and GDB;
- CLANG64 for LLVM-family tools.

`scripts/setup/setup-windows-msys2.sh` installs the repository-owned package list from
`scripts/setup/msys2-ucrt64-packages.txt` or
`scripts/setup/msys2-clang64-packages.txt`.

Windows Clang is the deliberate exception where selected environment files become
product input: the producer materializes the MinGW target headers, CRT and winpthreads
into the package sysroot and records the exact provider versions. That does not make the
rest of CLANG64 package-owned.

### macOS

macOS LLVM builds use the GitHub macOS runner plus
`scripts/setup/setup-macos-builder.sh`. That script owns the Homebrew formula set and
exports the prefixes required by CMake and `pkg-config`.

The Apple SDK is discovered with `xcrun`. Homebrew paths are build-time paths; required
non-system runtime libraries must be packaged and made relocatable rather than left as
absolute Homebrew dependencies.

## Common build and packaging tools

Repository automation relies on ordinary host utilities such as Bash, `curl`, `tar`,
`xz`, `gzip`, `zip`/`unzip`, `find`, `file` and SHA-256 tooling.

Runtime closure additionally uses platform-format tools:

- Linux: `readelf`, `ldd`, `realpath`, `patchelf`;
- macOS: `otool`, `install_name_tool`, `codesign`;
- Windows: PE/import inspection tools provided by the selected MSYS2 environment.

These utilities help construct or inspect packages; they are not package payload merely
because the producer uses them.

## Upstream sources

The repository acquires versioned source releases for:

```text
GCC
Binutils
MinGW-w64
GDB
LLVM project
Valgrind
```

Family URL construction and configured default-source digests are owned by
`scripts/package/package-common.sh`. The source cache is `.cup-build/src`.

Configured default archives are digest-verified before extraction. An explicit numeric
version remains a valid build input even when the repository has no built-in digest for
it; the caller can supply `source_sha256` to bind that build to exact source bytes. See
[Build](BUILD.md#source-acquisition).

## Tool-specific build inputs

### GCC and GNU `ld`

GCC uses the normal C/C++ GNU build stack. On Linux its upstream
`contrib/download_prerequisites` helper prepares GCC prerequisite sources such as GMP,
MPFR, MPC and ISL. Native Windows builds instead consume the corresponding UCRT64 build
environment.

Binutils is different from those ordinary prerequisites: a selected Binutils release is
a deliberate component of a GCC package. A Windows-target GCC also deliberately owns a
selected MinGW-w64 target toolchain. Standalone GNU `ld` uses Binutils as its primary
source rather than as a nested component.

### GDB

GDB builds use the host compiler/build stack, Python and the development inputs needed
by the selected debugger configuration. The Linux environment can provide terminal/TUI,
Expat, compression, debuginfod, Source Highlight, xxHash, Babeltrace and Intel Processor
Trace support where applicable.

Python and TUI are required by the current package policy. Other integrations remain
configuration/runtime-content facts unless they correspond to a deliberately validated
product capability. Development packages are never copied wholesale; the normal runtime
closure starts only from the selected GDB product roots.

### LLVM family

LLVM builds use CMake, Ninja, the platform compiler and the inputs required by the
selected LLVM projects. LLDB additionally needs Python, SWIG and its configured
XML/compression/terminal dependencies. Windows LLD also enables libxml2 for its COFF
configuration.

Clang package construction builds compiler-rt, libunwind, libc++abi and libc++ from the
same LLVM source release. Windows Clang additionally owns the selected MinGW target
sysroot described above. Linux and macOS Clang deliberately retain platform-owned native
development prerequisites instead of copying an entire system SDK/toolchain into the
package; these are explicit `requires.*` metadata where relevant.

### Valgrind

Valgrind is built only on Linux with the GNU toolchain environment. The build uses the
host compiler and normal autotools/packaging stack. Optional upstream surfaces are kept
only when they belong to the product policy described in [Tool packages](TOOLS.md#valgrind).

## Runtime ownership

After a tool-specific package surface is selected, common runtime closure classifies its
host dependencies as either operating-system-provided or package-owned:

- Linux leaves the deliberate glibc/loader boundary to the OS and packages required
  non-base libraries;
- macOS leaves `/usr/lib` and `/System/Library` dependencies to the OS and packages
  required non-system libraries;
- Windows leaves system DLLs to Windows and packages required non-system MSYS2/MinGW
  runtime DLLs.

This classification is about the finished process graph, not where a library happened
to be installed on the build machine. The exact mechanics are defined in
[Packages](PACKAGES.md#runtime-closure).
