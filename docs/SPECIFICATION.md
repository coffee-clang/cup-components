# Specification

`cup-components` is the producer repository for the development-tool packages installed by `cup`. It builds selected upstream tools, turns each completed install tree into a package with a stable identity and validates the result before it is exposed to the consumer repository.

This document defines the producer contract. Detailed package representation is documented in [Packages](PACKAGES.md), build operation in [Build](BUILD.md), and concrete builder inputs in [Dependencies](DEPENDENCIES.md).

## Scope

`cup-components` is responsible for:

- selecting supported tool, host and target combinations;
- acquiring supported upstream source releases;
- building tools in controlled platform-specific environments;
- staging and normalizing package roots;
- packaging required non-system host runtime dependencies;
- writing package metadata and the exact package manifest;
- producing equivalent `tar.xz`, `tar.gz` and `zip` archives;
- validating package capabilities and archive checksums;
- publishing package assets when explicitly requested.

It does not install packages on end-user machines or manage `~/.cup`. Installation, local state and user-facing package selection belong to `cup`.

## Tools and version selection

The producer supports tool families rather than a closed catalog of tool versions. For each build, the operator selects either an explicit dotted numeric upstream version or `stable`.

`stable` is a convenience selector that resolves to the repository's current configured default:

| Tool or component | Current `stable` default |
| --- | --- |
| GCC | 16.1.0 |
| Binutils | 2.46.0 |
| MinGW-w64 | 14.0.0 |
| GDB | 17.1 |
| LLVM family | 22.1.5 |
| Valgrind | 3.27.0 |

These values are defaults, not an exhaustive list of versions that may be built or distributed. An explicit version becomes part of the package identity, so multiple successfully built and published versions of the same tool can coexist as separate package publications. A selected version becomes downloadable when its package assets are successfully published.

The LLVM family contains the packages `clang`, `clang-format`, `clang-tidy`, `clangd`, `lld` and `lldb` from the same selected LLVM project release. Other symbolic aliases such as `latest` are not part of the producer contract.

## Platforms

The platform identifiers are:

```text
linux-x64
linux-arm64
windows-x64
macos-x64
macos-arm64
```

Windows arm64 is not part of the current producer matrix. The current minimum supported macOS deployment target is 15.0 for both macOS architectures.

### Host and target

The **host** is the platform on which a packaged tool runs. The **target** is the platform for which that tool produces, links or otherwise operates on code.

Most packages are native, so host and target are the same. GCC also supports a Linux-hosted Windows target package. For example:

```text
gcc-16.1.0-rev1-linux-x64-windows-x64
```

means:

- the packaged GCC runs on Linux x64;
- it produces code for Windows x64.

The platform-to-triple mapping is:

```text
linux-x64    -> x86_64-linux-gnu
linux-arm64  -> aarch64-linux-gnu
windows-x64  -> x86_64-w64-mingw32
macos-x64    -> x86_64-apple-darwin
macos-arm64  -> arm64-apple-darwin
```

## Supported combinations

| Family | Host | Target |
| --- | --- | --- |
| GCC | `linux-x64` | `linux-x64` |
| GCC | `linux-arm64` | `linux-arm64` |
| GCC | `linux-x64` | `windows-x64` |
| GCC | `windows-x64` | `windows-x64` |
| GDB | `linux-x64` | `linux-x64` |
| GDB | `linux-arm64` | `linux-arm64` |
| GDB | `windows-x64` | `windows-x64` |
| LLVM family | `linux-x64` | `linux-x64` |
| LLVM family | `linux-arm64` | `linux-arm64` |
| LLVM family | `windows-x64` | `windows-x64` |
| LLVM family | `macos-x64` | `macos-x64` |
| LLVM family | `macos-arm64` | `macos-arm64` |
| Valgrind | `linux-x64` | `linux-x64` |
| Valgrind | `linux-arm64` | `linux-arm64` |

LLVM-family and GDB packages are native host/target packages. Valgrind is Linux-only.

## Package identity

A package identity tells `cup` exactly which tool distribution it refers to. It combines the tool, main upstream version, host and target. A revision is present only when a package deliberately combines independently versioned internal components whose selected versions can change without changing the main tool version.

Revision-bearing packages use:

```text
<tool>-<version>-revN-<host>-<target>
```

Revisionless packages use:

```text
<tool>-<version>-<host>-<target>
```

