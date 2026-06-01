# Specification

This document describes the implemented build and packaging model of `cup-components`.

`cup-components` builds the component archives consumed by `cup`. The repository is responsible for producing self-contained package roots, writing package metadata and publishing archives with names that match the `cup` manifest.

## 1. Scope

The repository provides:

```text
GitHub Actions workflows for component builds
Linux Docker build environments
Windows MSYS2 build environments
macOS Homebrew-based build setup
per-tool build scripts
shared packaging helpers
package metadata generation
package capability tests
release asset publishing
```

The repository does not install packages into an end user's `.cup` directory. It only produces archives. Installation, state management, manifest resolution, doctor/repair and uninstall behavior are implemented by `cup`.

## 2. Package identity

Every package is identified by:

```text
tool
version
host_platform
target_platform
revision when needed
```

The base name is:

```text
<tool>-<package-version>-<host_platform>-<target_platform>
```

The package version is normally the upstream version. A revision suffix is included for recipe-sensitive packages and cross-target packages:

```text
<version>-rev<revision>
```

Examples:

```text
gcc-16.1.0-rev1-linux-x64-linux-x64
gcc-16.1.0-rev1-linux-x64-windows-x64
clang-22.1.5-windows-x64-windows-x64
valgrind-3.27.0-linux-x64-linux-x64
```

The GitHub Release tag is the package base name.

