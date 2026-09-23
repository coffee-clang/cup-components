# Specification

This document defines the public producer identities and version rules used by
`cup-components`. Read [Concepts](CONCEPTS.md) for the producer model and
[Packages](PACKAGES.md) for the physical package contract.

## Scope

`cup-components` acquires upstream sources, builds supported tools, selects and closes
their package payload, validates the finished tree, emits equivalent archives, publishes
immutable package releases and maintains the concrete package catalog consumed by CUP.

CUP owns package installation and local runtime state. It does not reconstruct producer
build policy from upstream source.

## Tools

The operational package families are:

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

Tool names are globally unambiguous. Their CUP components are:

| Tool | Component |
| --- | --- |
| GCC, Clang | `compiler` |
| GDB, LLDB | `debugger` |
| GNU ld, LLD | `linker` |
| clang-format | `formatter` |
| clang-tidy | `linter` |
| clangd | `language-server` |
| Valgrind | `analyzer` |

## Upstream version selection

Producer commands accept either `default` or an explicit canonical numeric-dotted
upstream version. `default` resolves to the repository-configured source version for the
family; it does **not** mean catalog stable. `stable` and `latest` are not producer source
selectors.

Numeric versions have no leading zero in a segment except the segment `0` itself.
Examples of valid source versions are `17.2`, `23.1.0` and `3.27.1`.

Configured source defaults and their known digests live in
`scripts/package/package-common.sh`, which is the operational authority used by every
builder. Documentation does not duplicate that changing inventory.

Explicit upstream versions remain possible even when the repository does not contain a
built-in source digest. A supplied `source_sha256` binds that build to exact source bytes.

## Package version and revision

A package version consists of the upstream/base version plus one optional terminal CUP
package revision:

```text
<base-version>
<base-version>-revN
```

`N` is a canonical positive integer. Revision absence is revision zero for ordering.
`-revN` is a package-distribution revision, not part of the upstream source version. It
is used when the same upstream release intentionally gets another immutable CUP package,
for example because packaging, relocation, runtime closure or bundled composition
changed.

Examples:

```text
23.1.0
23.1.0-rev1
23.1.0-rev2
```

A revision-bearing package requires one short `package.revision_reason`. A revisionless
package has no revision-reason field. The reason is descriptive and never participates
in ordering.

Source acquisition always receives the unsuffixed base version. For example a
`23.1.0-rev2` LLVM package still downloads/builds LLVM `23.1.0`.

The comparator first compares the complete numeric base version, then the package
revision only when the base is identical. Therefore:

```text
23.1.0 < 23.1.0-rev1 < 23.1.1
23.1.0-rev9 < 23.1.0-rev10
1.2-rev99 < 1.2.0
```

The same comparator is used by producer catalog canonicalization and by CUP when it
orders package versions.

## Package identity

Public package identity is:

```text
(component, tool, package-version, host, target)
```

The package directory/archive base name is:

```text
<tool>-<package-version>-<host>-<target>
```

The canonical GitHub Release tag is:

```text
pkg-<tool>-<package-version>-<host>-<target>
```

Tag and archive names are derived renderings. Product logic does not recover structured
identity by splitting them on `-`; hyphenated tool/platform names make that unnecessary
and ambiguous.

Published package identity is immutable. Publishing an identical already-published
identity is an idempotent success; different data for the same identity is an error. A
corrected distribution uses a new `-revN` identity and leaves the older release intact.

## Platforms

Package platform identifiers are:

```text
linux-x64
linux-arm64
windows-x64
macos-x64
macos-arm64
```

The host is where the packaged program runs. The target is where compiler/linker output
runs. Most packages are native; GCC and GNU ld also support Linux x64 -> Windows x64.

The producer matrix is:

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

Current macOS packages use deployment target 15.0. Internal upstream target triples are
producer details; the CUP platform identity remains the platform string above.

## GCC composition

GCC packages deliberately include independently selected Binutils and, for Windows
targets, MinGW-w64. Those versions remain explicit `bundle.*` metadata and producer
inputs. They are independent of the generic package-revision number.

A composition change can justify a new package revision, but `revN` does not encode the
component versions. Inspecting a GCC package therefore shows both its complete package
version/revision reason and the concrete bundled component versions.

## Package release descriptor

Every package publication manages exactly four assets:

```text
publication.txt
<package-base>.tar.xz
<package-base>.tar.gz
<package-base>.zip
```

`publication.txt` format 1 contains the structured package identity, optional revision
reason, `manifest_sha256`, and the SHA-256 of each of the three archives in fixed order
`tar.xz`, `tar.gz`, `zip`.

`manifest_sha256` proves that all three distributable archives represent the same
finalized package tree. Archive SHA-256 values authenticate the exact downloadable
bytes. No separate `SHA256SUMS` or publication identifier is part of the package-release
contract.

## Catalog

`catalog/catalog.cfg` is the repository source authority for package availability. Its
published consumer endpoint is the `catalog.cfg` asset of the rolling GitHub Release
with tag `catalog`.

Catalog format 1 contains:

```text
format=1
revision=<uint64>
update_url=<stable rolling-release asset URL>
```

followed by concrete package records. Each package record contains component, tool,
host, target, complete package version, derived `stable`, optional `revision_reason`
for `-revN`, and exactly three artifact records containing format, concrete URL and
SHA-256.

The catalog contains only packages proven against already-published immutable package
releases. `stable=true` is materialized for readability/consumption but is derived as
the semantic maximum package version in each `(component, tool, host, target)` scope.
There is no independent promote/set-stable lifecycle.

Canonical catalog order is component/tool/host/target followed by semantic package
version ascending. A semantic change produces a strictly newer catalog revision; a
no-op preserves revision and bytes.

## Catalog publication lifecycle

The first empty revision-0 catalog endpoint is bootstrapped manually. Normal package
publication is automatic after that:

```text
build + qualify
      -> immutable package release
      -> serialized catalog activation
      -> commit updated catalog.cfg
      -> synchronize rolling catalog release
```

Different package identities build in parallel. Duplicate published runs for one identity
are serialized before package publication, and catalog mutation/publication is serialized
so every activation starts from the latest source authority and cannot lose another
package's update.

Manual catalog publication remains an administrative/recovery path, not a normal gate
between package publication and visibility. A rare emergency removal edits the source
catalog deliberately; it does not mutate the immutable package release. The exact
single-writer, anti-rollback and interrupted-publication rules are in
[Catalog](CATALOG.md).

## Relation to CUP

`cup-components` owns package bytes, package publication and catalog production. CUP
consumes published catalog snapshots and owns package download/admission, installation,
state, defaults, wrappers and local recovery.
