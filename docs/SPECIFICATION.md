# Specification

`cup-components` is the repository that creates the development-tool packages installed by `cup`.

Its responsibility ends at the finished package archives and their publication. The `cup` application is responsible for choosing, downloading, validating and installing those packages on the user's machine.

For the physical package format, see [Packages](PACKAGES.md). For the contents of each tool family, see [Tool packages](TOOLS.md). For build operation, see [Build](BUILD.md).

## Scope

`cup-components` is responsible for:

- accepting a supported tool, version and platform selection;
- obtaining the selected upstream source release;
- building the tool in the correct platform environment;
- selecting the files that belong to the distributed package;
- adding required non-system host runtime dependencies;
- making the package relocatable;
- writing semantic metadata and the exact package manifest;
- producing equivalent `tar.xz`, `tar.gz` and `zip` archives;
- validating the completed package and archive checksums;
- publishing package assets when explicitly requested.

It does not:

- install packages into `~/.cup`;
- manage user configuration or installed-package state;
- choose a user's default tool;
- modify a user's `PATH`.

Those responsibilities belong to `cup`.

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

A build accepts either:

- `stable`, which resolves to the repository's configured default for that family; or
- an explicit dotted numeric version such as `17.2`, `23.1.0` or `3.27.1`.

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

These values are defaults, not a closed version list. An explicit numeric version is passed through the general builder for its family. A different upstream release can require a family-specific adaptation if its configure options, CMake options, installed layout or runtime requirements differ from the versions already handled by the repository.

The symbolic version `latest` is intentionally not part of the interface. `stable` is the only symbolic selector, so the resolved version is deterministic from the repository state.

All LLVM-family packages use the same selected LLVM project release. For example, selecting LLVM `23.1.0` means that Clang, LLD, LLDB, clangd, clang-format and clang-tidy are built from LLVM project `23.1.0` when those packages are requested.

## Platforms

The platform identifiers are:

```text
linux-x64
linux-arm64
windows-x64
macos-x64
macos-arm64
```

Windows arm64 is not part of the current matrix.

The current macOS deployment target is 15.0 for both macOS architectures.

### Host and target

The **host platform** is where the packaged tool runs.

The **target platform** is the platform for which a compiler or linker produces code.

Most packages are native, so host and target are the same. Their workflows therefore expose a single `platform` input. GCC and GNU ld also support a Linux x64 package that targets Windows x64, so those two workflows expose separate `host_platform` and `target_platform` inputs.

Example:

```text
gcc-16.2.0-rev1-linux-x64-windows-x64
```

This package:

- runs on Linux x64;
- produces Windows x64 programs.

The package platform identifiers map to conventional toolchain triples as follows:

| Platform | Triple |
| --- | --- |
| `linux-x64` | `x86_64-linux-gnu` |
| `linux-arm64` | `aarch64-linux-gnu` |
| `windows-x64` | `x86_64-w64-mingw32` |
| `macos-x64` | `x86_64-apple-darwin` |
| `macos-arm64` | `arm64-apple-darwin` |

A tool can internally use a more specific upstream triple. That internal name does not create a second package platform.

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

GDB, LLVM-family tools and Valgrind are native-only in the current repository. GNU ld is not produced for macOS. Valgrind is Linux-only.

## Package identity

Every package has a base name that identifies the tool, main upstream version, host and target.

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

Different main tool versions therefore have different identities and can coexist as separate published packages.

### GCC composition revision

GCC uses a revision because one logical GCC package deliberately contains independently versioned components:

- GCC itself;
- Binutils;
- MinGW-w64 for Windows targets.

