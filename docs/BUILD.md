# Build

`cup-components` can be driven through GitHub Actions or through the repository builder scripts in an already prepared build environment. Both paths use the same tool-specific builders and common package finalization code.

For supported identities and platform combinations, see [Specification](SPECIFICATION.md). For the concrete tools installed into each builder environment, see [Dependencies](DEPENDENCIES.md).

## Build flow

A package build follows this sequence:

```text
select tool/version/host/target
acquire upstream source
configure
build
install into staging
close host runtime dependencies
normalize package tree
write and verify metadata/manifest
create tar.xz, tar.gz and zip
write and verify SHA256SUMS
run package capability tests
publish only when requested
```

Tool-specific builders own configure/build/install behavior. `scripts/package/package-common.sh` owns shared source acquisition and package finalization.

## GitHub Actions workflows

The repository exposes four manual workflows:

| Workflow | Purpose |
| --- | --- |
| `Build GCC` | GCC packages, including Linux-to-Windows GCC |
| `Build GDB` | GDB packages |
| `Build LLVM tool` | Clang, clang-format, clang-tidy, clangd, LLD and LLDB packages |
| `Build Valgrind` | Linux Valgrind packages |

### Common inputs

The workflows use an explicit tool version or `stable`, the relevant host/target selection and a Boolean `publish` input. The version is selected by the operator for each build. `stable` only resolves to the repository's current default; it does not restrict builds to that version.

Because the selected version is part of the package identity, different successfully published versions of the same tool are separate package publications and may coexist. `publish=false` builds and tests the package without mutating the GitHub Release publication. `publish=true` authorizes publication of the selected logical package identity.

### GCC revision input

Only the GCC workflow exposes a `revision` input. The current default is `1`.

The revision identifies the selected internal GCC package composition; it is not a build sequence number. Changing producer scripts or re-publishing the same package identity does not increment it.

### LLVM tool selection

The LLVM workflow selects one of:

```text
clang
clang-format
clang-tidy
clangd
lld
lldb
```

LLVM-family packages are native host/target builds in the current producer matrix.

## Direct builder interfaces

The same builders can be invoked directly when their platform build dependencies are already available.

### GCC

```text
scripts/build/build-gcc.sh <version|stable> <host_platform> <target_platform> <revision>
```

Examples:

```text
scripts/build/build-gcc.sh stable linux-x64 linux-x64 1
scripts/build/build-gcc.sh stable linux-x64 windows-x64 1
scripts/build/build-gcc.sh stable windows-x64 windows-x64 1
```

### GDB

```text
scripts/build/build-gdb.sh <version|stable> <host_platform> <target_platform>
```

Examples:

```text
scripts/build/build-gdb.sh stable linux-x64 linux-x64
scripts/build/build-gdb.sh stable windows-x64 windows-x64
```

### LLVM tool

```text
scripts/build/build-llvm-tool.sh <tool> <version|stable> <host_platform> <target_platform>
```

Example:

```text
scripts/build/build-llvm-tool.sh clang stable linux-x64 linux-x64
```

### Valgrind

```text
scripts/build/build-valgrind.sh <version|stable> <host_platform>
```

Examples:

```text
scripts/build/build-valgrind.sh stable linux-x64
scripts/build/build-valgrind.sh stable linux-arm64
```

The builders validate unsupported platform combinations before the expensive build path.

## Builder environments

### Linux

Linux workflows build inside repository Docker images based on Ubuntu 24.04:

- `docker/toolchain-builder.Dockerfile` for GCC, GDB and Valgrind;
- `docker/llvm-builder.Dockerfile` for LLVM-family tools.

The images provide compilers, build tools and the platform utilities required by package finalization and capability tests.

### Windows

Windows workflows use MSYS2:

- `UCRT64` for GCC and GDB;
- `CLANG64` for LLVM-family tools.

The package lists under `scripts/setup/` define the installed MSYS2 dependencies.

### macOS

macOS LLVM builds run on GitHub-hosted macOS runners. `scripts/setup/setup-macos-builder.sh` installs the required Homebrew dependencies and exports the prefixes consumed by CMake and `pkg-config`.

The LLVM builder uses the active SDK through `xcrun`. The default deployment target is macOS 15.0.

## Working directories

The common package code uses:

```text
CUP_ROOT       repository root
CUP_WORK_DIR   .cup-build
CUP_SRC_DIR    .cup-build/src
CUP_BUILD_DIR  .cup-build/build
CUP_STAGE_DIR  .cup-build/stage
CUP_OUT_DIR    dist
```

Downloaded source archives are cached under `.cup-build/src`. Configure/build trees live under `.cup-build/build`, staged installs under `.cup-build/stage`, and temporary normalized package roots under `.cup-build/package-root`.

Final archives, `SHA256SUMS` and `release.env` are written to `dist/`.

## Source acquisition

The common helper resolves the selected upstream version, downloads the configured source archive when it is not already cached, and extracts it into the working source area.

A failed download or failed extraction stops the build. Source identity/trust semantics are part of the producer contract and are described in [Specification](SPECIFICATION.md#source-acquisition-boundary).

## Package finalization

After a tool installs into staging, common finalization:

1. validates staging paths and object types;
2. closes supported non-system host runtime dependencies;
3. normalizes the package root, hardlink identity and file modes;
4. validates `info.txt`;
5. writes and verifies `manifest.txt`;
6. creates all three archive formats;
7. generates and verifies `SHA256SUMS`;
8. writes `release.env` with the package base and release tag.

The package format and runtime rules are documented in [Packages](PACKAGES.md).

## Tests

Each workflow runs package tests after the package is created.

The test surface includes:

- package identity and metadata checks;
- exact manifest/object-model checks;
- archive/checksum validation, including a deliberate tampering failure;
- package relocation/runtime-dependency checks;
- compiler compile/link capability checks;
- OpenMP, pthread, LTO and sanitizer checks where the tool contract requires them;
- GDB/LLDB startup and Python/debugger checks;
- LLVM frontend/helper checks;
- Valgrind execution and relocation checks.

POSIX package tests use shell. Windows package tests use PowerShell.

## Build output

For one package identity, `dist/` contains:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
SHA256SUMS
release.env
```

`release.env` contains the package base and release tag for workflow steps. Published releases contain the three archives and `SHA256SUMS`; `release.env` is workflow plumbing rather than a package asset.

## Publication

The release tag is the package base name.

When `publish=false`, publication is not mutated.

When `publish=true`, the operator explicitly authorizes the current package identity to become the publication for that tag. Different tool versions have different package identities and therefore different release tags, so their published assets can coexist. If a release already exists for the same logical identity, the workflow replaces the existing release/tag and uploads the complete current asset set. If only a stale standalone tag exists, that tag is removed before the release is created.

Remote state is determined before the first publication mutation. A lookup error is not treated as “not found”.

Re-publishing the same logical identity does not increment package revision. The recreated tag targets the source commit used by the workflow, and the published asset set contains only:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
SHA256SUMS
```
