# Build

`cup-components` uses the same family builders in GitHub Actions and direct prepared
environments. GitHub Actions is the canonical native build/publication surface because
it selects the runner, prepares dependencies, runs native product tests, publishes the
package and then queues serialized catalog activation.

See [Specification](SPECIFICATION.md) for identities and versions,
[Dependencies](DEPENDENCIES.md) for environment inputs, [Testing](TESTING.md) for
qualification layers and [Catalog](CATALOG.md) for the publication/availability lifecycle.

## Lifecycle

A normal producer run is:

```text
select tool / upstream version / optional package revision
        ↓
validate producer contracts
        ↓
prepare native environment
        ↓
acquire + verify upstream source
        ↓
configure / build / install to staging
        ↓
select tool-owned payload
        ↓
close non-system host runtime dependencies
        ↓
normalize + final tool policy
        ↓
validate info.txt + generate manifest.txt
        ↓
emit and verify tar.xz / tar.gz / zip
        ↓
generate publication.txt
        ↓
native tool-package test
        ↓
optional immutable package publication
        ↓
automatic serialized catalog activation/publication
```

The family builder owns upstream configure/build/install and the tool-specific package
surface. `scripts/package/package-common.sh` owns common source, metadata, closure,
manifest, archive and publication-descriptor mechanics.

## Workflows

The native producer entry points are:

| Workflow | File | Family |
| --- | --- | --- |
| Build GCC | `build-gcc.yml` | GCC, including Linux x64 -> Windows x64 |
| Build GNU ld | `build-ld.yml` | standalone GNU ld, including Linux x64 -> Windows x64 |
| Build GDB | `build-gdb.yml` | native GDB |
| Build LLVM tool | `build-llvm.yml` | Clang, clang-format, clang-tidy, clangd, LLD, LLDB |
| Build Valgrind | `build-valgrind.yml` | native Linux Valgrind |

Every workflow accepts:

- `version`: `default` or an explicit upstream numeric-dotted version;
- `source_sha256`: optional exact primary-source digest;
- `revision`: optional positive package revision number;
- `revision_reason`: required iff `revision` is supplied;
- `publish`: whether the qualified package should be published.

GCC additionally accepts independent Binutils/MinGW-w64 version and digest inputs.
Those source selectors also use `default` or an explicit upstream version. They do not
encode package revision.

GCC/GNU ld expose host and target separately because they include the supported Linux
x64 -> Windows x64 cross-target cell. GDB, LLVM tools and Valgrind use one native
platform input.

`Build LLVM tool` can build one selected cell or the complete six-tool by five-platform
native matrix. Matrix cells remain independent so one failure does not erase evidence
from other cells.

## Direct builders

With a prepared native environment:

```text
scripts/build/build-gcc.sh <version|default> <host> <target>
scripts/build/build-ld.sh <version|default> <host> <target>
scripts/build/build-gdb.sh <version|default> <platform>
scripts/build/build-llvm-tool.sh <tool> <version|default> <platform>
scripts/build/build-valgrind.sh <version|default> <platform>
```

Examples:

```text
scripts/build/build-gcc.sh default linux-x64 windows-x64
scripts/build/build-ld.sh default windows-x64 windows-x64
scripts/build/build-gdb.sh default linux-arm64
scripts/build/build-llvm-tool.sh lldb default macos-arm64
scripts/build/build-valgrind.sh default linux-x64
```

Package revision is supplied uniformly through:

```text
CUP_PACKAGE_REVISION=<positive-integer>
CUP_PACKAGE_REVISION_REASON=<short-single-line-reason>
```

Both may be omitted. Supplying only one is an error.

GCC composition overrides are independent:

```text
CUP_GCC_BINUTILS_VERSION=<version|default>
CUP_GCC_MINGW_VERSION=<version|default>
CUP_BINUTILS_SOURCE_SHA256=<optional-sha256>
CUP_MINGW_SOURCE_SHA256=<optional-sha256>
```

## Environments

| Host | Environment owner | Used for |
| --- | --- | --- |
| Linux | repository Ubuntu 24.04 Dockerfiles | GNU families, GDB, Valgrind, LLVM |
| Windows | MSYS2 UCRT64 | GCC, GNU ld, GDB |
| Windows | MSYS2 CLANG64 | LLVM family |
| macOS | `setup-macos-builder.sh` + Homebrew | LLVM family |

