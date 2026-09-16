# Specification

This document defines the package identities that `cup-components` can produce and the
rules used to select their source versions and platforms. Read [Concepts](CONCEPTS.md)
first for the producer model and [Packages](PACKAGES.md) for the physical package
contract.

## Scope

`cup-components` accepts a supported tool, version and platform selection, obtains the
upstream source, builds it in the corresponding environment, selects and closes the
package payload, validates the finished package and optionally publishes its archives.

Installation below a user's CUP root, local state, defaults, wrappers and PATH behavior
belong to CUP rather than this repository.

## Tools and versions

The supported package families are:

```text
GCC
GNU ld
GDB
Clang
clang-format
clang-tidy
clangd
LLD
LLDB
Valgrind
```

A build accepts either `stable` or an explicit dotted numeric version. `stable` resolves
to the repository default for that family; `latest` is intentionally not a supported
symbolic selector.

The current defaults are:

| Tool or component | `stable` |
| --- | --- |
| GCC | 16.2.0 |
| Binutils bundled in the default GCC composition | 2.47 |
| MinGW-w64 bundled in the default Windows-target GCC composition | 14.0.0 |
| Default GCC package revision | 1 |
| GNU ld / standalone Binutils package | 2.47 |
| GDB | 17.2 |
| LLVM family | 23.1.0 |
| Valgrind | 3.27.1 |

These are defaults rather than a closed version list. An explicit release is passed to
the general builder for its family. If an upstream release changes configure/CMake
options, source layout, installed layout or runtime requirements, the family recipe may
need an adaptation before that version can complete successfully.

All LLVM-family packages use the same selected LLVM project release. Selecting LLVM
`23.1.0`, for example, means Clang, LLD, LLDB, clangd, clang-format and clang-tidy are
built from LLVM project `23.1.0` when requested.

## Platforms

Package platform identifiers are:

```text
linux-x64
linux-arm64
windows-x64
macos-x64
macos-arm64
```

Windows arm64 is not part of the current matrix. The current macOS deployment target is
15.0 for both supported macOS architectures.

### Host and target

The **host** is the platform on which the packaged tool runs. The **target** is the
platform for which a compiler or linker produces code.

Most packages are native, so host and target are equal. GCC and GNU `ld` additionally
support a Linux x64 package targeting Windows x64; their workflows therefore expose
separate host and target inputs.

The package-platform mapping is:

| Platform | Toolchain triple |
| --- | --- |
| `linux-x64` | `x86_64-linux-gnu` |
| `linux-arm64` | `aarch64-linux-gnu` |
| `windows-x64` | `x86_64-w64-mingw32` |
| `macos-x64` | `x86_64-apple-darwin` |
| `macos-arm64` | `arm64-apple-darwin` |

A producer can use a more specific upstream triple internally. That does not create a
second CUP platform identity.

## Supported combinations

| Family | Host | Target |
| --- | --- | --- |
| GCC | `linux-x64` | `linux-x64` |
| GCC | `linux-arm64` | `linux-arm64` |
| GCC | `linux-x64` | `windows-x64` |
| GCC | `windows-x64` | `windows-x64` |
| GNU ld | `linux-x64` | `linux-x64` |
| GNU ld | `linux-arm64` | `linux-arm64` |
| GNU ld | `linux-x64` | `windows-x64` |
| GNU ld | `windows-x64` | `windows-x64` |
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

GDB, LLVM-family tools and Valgrind are native-only in the current repository. GNU `ld`
is not produced for macOS, and Valgrind is Linux-only.

## Package identity

Revisionless packages use:

```text
<tool>-<version>-<host>-<target>
```

GCC packages use:

```text
<tool>-<version>-revN-<host>-<target>
```

Examples:

```text
gcc-16.2.0-rev1-linux-x64-linux-x64
gcc-16.2.0-rev1-linux-x64-windows-x64
ld-2.47-linux-x64-linux-x64
gdb-17.2-linux-x64-linux-x64
clang-23.1.0-macos-arm64-macos-arm64
valgrind-3.27.1-linux-arm64-linux-arm64
```

Different main tool versions therefore have different identities and can coexist as
separate published packages.

### GCC composition revision

GCC is revision-bearing because one logical GCC package contains independently
versioned components:

- GCC;
- Binutils;
- MinGW-w64 for Windows targets.

Their versions are selected independently. There is no repository rule that maps one
GCC release to one Binutils or MinGW-w64 release, and the bundled Binutils default used
by GCC is independent of the standalone GNU `ld` default.

The revision identifies a deliberate composition; it does not select component versions.
The configured `stable` revision is valid only when the resolved GCC release and all
applicable bundled component versions equal the configured default composition. Any
other composition requires an explicit positive revision.

A revision is not a build counter. Rebuilding the same composition after a packaging,
runtime-closure or publication change does not by itself create a new revision.

GNU `ld`, GDB, LLVM-family packages and Valgrind are revisionless in the current model.
Ordinary build/runtime dependencies do not create package revisions.

## Package requirements

Every archive contains exactly one top-level package directory with at least:

```text
info.txt
manifest.txt
```

`info.txt` describes semantic identity, entries, capabilities, requirements and source
provenance. `manifest.txt` describes the exact finalized filesystem tree. The package
can additionally contain the executables, libraries, runtime data, target files and
helpers owned by that tool.

The shared filesystem, metadata, archive, self-containment and relocatability rules are
defined in [Packages](PACKAGES.md). Tool-specific payload ownership is defined in
[Tool packages](TOOLS.md).

## Source selection and verification

Versioned upstream source archives are downloaded from the family URL implemented by
the common source layer or reused from the local source cache.

The repository contains known SHA-256 values for the current `stable` sources. Those
archives are verified before extraction, including when a cached copy is reused.

An explicit numeric version can be attempted without a repository-known digest. The
optional `source_sha256` workflow input, forwarded as `CUP_SOURCE_SHA256`, binds that
build to an exact source digest when supplied.

Every completed package records the SHA-256 of the source archive actually used. Build
records additionally preserve the resolved URL, expected digest when one was supplied
or known, actual digest and acquisition status. See [Build records](BUILD_RECORDS.md).

`SHA256SUMS` serves a different boundary: it records digests of the finished package
archives, not the upstream source archive.

## Publication identity

The package base name is also the GitHub Release tag used by the workflows.
Re-publishing one package identity replaces that identity's release and assets; it does
not remove other tool versions. Re-publication does not change the GCC composition
revision.

See [Build](BUILD.md#publication) for the exact workflow behavior.

## Relation to CUP

`cup-components` ends at validated package assets and optional publication. CUP begins
with package selection/download and owns package admission, installation, local state,
defaults, wrappers and recovery.

Both repositories implement the same package contract from opposite sides: the producer
must emit bytes the consumer can validate without reconstructing producer-specific build
logic.
