# Build

`cup-components` builds packages through GitHub Actions or by invoking the same family
builders directly inside a prepared platform environment. GitHub Actions is the
canonical native build surface because it selects the runner, prepares the environment,
runs the product test and optionally publishes the completed assets.

For supported identities, see [Specification](SPECIFICATION.md). For environment-owned
build inputs, see [Dependencies](DEPENDENCIES.md). For package acceptance, see
[Testing](TESTING.md).

## Build lifecycle

A producer run follows one lifecycle regardless of tool family:

```text
select tool/version/platform
        ↓
validate repository/package contracts
        ↓
prepare the native builder environment
        ↓
acquire and verify upstream source
        ↓
configure, build and install to staging
        ↓
select the tool-owned package roots
        ↓
close non-system host runtime dependencies
        ↓
normalize and apply the final tool policy
        ↓
validate info.txt and generate manifest.txt
        ↓
emit + semantically verify tar.xz, tar.gz and zip
        ↓
write SHA256SUMS
        ↓
run the native tool-package test
        ↓
optionally publish the package assets
```

The family builder owns configure/build/install and the tool-specific package surface.
`scripts/package/package-common.sh` owns the shared source, metadata, runtime-closure,
manifest and archive mechanics. The final tool-policy hook runs after common runtime
closure and normalization so it evaluates the same tree that is about to be sealed.

## GitHub Actions workflows

Five manually started workflows are the public native build entry points:

| Workflow | File | Product family |
| --- | --- | --- |
| `Build GCC` | `build-gcc.yml` | GCC, including Linux x64 → Windows x64 |
| `Build GNU ld` | `build-ld.yml` | GNU `ld`, including Linux x64 → Windows x64 |
| `Build GDB` | `build-gdb.yml` | native GDB |
| `Build LLVM tool` | `build-llvm.yml` | Clang, clang-format, clang-tidy, clangd, LLD, LLDB |
| `Build Valgrind` | `build-valgrind.yml` | native Linux Valgrind |

Each workflow has an Ubuntu `select` job that validates the requested identity and runs
the common package contract before dispatching the native build. The build job then
uses the platform environment owned by the repository: Docker on Linux, MSYS2 on
Windows and the GitHub macOS runner plus Homebrew setup on macOS.

The synthetic common contract intentionally has one predictable POSIX owner. The real
finished-package test still runs on the platform that built the package.

## Workflow inputs

Every workflow accepts:

- `version`: `stable` or an explicit dotted numeric version;
- `source_sha256`: optional exact digest for the primary source archive;
- `publish`: whether the completed package should replace/publish its matching GitHub
  Release identity.

