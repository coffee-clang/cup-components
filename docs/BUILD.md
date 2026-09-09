# Build

`cup-components` can build packages through GitHub Actions or by invoking the repository builder scripts directly inside a prepared platform environment.

Both entry points use the same tool-family builders and the same common package finalizer.

For supported tool/platform identities, see [Specification](SPECIFICATION.md). For installed builder dependencies, see [Dependencies](DEPENDENCIES.md). For package validation, see [Testing](TESTING.md).

## Build flow

A normal build follows this sequence:

```text
select tool, version and platform
        ↓
validate common package mechanics
        ↓
prepare the selected platform build environment
        ↓
obtain the selected upstream source
        ↓
configure and build
        ↓
install into staging
        ↓
select the tool-specific package roots
        ↓
close required host runtime dependencies
        ↓
normalize the package tree
        ↓
write/validate info.txt and generate manifest.txt
        ↓
create and semantically verify tar.xz, tar.gz and zip
        ↓
write SHA256SUMS
        ↓
validate the completed tool package
        ↓
verify SHA256SUMS
        ↓
optionally publish the finished archives
```

Tool-family builders own configure/build/install and tool-specific package selection. `scripts/package/package-common.sh` owns common source handling, metadata rules, manifest generation, runtime closure and archive finalization.

## GitHub Actions workflows

The repository contains five manually started workflows:

| Workflow | File | Purpose |
| --- | --- | --- |
| `Build GCC` | `build-gcc.yml` | GCC packages, including Linux x64 to Windows x64 |
| `Build GNU ld` | `build-ld.yml` | Standalone GNU ld packages, including Linux x64 to Windows x64 |
| `Build GDB` | `build-gdb.yml` | Native GDB packages |
| `Build LLVM tool` | `build-llvm.yml` | Clang, clang-format, clang-tidy, clangd, LLD and LLDB packages |
| `Build Valgrind` | `build-valgrind.yml` | Native Linux Valgrind packages |

The workflows first use their Ubuntu `select` job to validate the requested platform identity and run the common package contract. The selected `build` job then prepares the actual platform environment:

- Linux uses repository Docker images;
- Windows uses MSYS2;
- macOS uses a GitHub-hosted macOS runner with Homebrew dependencies.