The versions of those components are selected independently. There is no repository mapping from a GCC release to a Binutils or MinGW-w64 release. The configured defaults are listed in [Tools and versions](#tools-and-versions); the default GCC composition currently uses `rev1` and has its own bundled Binutils default, independent of the standalone GNU ld/Binutils default.

These are defaults, not compatibility bindings. A build may combine an explicit GCC release with an older or newer explicit Binutils release, and a Windows-target build may independently select its MinGW-w64 release.

The revision is selected with the composition. It does not choose component versions. If the same GCC version is published with a different Binutils or MinGW-w64 composition, the maintainer assigns a different revision such as `rev2` or `rev3`. The configured `stable` revision is accepted only when the resolved GCC version and all applicable bundled component versions equal the configured default GCC composition; any different composition therefore requires an explicit revision.

GNU ld, GDB, LLVM-family packages and Valgrind are revisionless in the current model. Their ordinary runtime dependencies and builder packages do not create package revisions.

A package revision is not a build counter and does not change merely because the packaging scripts, runtime closure or publication process changes.

## Package contract

Each archive contains exactly one top-level package directory. That directory contains at least:

```text
info.txt
manifest.txt
```

`info.txt` describes the package's identity and capabilities.

`manifest.txt` describes the exact finalized file tree.

The package can also contain executables, libraries, runtime data, target runtimes, helper programs and other files required by that specific tool.

The common representation rules are documented in [Packages](PACKAGES.md). Tool-specific contents are documented in [Tool packages](TOOLS.md).

## Self-contained and relocatable packages

A package is **self-contained** when every required host runtime dependency that is not deliberately provided by the operating system is included in the package.

The operating-system-provided runtime boundary is:

- Linux: glibc and loader facilities;
- macOS: Apple system libraries under `/usr/lib` and `/System/Library`;
- Windows: Windows system DLLs.

Self-containment describes the package's runtime closure. It does not imply redistribution of target SDKs or platform-integrated developer services that the operating system vendor owns. Any such dependency must be declared explicitly with `requires.*` metadata and exercised by the native qualification that relies on it. In the current matrix, macOS Clang requires an active Apple macOS SDK for normal native compilation, and macOS LLDB local process control uses Apple's system `debugserver`. LLDB remote debugging on macOS is not declared because a deployable `debugserver` is not package-owned.

A package is **relocatable** when it continues to work after extraction to a different directory. It must not require the temporary build or staging path.

Target runtimes are separate from host runtime dependencies. For example, a Linux-hosted GCC package targeting Windows contains the MinGW-w64 target headers and runtime because they are part of the compiler toolchain it distributes.

## Source selection and verification

Source releases are downloaded from the configured versioned upstream HTTPS locations or reused from the local source cache.

The repository contains known SHA-256 values for the current `stable` source releases. Those source archives are verified before extraction, including when an already cached archive is reused.

For another explicit numeric version, the build can proceed without a repository-known digest. The optional `source_sha256` workflow input, forwarded as `CUP_SOURCE_SHA256`, can be supplied when exact source verification is desired for that version.

Every completed package records the SHA-256 of the source archive that was actually used. Build records also keep the resolved source URL, expected digest when one was supplied or known, actual digest and source-acquisition status. See [Build records](BUILD_RECORDS.md).

`SHA256SUMS` has a different purpose: it contains checksums for the finished package archives, not the upstream source archive.

## Publication identity

The package base name is also the release tag used by the workflows.

Publishing the same logical package identity again replaces that identity's existing release and assets. Publishing a different tool version creates a different release identity, so versions can coexist.

Re-publishing the same identity does not change the GCC composition revision.

See [Build](BUILD.md#publication) for the workflow behavior.

## Repository implementation languages

Repository automation is implemented with:

```text
POSIX shell / Bash
PowerShell
YAML
Dockerfiles
```

Python is not used as a standalone repository automation layer. It is nevertheless a legitimate upstream build dependency and can be part of the final runtime of tools such as GDB, LLDB and LLVM helper commands.

## Relation to cup

The boundary between the two repositories is:

```text
cup-components
  builds the selected tool
  creates the final package tree
  writes info.txt and manifest.txt
  creates archives and SHA256SUMS
  optionally publishes the archives

cup
  selects available package identities
  downloads an archive
  validates the package
  installs it into the user-owned CUP directory
  manages local installation and configuration state
```

They share the same package format, but they have different responsibilities.