Examples using the current `stable` defaults are:

```text
gcc-16.1.0-rev1-linux-x64-linux-x64
gcc-16.1.0-rev1-linux-x64-windows-x64
gdb-17.1-linux-x64-linux-x64
clang-22.1.5-macos-arm64-macos-arm64
valgrind-3.27.0-linux-arm64-linux-arm64
```

### Revision semantics

GCC is revision-bearing because its logical package composition includes independently versioned Binutils and, for Windows targets, MinGW-w64 components. With the current `stable` defaults, GCC 16.1.0 uses Binutils 2.46.0 and MinGW-w64 14.0.0 where applicable, and that composition is `rev1`. A different GCC main version is a different package identity; revision distinguishes compositions only within the same main version.

GDB, the LLVM-family packages and Valgrind are revisionless in the current model.

A package revision is **not** a build number, publication generation, source-fix counter or packaging-script version. Producer fixes, runtime-closure changes, archive changes and re-publication do not increment revision by themselves.

Runtime libraries discovered during packaging and ordinary builder dependencies do not become revision-driving components merely because they have versions.

## Package contract

A package is the complete archive-level result consumed by `cup`. Each archive has one top-level directory whose name is the package identity and contains at least:

```text
info.txt
manifest.txt
```

`info.txt` describes semantic package identity, platform, entry points, capabilities, build configuration and source provenance. `manifest.txt` inventories the finalized package tree.

On POSIX hosts the package object model admits directories, regular files and safe relative internal symbolic links whose finite chain ends at a regular file. Windows packages contain directories and regular files only. Hardlink inode sharing is not logical package semantics, special filesystem objects are rejected, and the three archive formats represent the same logical object graph without requiring identical inode topology.

The complete representation and validation rules are defined in [Packages](PACKAGES.md).

## Self-contained and relocatable packages

A package is **self-contained** for the non-base runtime dependencies of the packaged host process. This does not mean embedding the operating system.

The deliberate external base is:

- glibc/loader facilities on Linux;
- Apple system libraries on macOS;
- Windows system DLLs on Windows.

Other required host runtime dependencies are packaged when necessary. Target sysroots and target runtimes are separate tool-specific payloads; for example, a Windows-target GCC package carries the MinGW-w64 target layout because the compiler needs it to produce Windows programs.

A package is **relocatable** when it remains usable after being extracted below the location chosen by `cup`, rather than depending on the CI staging path. Linux, macOS and Windows require different runtime-dependency mechanisms; see [Runtime dependencies](PACKAGES.md#runtime-dependencies).

## Integrity

The producer creates:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
SHA256SUMS
```

The exact package tree is recorded in `manifest.txt`. `SHA256SUMS` covers the finished archive bytes and contains one SHA-256 digest for each archive.

Archive checksums protect package transport and cache integrity. They are not upstream-source authentication.

## Source acquisition boundary

Source releases are obtained from configured official versioned HTTPS locations or an existing local source cache. The selected source version is deterministic, but the repository does not maintain a per-version digest/signature table for every accepted upstream source archive.

The builder TLS/platform trust store and the configured source location therefore remain part of the source-acquisition trust boundary. Final package checksums apply only after the package has been built.

Concrete source families and builder requirements are listed in [Dependencies](DEPENDENCIES.md).

## Publication identity

The package basename is also the logical publication identity. Different tool versions therefore use different publication identities and may coexist as separate releases. Publishing the same logical package identity again is an explicit operator action that replaces only that identity's previous release/tag and asset set. It does not create a new package revision.

When publication is disabled, the workflow does not mutate the GitHub Release publication. Operational details are documented in [Build](BUILD.md#publication).

## Repository scripting and Python

Repository automation uses the existing shell, PowerShell, YAML and Dockerfile surfaces. Python is not a repository scripting dependency.

Python can still be part of an upstream tool runtime. GDB and LLDB deliberately provide Python support, so their packages may contain a Python interpreter, standard library and related runtime files. That runtime relationship is described in [Packages](PACKAGES.md#python-runtime).

## Relation to cup

The repository boundary is:

```text
cup-components
  builds and packages tools
  defines package metadata and physical package representation
  produces archives and SHA256SUMS
  can publish package assets

cup
  resolves package choices
  downloads package assets
  verifies downloaded archives
  validates and installs packages
  owns local installation state
```

The repositories share the package contract but have different responsibilities.