The produced archive names are:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
```

The workflow also writes:

```text
dist/release.env
```

which records the release tag and archive paths for later workflow steps.

## 3. Platform model

Platform identifiers match the identifiers used by `cup`:

```text
linux-x64
linux-arm64
macos-x64
macos-arm64
windows-x64
```

The build scripts map those identifiers to toolchain triples:

```text
linux-x64    -> x86_64-linux-gnu
linux-arm64  -> aarch64-linux-gnu
windows-x64  -> x86_64-w64-mingw32
macos-x64    -> x86_64-apple-darwin
macos-arm64  -> arm64-apple-darwin
```

The package host platform is where the packaged tool runs. The target platform is what the tool targets.

A package may be native:

```text
host_platform == target_platform
```

or target a different platform while still running on the host:

```text
host_platform != target_platform
```

The main non-native package is the Linux-hosted GCC package targeting Windows.

## 4. Supported build matrix

### 4.1 GCC

GCC packages support:

```text
linux-x64   -> linux-x64
linux-arm64 -> linux-arm64
linux-x64   -> windows-x64
windows-x64 -> windows-x64
```

GCC packages include GCC, the required target binutils layout and the runtime pieces needed by the selected target.

The Windows target packages include MinGW-w64 headers, CRT, winpthreads and target-prefixed GCC/binutils entry points.

### 4.2 GDB

GDB packages support:

```text
linux-x64   -> linux-x64
linux-arm64 -> linux-arm64
windows-x64 -> windows-x64
```

GDB packages are native host-target packages.

### 4.3 LLVM tools

The LLVM workflow builds these tools:

```text
clang
lld
lldb
clangd
clang-format
clang-tidy
```

LLVM tool packages support native builds on:

```text
linux-x64
linux-arm64
macos-x64
macos-arm64
windows-x64
```

The workflow rejects LLVM host/target combinations where host and target differ. LLVM target backend selection is based on the selected platform architecture:

```text
x64 platforms   -> X86
arm64 platforms -> AArch64
```

`clang` packages include LLVM runtimes. The runtime build sequence is separated into:

```text
compiler-rt builtins
libunwind + libc++abi + libc++
compiler-rt sanitizers/profile
```

This keeps the runtime order explicit and avoids depending on a single monolithic runtime configuration.

### 4.4 Valgrind

Valgrind packages support:

```text
linux-x64   -> linux-x64
linux-arm64 -> linux-arm64
```

Valgrind is Linux-only. The package uses a relocatable wrapper so the installed tool can find its runtime directory after being installed by `cup`.

## 5. Source versions

The shared packaging helpers define default versions for stable builds:

```text
GCC       16.1.0
GDB       17.1
Binutils  2.46.0
MinGW-w64 14.0.0
LLVM      22.1.5
Valgrind  3.27.0
```

Workflow inputs accept an explicit version, `stable` or `latest`. `stable` and `latest` are resolved by the build scripts to the configured default version for the tool family.

The `cup` manifest then maps the user-facing `stable` release to the concrete package version.

## 6. Shared build directories

The shared packaging code uses these directories:

```text
CUP_ROOT       repository root
CUP_WORK_DIR   .cup-build
CUP_SRC_DIR    .cup-build/src
CUP_BUILD_DIR  .cup-build/build
CUP_STAGE_DIR  .cup-build/stage
CUP_OUT_DIR    dist
```

Source archives are cached under `.cup-build/src`. Build directories are kept under `.cup-build/build`. Package roots are staged under `.cup-build/stage` and temporary package-root directories are kept under `.cup-build/package-root`.

Only final archives and `release.env` are written to `dist`.

## 7. Package root contract

Each package archive has one top-level directory matching the package base name:

```text
<package-base>/
```

Inside that root, the package must include:

```text
info.txt
```

Tool-specific packages commonly include:

```text
bin/
include/
lib/
libexec/
share/
<target-triple>/
```

The exact internal tree depends on the tool. The package must be relocatable under the install path used by `cup`:

```text
~/.cup/components/<component>/<tool>/<host_platform>/<target_platform>/<version>/
```

## 8. Metadata contract

`info.txt` is generated by the build scripts with strict key/value lines.

Required identity fields are:

```text
package.component
package.tool
package.version
platform.host
platform.target
```

Common groups are:

```text
entry.*
features.*
contents.*
config.*
```

### 8.1 Entry metadata

`entry.*` fields describe executable entry points relative to the package root.

Examples:

```text
entry.gcc=bin/gcc
entry.g++=bin/g++
entry.clang=bin/clang
entry.lld=bin/ld.lld
entry.gdb=bin/gdb
```

### 8.2 Feature metadata

`features.*` fields describe capabilities that were built and detected in the staged package.

Examples:

```text
features.c=true
features.cpp=true
features.openmp=true
features.sanitizers=true
features.gdbserver=true
features.link_coff=true
features.background_index=true
```

### 8.3 Contents metadata

`contents.*` fields describe notable files or runtime groups included in the package.

Examples:

```text
contents.self_contained=true
contents.includes_lld=true
contents.includes_mingw=true
contents.libstdcxx=true
contents.asan=true
contents.runtime_dir=libexec/valgrind
```

### 8.4 Configuration metadata

`config.*` fields describe relevant build choices.

Examples:

```text
config.languages=c,c++,lto
config.multilib=false
config.nls=false
config.llvm_projects=clang;lld
config.llvm_targets=X86
config.llvm_runtimes=compiler-rt;libunwind;libcxxabi;libcxx
```

`cup info` displays this metadata after installation.

## 9. Archive formats

The packaging script creates these formats:

```text
tar.xz
tar.gz
zip
```

Windows packages prefer `zip` as the default format in the `cup` manifest. Unix-like packages prefer `tar.gz` as the default format, while `tar.xz` and `zip` are also produced.

Workflow artifacts and release uploads include only final archives and `release.env`; temporary package roots are not uploaded.

## 10. GCC package model

The GCC script builds from upstream GCC source and uses Binutils where required.

Native Linux GCC packages include:

```text
GCC drivers
C and C++ frontend support
LTO support
libstdc++
OpenMP runtime when available
sanitizer runtime files when available
binutils in the GCC target layout
```

GCC may canonicalize the native Linux target triple internally. For example, a Linux x64 package can contain GCC target directories using:

```text
x86_64-pc-linux-gnu
```

That is a GCC/Binutils canonical target name, not a separate package target. The package must not contain redundant competing native Linux target layouts for the same toolchain.

Windows GCC packages include the MinGW-w64 target layout:

```text
x86_64-w64-mingw32/
```

That directory is meaningful because it contains the Windows target sysroot, target libraries, headers and binutils entry points.

## 11. LLVM package model

The LLVM script builds from the monorepo source release.

Tool selection controls the enabled LLVM projects:

```text
clang        -> clang;lld
lld          -> lld
lldb         -> clang;lld;lldb
clangd       -> clang;clang-tools-extra
clang-format -> clang
clang-tidy   -> clang;clang-tools-extra
```

`clang` packages build and install runtime files needed for compiler use. The runtime sequence is:

```text
build compiler-rt builtins
build libunwind, libc++abi and libc++
build compiler-rt sanitizers and profile runtime
copy runtime files into Clang's resource directory
copy sanitizer runtime DLLs where required by the host platform
```

Windows LLVM builds use MSYS2 CLANG64 and explicit MinGW runtime configuration to avoid mixing PE/COFF runtime builds with Unix/ELF linker assumptions.

macOS LLVM builds use the active macOS SDK and Homebrew dependencies while producing native macOS packages for x64 or arm64.

## 12. GDB package model

The GDB script builds from upstream GDB source and records support for optional capabilities detected in the package.

Metadata includes support for:

```text
Python
TUI
readline
expat
zlib
lzma
zstd
debuginfod
source-highlight
xxhash
babeltrace
Intel PT where available
gdbserver where available
```

Windows GDB packages also copy the required non-system runtime DLLs and Python runtime files so the package remains self-contained.

## 13. Valgrind package model

The Valgrind script builds from upstream Valgrind source on Linux.

The package records:

```text
memcheck
cachegrind
callgrind
massif
helgrind
drd
dhat
lackey
exp-bbv
MPI wrapper support when available
relocatable runtime wrapper
```

Valgrind's internal runtime directory is kept in the package and referenced by the wrapper.

## 14. Windows runtime closure

Windows packages are checked for PE runtime dependencies.

The packaging helpers:

```text
collect packaged PE files
inspect imported DLL names
find non-system DLLs in allowed runtime directories
copy required DLLs into the package bin directory
copy Python runtime files when needed
create Python path configuration files when needed
verify that packaged executables no longer depend on missing non-system DLLs
```

System DLLs are not bundled. Runtime DLLs from MSYS2/MinGW environments are bundled when needed by packaged executables.

## 15. Tests

Each workflow runs package tests after building.

Linux and macOS tests extract the package and run shell-based checks. Windows tests use PowerShell.

The tests verify:

```text
required executables exist
version commands work
info.txt metadata is readable
feature metadata matches expected files
runtime DLL closure on Windows
basic compile/link behavior for compilers
OpenMP, pthread, LTO and sanitizer behavior where applicable
GDB and LLDB basic startup behavior
LLVM tool frontends and helper tools
Valgrind runtime behavior
```

The generic package capability scripts can print a summary of entries, contents, configuration and features for a produced package.

## 16. Release publishing

Each workflow has a `publish` input.

When `publish` is false, the final archives are uploaded as workflow artifacts.

When `publish` is true, the workflow creates or updates the GitHub Release named after the package base:

```text
<tool>-<version>[-revN]-<host_platform>-<target_platform>
```

Existing release assets are overwritten with `--clobber` so a recipe revision can be republished under the intended release tag when appropriate.

## 17. Relation to cup

`cup-components` produces release assets. `cup` consumes those assets through URL templates in `packages.cfg`.

The boundary is:

```text
cup-components
  builds and publishes archives
  defines package metadata
  ensures package self-containment

cup
  reads the manifest
  downloads archives
  validates info.txt
  installs packages into ~/.cup
  records local state
```

The two repositories should stay conceptually separate. Cross-references are limited to the package contract and manifest URL relationship.
