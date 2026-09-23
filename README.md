# cup-components

`cup-components` is the package producer for CUP.
It turns upstream C development-tool releases into verified, relocatable packages
that CUP can download and install without building those tools on the user's machine.

A producer build does more than compile upstream source. It selects the payload that
belongs to one CUP tool, closes required host runtime dependencies, removes unrelated
build/install material, writes package metadata and an exact manifest, emits equivalent
archives and runs native product checks against the finished package.

## Produced tools

The repository produces GCC, GNU `ld`, GDB, Clang, `clang-format`, `clang-tidy`,
`clangd`, LLD, LLDB and Valgrind packages.

Supported package hosts are Linux x64/ARM64, Windows x64 and macOS x64/ARM64.
Availability is tool-specific. GCC and standalone GNU `ld` additionally support the
deliberate Linux x64 → Windows x64 cross-target package. The exact matrix is in the
[specification](docs/SPECIFICATION.md#platforms).

## Package model

The central rule is that an upstream install tree is **not** automatically a CUP
package. Each tool producer owns the commands, runtime data, target files and helpers
that belong to its product. Common package code then makes that selected payload
complete and portable.

Every finished package contains:

- the selected tool payload and required package-owned runtime files;
- `info.txt`, which records package identity, entries, capabilities and provenance;
- `manifest.txt`, which describes the exact finalized package tree;
- equivalent `tar.xz`, `tar.gz` and `zip` archives;
- `publication.txt`, which authenticates the common manifest and all three archive bytes.

Packages are designed to be relocatable and self-contained with respect to non-system
host runtime dependencies. Platform-owned prerequisites that cannot belong to the
package are explicit metadata rather than hidden build-runner assumptions.

## Publication and catalog

A qualified package is published once under a readable immutable `pkg-...` release tag.
Successful package publication then queues the serialized catalog workflow, which updates
`catalog/catalog.cfg` and the rolling `catalog` release. The initial empty revision-0
catalog and exceptional recovery can be published manually; normal package visibility is
automatic.

## Building and validating

GitHub Actions is the canonical native build surface. The workflows build one package
identity at a time, or the full LLVM tool/platform matrix, using the same family
builders and package finalizer available in the repository.

The builders can also be invoked directly inside a prepared platform environment.
See [Build](docs/BUILD.md) for workflow inputs and command lines, and
[Dependencies](docs/DEPENDENCIES.md) for the required environments.

Repository regressions can be run with:

```sh
tests/run.sh
```

The common package contract can be exercised with:

```sh
bash scripts/test/test-package-contract.sh
```

Those local checks validate repository mechanics; native package behavior is proved by
the platform-specific product tests run after a real package build.

## Documentation

Start with the [documentation index](docs/INDEX.md). In particular:

- [Concepts](docs/CONCEPTS.md) explains the producer model and terminology;
- [Specification](docs/SPECIFICATION.md) defines supported identities and version rules;
- [Packages](docs/PACKAGES.md) defines the shared package format and runtime closure;
- [Catalog](docs/CATALOG.md) explains availability activation, automatic publication and recovery;
- [Tool packages](docs/TOOLS.md) explains what each producer deliberately ships;
- [Build](docs/BUILD.md) and [Dependencies](docs/DEPENDENCIES.md) cover build operation;
- [Testing](docs/TESTING.md) explains repository and native package validation;
- [Build records](docs/BUILD_RECORDS.md) explains the diagnostic evidence saved per run.

## Project boundary

`cup-components` owns source acquisition, tool builds, package composition, package
metadata, archive production, native package validation, immutable package publication and
the concrete catalog source/publishing pipeline. CUP consumes published catalog snapshots
and owns package download/admission, installation, local state, defaults, command wrappers
and recovery on the user's machine.