The common contract uses synthetic package trees to validate platform-independent package rules, so it has one stable POSIX execution environment rather than depending on whether a Windows or macOS filesystem can represent a particular fixture. Tool-specific package checks still run on the real selected platform against the package that was actually built. See [Testing](TESTING.md#common-package-validation).

## Workflow inputs

Every workflow accepts:

- `version` — `stable` or an explicit dotted numeric version;
- `source_sha256` — optional SHA-256 for the selected main source archive;
- `publish` — whether the completed package should be published as a GitHub Release.

The GCC workflow additionally accepts the composition of the GCC package:

- `binutils_version` — bundled Binutils version, `stable` or an explicit dotted numeric version;
- `binutils_source_sha256` — optional SHA-256 for that Binutils archive;
- `mingw_version` — MinGW-w64 version used by Windows-target GCC packages, `stable` or an explicit dotted numeric version;
- `mingw_source_sha256` — optional SHA-256 for that MinGW-w64 archive;
- `revision` — GCC package revision. `stable` selects the configured revision only when the resolved GCC package composition equals the configured default composition; any different GCC, Binutils or MinGW-w64 composition requires an explicit positive revision.

GCC, bundled Binutils and MinGW-w64 are independent selections. Choosing a GCC release does not force a particular Binutils release. The default bundled Binutils used by GCC is also independent of the Binutils default used by the standalone GNU ld package.

### Platform inputs

GCC and GNU ld expose:

```text
host_platform
target_platform
```

because they support both native packages and the Linux x64 to Windows x64 cross-target configuration.

GDB, LLVM-family tools and Valgrind expose only:

```text
platform
```

because they are native-only in the current repository. Internally that one value becomes both host and target. This prevents unsupported host/target combinations from being represented by the workflow interface.

### LLVM tool input

The LLVM workflow also accepts one tool name:

```text
clang
clang-format
clang-tidy
clangd
lld
lldb
```

### Version behavior

`stable` resolves to the current default configured in `scripts/package/package-common.sh`.

An explicit numeric version is not replaced by the stable version and is not rejected merely because the repository does not already contain a digest for it. The family builder constructs the corresponding upstream source URL and attempts the normal family recipe.

A selected upstream version can still require a repository change if that release changed its source layout, build-system options or installed package layout in a way the general recipe does not yet handle. Build records are saved specifically so the first failing phase and the available configuration state can be inspected. See [Build records](BUILD_RECORDS.md).

## Direct builder commands

The same family builders can be run directly when the required platform dependencies are already installed.

### GCC

```text
scripts/build/build-gcc.sh <version|stable> <host_platform> <target_platform>
```

Examples:

```text
scripts/build/build-gcc.sh stable linux-x64 linux-x64
scripts/build/build-gcc.sh stable linux-x64 windows-x64
scripts/build/build-gcc.sh stable windows-x64 windows-x64
```

The direct builder keeps the same short command line. Alternate GCC compositions are selected through the same environment values used by the workflow:

```text
CUP_GCC_BINUTILS_VERSION=<version|stable>
CUP_GCC_MINGW_VERSION=<version|stable>
CUP_GCC_REVISION=<positive-integer|stable>
CUP_BINUTILS_SOURCE_SHA256=<optional-sha256>
CUP_MINGW_SOURCE_SHA256=<optional-sha256>
```

`CUP_GCC_MINGW_VERSION` and `CUP_MINGW_SOURCE_SHA256` apply only to Windows targets. A non-default composition must use an explicit revision so it cannot silently inherit the revision of the configured stable composition.

### GNU ld

```text
scripts/build/build-ld.sh <version|stable> <host_platform> <target_platform>
```

Examples:

```text
scripts/build/build-ld.sh stable linux-x64 linux-x64
scripts/build/build-ld.sh stable linux-x64 windows-x64
scripts/build/build-ld.sh stable windows-x64 windows-x64
```

### GDB

```text
scripts/build/build-gdb.sh <version|stable> <platform>
```

Examples:

```text
scripts/build/build-gdb.sh stable linux-x64
scripts/build/build-gdb.sh stable windows-x64
```

### LLVM-family tool

```text
scripts/build/build-llvm-tool.sh <tool> <version|stable> <platform>
```

Examples:

```text
scripts/build/build-llvm-tool.sh clang stable linux-x64
scripts/build/build-llvm-tool.sh lldb stable macos-arm64
```

### Valgrind

```text
scripts/build/build-valgrind.sh <version|stable> <platform>
```

Examples:

```text
scripts/build/build-valgrind.sh stable linux-x64
scripts/build/build-valgrind.sh stable linux-arm64
```

Each builder validates its supported platform combination before the expensive source build.

## Builder environments

### Linux

Linux workflows build inside Ubuntu 24.04 Docker images defined by the repository:

- `docker/toolchain-builder.Dockerfile` — GCC, GNU ld, GDB and Valgrind;
- `docker/llvm-builder.Dockerfile` — LLVM-family tools.

The images provide the compiler, build utilities, development headers and package-finalization tools required by those families.

### Windows

Windows workflows use MSYS2:

- `UCRT64` — GCC, GNU ld and GDB;
- `CLANG64` — LLVM-family tools.

`scripts/setup/setup-windows-msys2.sh` installs the package list selected from `scripts/setup/msys2-ucrt64-packages.txt` or `scripts/setup/msys2-clang64-packages.txt`.

The Windows tool-specific package checks run through PowerShell after the MSYS2 build has produced the package.

### macOS

macOS currently builds only LLVM-family packages.

`scripts/setup/setup-macos-builder.sh` installs the Homebrew dependencies required by the selected LLVM build and exports the paths used by CMake and `pkg-config`.

The setup selects Homebrew `python` because Python can become package-owned runtime content for LLDB and LLVM Python helper commands. The producer derives the package layout and runtime-version provenance from the interpreter actually selected by the build rather than fixing a Python major/minor release in the repository.

The active macOS SDK is selected through `xcrun`. The current deployment target is macOS 15.0.

The exact dependency lists are documented in [Dependencies](DEPENDENCIES.md).

## Working directories

The common code uses these directories:

```text
CUP_ROOT       repository root
CUP_WORK_DIR   .cup-build
CUP_SRC_DIR    .cup-build/src
CUP_BUILD_DIR  .cup-build/build
CUP_STAGE_DIR  .cup-build/stage
CUP_OUT_DIR    dist
```

Their roles are:

| Path | Purpose |
| --- | --- |
| `.cup-build/src` | downloaded source archives and extracted source trees |
| `.cup-build/build` | configure/CMake/Ninja/Make build trees |
| `.cup-build/stage` | temporary upstream installations and selected package staging |
| `.cup-build/package-root` | normalized package trees used for final archives |
| `.cup-build/build-records` | workflow run information, logs and configuration files |
| `dist` | finished archives, `SHA256SUMS` and `release.env` |

`.cup-build/build-records` is not package content. See [Build records](BUILD_RECORDS.md).

## Source acquisition

The common source layer performs these steps:

1. resolve `stable` or preserve the explicit numeric version;
2. construct the upstream source URL for the selected family;
3. choose a deterministic local archive name;
4. reuse the cached archive if it already exists, otherwise download it;
5. calculate its SHA-256;
6. verify the digest when the repository knows the selected stable digest or when `source_sha256` was supplied;
7. extract the archive into `.cup-build/src`;
8. record the actual source digest used by the package.

The current stable source digests are stored directly in `scripts/package/package-common.sh` for:

```text
GCC
Binutils
MinGW-w64
GDB
LLVM project
Valgrind
```

For an explicit version without a known digest, the build still calculates and records the actual SHA-256. Supplying `source_sha256` changes that build from recorded-only to verified source identity: a mismatch stops the build before extraction.

The repository does not maintain a separate version database that must be extended before another numeric release can be attempted.

## Tool build and staging

Each family builder owns its own configure/build/install logic:

```text
scripts/build/build-gcc.sh
scripts/build/build-ld.sh
scripts/build/build-gdb.sh
scripts/build/build-llvm-tool.sh
scripts/build/build-valgrind.sh
```

The upstream install goes into a temporary staging location. The builder then keeps the files that belong to that tool package and removes development or unrelated upstream payload according to [Tool packages](TOOLS.md).

This separation matters because the upstream install tree can be much larger than the command-line package distributed by `cup`.

## Package finalization

After the tool-specific package tree has been selected, common finalization performs:

1. staging object and path validation;
2. removal of non-relocatable libtool metadata that still contains temporary build paths;
3. host runtime closure for the selected platform;
4. package-root normalization;
5. `info.txt` contract validation;
6. `manifest.txt` generation, followed by independent regeneration from each extracted archive;
7. timestamp normalization where supported by the package path;
8. creation of `tar.xz`, `tar.gz` and `zip`;
9. creation of `SHA256SUMS`;
10. creation of `release.env` for later workflow steps.

The workflow then runs the tool-specific product test and verifies `SHA256SUMS` before upload or publication. Archive semantic verification itself is already part of common finalization.

The common finalizer does not decide which public commands belong to GDB, Clang, Valgrind or another family. That decision remains in the corresponding tool builder.

## Build output

For one completed package identity, `dist/` contains:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
SHA256SUMS
release.env
```

`release.env` contains:

```text
release_tag=<package-base>
package_base=<package-base>
```

It is used by later workflow steps and is not itself a package archive or published package asset.

When `publish=false`, GitHub Actions uploads the build output as a workflow artifact so the package can be downloaded without changing release state.

## Publication

The release tag is the package base name.

When `publish=false`:

- no GitHub Release or tag is modified;
- the package output is uploaded only as a workflow artifact.

When `publish=true`:

1. the workflow determines whether a release already exists for that exact package identity;
2. if it exists, that release and its tag are removed;
3. if no release exists but the same standalone tag exists, the stale tag is removed;
4. a new release is created for the current source commit;
5. the three archives and `SHA256SUMS` are uploaded as the complete asset set.

A failure while checking remote release/tag state is not treated as “not found”; publication stops instead of guessing.

Different tool versions use different package identities and therefore different release tags. Re-publishing one identity does not remove other versions.

The published asset set is exactly:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
SHA256SUMS
```