GCC additionally accepts independently selected Binutils and MinGW-w64 versions and
source digests, plus a package `revision`. The configured stable GCC revision is valid
only for the configured default composition; another composition requires an explicit
positive revision. See [Specification](SPECIFICATION.md#gcc-composition-revision).

GCC and GNU `ld` expose separate `host_platform` and `target_platform` inputs because
both own the deliberate Linux x64 → Windows x64 cross-target cell. GDB, LLVM-family
tools and Valgrind expose a single native `platform` input, which becomes both host and
target.

### LLVM full matrix

`Build LLVM tool` can build one tool/platform cell or the complete native matrix.
`full_matrix=true` expands to six tools:

```text
clang  clang-format  clang-tidy  clangd  lld  lldb
```

across five platforms:

```text
linux-x64  linux-arm64  windows-x64  macos-x64  macos-arm64
```

That is the 30-cell LLVM matrix. With `full_matrix=false`, `tool` and `platform` select
a single cell. The selected version/source digest/publication policy applies to every
cell in the run.

### Version selection

`stable` resolves through the defaults in `scripts/package/package-common.sh`. An
explicit numeric version is preserved and passed to the family recipe; it is not
rejected merely because the repository has no built-in digest for it.

A new upstream release can still require a recipe change when its source layout,
build-system options, installed layout or runtime graph changed. [Build records](BUILD_RECORDS.md)
exist so that failure is diagnosed at the owning phase rather than hidden behind a
version allow-list.

## Direct builders

The same producers can be invoked directly when their platform environment is already
prepared:

```text
scripts/build/build-gcc.sh <version|stable> <host_platform> <target_platform>
scripts/build/build-ld.sh <version|stable> <host_platform> <target_platform>
scripts/build/build-gdb.sh <version|stable> <platform>
scripts/build/build-llvm-tool.sh <tool> <version|stable> <platform>
scripts/build/build-valgrind.sh <version|stable> <platform>
```

Examples:

```text
scripts/build/build-gcc.sh stable linux-x64 windows-x64
scripts/build/build-ld.sh stable windows-x64 windows-x64
scripts/build/build-gdb.sh stable linux-arm64
scripts/build/build-llvm-tool.sh lldb stable macos-arm64
scripts/build/build-valgrind.sh stable linux-x64
```

The GCC builder keeps composition selection out of its positional interface. Alternate
components use the same environment values supplied by the workflow:

```text
CUP_GCC_BINUTILS_VERSION=<version|stable>
CUP_GCC_MINGW_VERSION=<version|stable>
CUP_GCC_REVISION=<positive-integer|stable>
CUP_BINUTILS_SOURCE_SHA256=<optional-sha256>
CUP_MINGW_SOURCE_SHA256=<optional-sha256>
```

The MinGW values apply only to Windows targets. Every builder rejects unsupported
platform identities before starting the expensive build.

## Builder environments

The build environments are deliberately separate from package ownership:

| Host | Environment owner | Used for |
| --- | --- | --- |
| Linux | repository Ubuntu 24.04 Dockerfiles | GNU families, GDB, Valgrind, LLVM |
| Windows | MSYS2 UCRT64 | GCC, GNU `ld`, GDB |
| Windows | MSYS2 CLANG64 | LLVM family |
| macOS | `setup-macos-builder.sh` + Homebrew | LLVM family |

Exact installed package/formula lists belong to those environment files and are not
duplicated here. [Dependencies](DEPENDENCIES.md#build-environments) documents the
boundary.

macOS uses the active SDK discovered through `xcrun`; the current deployment target is
15.0. Python selected by a builder is discovered from that environment rather than by a
repository-fixed Python major/minor version.

## Working directories

Build state lives under `.cup-build`; completed output lives under `dist`:

| Path | Responsibility |
| --- | --- |
| `.cup-build/src` | source archive cache and extracted sources |
| `.cup-build/build` | configure/CMake/Ninja/Make trees |
| `.cup-build/stage` | upstream installs and temporary selected staging |
| `.cup-build/package-root` | normalized final package trees |
| `.cup-build/build-records` | run diagnostics and provenance |
| `dist` | finished archives, `SHA256SUMS`, `release.env` |

Build records are diagnostic evidence, not package content. See
[Build records](BUILD_RECORDS.md).

## Source acquisition

The common source layer:

1. resolves `stable` or preserves the explicit numeric version;
2. derives the family source URL and deterministic cache filename;
3. reuses an existing cached archive or downloads it with bounded transfer retries;
4. computes SHA-256 and verifies it when a stable digest is known or the caller supplied
   `source_sha256`;
5. extracts the source into `.cup-build/src`;
6. records the actual source identity used by the build.

Known stable source digests for GCC, Binutils, MinGW-w64, GDB, LLVM and Valgrind are
owned by `scripts/package/package-common.sh`. Explicit versions without a known digest
remain buildable; supplying `source_sha256` turns that particular acquisition into an
exact verified input.

## Build, staging and finalization

Each family builder installs upstream output to staging, then selects the commands,
runtime data, target files and helpers that belong to that package. This is the point at
which upstream install output becomes a CUP product surface. The selection policy is
documented in [Tool packages](TOOLS.md).

Common finalization then:

1. validates staging object/path semantics;
2. removes non-relocatable libtool metadata that contains temporary paths;
3. closes host runtime dependencies;
4. normalizes the package tree;
5. invokes the tool-specific final package policy when one exists;
6. validates `info.txt` and generates `manifest.txt`;
7. normalizes timestamps where applicable;
8. creates `tar.xz`, `tar.gz` and `zip`;
9. extracts and semantically verifies every archive against the finalized tree;
10. writes `SHA256SUMS` and `release.env`.

The workflow runs the tool-specific product test and verifies `SHA256SUMS` after this
step. See [Packages](PACKAGES.md) for the package contract and [Testing](TESTING.md) for
the acceptance layers.

## Output

For one package identity, `dist/` contains:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
SHA256SUMS
release.env
```

`release.env` contains the `release_tag` and `package_base` consumed by later workflow
steps. It is workflow state, not a published package asset.

With `publish=false`, GitHub Actions uploads the output as a workflow artifact and does
not mutate GitHub Release/tag state.

## Publication

The package base name is the release tag. With `publish=true`, the workflow:

1. queries the exact matching release/tag identity;
2. removes an existing matching release/tag, or a stale standalone matching tag;
3. creates a new release from the current repository commit;
4. publishes exactly the three package archives and `SHA256SUMS`.

Failure to query remote release/tag state is fatal; it is not interpreted as “not
found”. Different package identities use different tags, so publishing one version does
not remove other versions.