The exact package/formula inventories live in the environment files. macOS uses the
active SDK and deployment target 15.0.

## Working directories

| Path | Responsibility |
| --- | --- |
| `.cup-build/src` | cached/downloaded upstream archives and extracted sources |
| `.cup-build/build` | configure/CMake/Make/Ninja trees |
| `.cup-build/stage` | upstream installs and selected staging |
| `.cup-build/package-root` | finalized package trees |
| `.cup-build/build-records` | diagnostic run evidence |
| `dist` | three archives, `publication.txt`, `release.env` |

## Source acquisition

The common source layer resolves `default` or preserves an explicit upstream version,
derives its source URL/cache name, downloads with bounded retries when needed, verifies
a known/supplied SHA-256, extracts it and records the actual source identity.

Repository-known digests cover configured default sources. Explicit versions without a
known digest can still be attempted; `source_sha256` makes a particular build exact.
Package revision never changes the version passed to source acquisition.

## Finalization

After tool-specific payload selection, common finalization:

1. validates staging object/path semantics;
2. removes non-relocatable temporary libtool metadata;
3. closes required host runtime dependencies;
4. normalizes the package tree;
5. applies the final tool policy;
6. validates `info.txt` and generates `manifest.txt`;
7. normalizes timestamps where applicable;
8. creates `tar.xz`, `tar.gz` and `zip`;
9. extracts/verifies every archive against the finalized tree;
10. writes `publication.txt` and `release.env`.

`publication.txt` contains the archive digests and common manifest digest, so no second
checksum document is produced.

## Output

For one identity, `dist/` contains:

```text
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
publication.txt
release.env
```

`release.env` is workflow-local state containing `release_tag` and `package_base`; it is
not uploaded as a package-release asset.

With `publish=false`, the four distributable files plus `release.env` are retained as a
workflow artifact for inspection.

## Immutable package publication

With `publish=true`, `scripts/publish/publish-package.sh` owns remote publication.

The canonical release tag is `pkg-<package-base>`. The publisher validates the local
publication descriptor and archive digests, then reconciles that exact package identity:

- no release/tag -> create a draft, upload the four managed assets, verify and publish;
- matching unpublished draft -> discard/recreate it safely;
- already-published exact data -> idempotent success;
- already-published different data -> error;
- standalone conflicting tag -> error.

A published package release is never automatically replaced. Another intentional
distribution of the same upstream version uses a new `-revN` package identity. Published
runs for the same resolved package identity are serialized at the build-job boundary. The
selection job resolves `default` before computing that concurrency identity, so `default` and an
explicit request for the same upstream version cannot race while creating or reconciling the same
draft/release. Different package identities remain independent and build in parallel.

The release points at the exact repository commit whose bytes produced and qualified
the package. GitHub-generated source archives are outside the managed package asset set.

## Automatic catalog update

After package publication succeeds, the producer workflow dispatches
`update-catalog.yml` with the canonical package tag.

The catalog workflow is the single serialized writer. It reloads the current default
branch, validates the already-published package, activates it into
`catalog/catalog.cfg`, recomputes derived stable markers and advances catalog revision
only when the snapshot changes. It commits/pushes that source snapshot and synchronizes
the rolling `catalog` release.

A branch push race is retried from the new current source authority a bounded number of
times. Builds for different package identities remain parallel; only duplicate published
runs for one identity and the shared catalog writer are serialized. The complete
source-authority and rolling-release recovery rules are documented in [Catalog](CATALOG.md).

If package publication succeeds but catalog update fails, the package remains a valid
immutable release but is not yet discoverable through cup. Re-running the catalog update
is safe and idempotent.

## Initial bootstrap and recovery

`publish-catalog.yml` is the manual administrative path. `bootstrap` creates the rolling
`catalog` release from the empty revision-0 source catalog once. `sync` can re-publish
source-authority bytes for recovery/emergency use, including recreating a missing rolling
release from the current validated source catalog.

Normal package publication reaches the rolling catalog through the automatic update path.
