# Concepts

This page explains the model used throughout `cup-components`. It is intended to make
the repository understandable before reading individual builder scripts.

## Producer and consumer

`cup-components` is the **producer**. It starts from an upstream tool release and ends
with package archives that satisfy the CUP package contract.

CUP is the **consumer**. It selects one of those package identities, downloads an
archive, validates it and installs it below the user's CUP root.

The producer decides how a tool is built and what belongs in the package. The consumer
does not reconstruct those choices from upstream source or from the host system.

## From source to package

A normal producer build has four distinct trees:

```text
upstream source
      ↓
build tree
      ↓
staging tree
      ↓
final package root
```

The **build tree** contains compiler/build-system output. The **staging tree** is the
installation produced by the upstream build. Neither is automatically a package.

The producer selects the public commands, runtime data, target files and required
helpers that belong to the requested tool. These are the **package-selection roots**.
Common package code then closes runtime dependencies and normalizes that selected tree
into the **package root** used to create the archives.

This separation is why a Clang build can use LLVM utilities that are absent from the
final Clang package, or why a full Binutils installation can produce a small standalone
GNU `ld` package.

## Tool, host and target

A **tool** is the command-line product represented by one CUP package, such as GCC,
GDB, Clang or `clang-format`.

The **host platform** is where that packaged tool runs. The **target platform** is the
platform for which a compiler or linker produces code.

Most packages are native and therefore have the same host and target. GCC and GNU `ld`
also support a Linux x64 host with a Windows x64 target. Host and target are part of the
package identity; internal upstream triples do not create additional CUP platforms.

## Version and package identity

`stable` is a repository-owned default that resolves to a concrete upstream version.
An explicit dotted version selects that release directly.

Most package identities are:

```text
<tool>-<version>-<host>-<target>
```

GCC additionally carries a `revN` package revision because one GCC package deliberately
contains independently versioned logical components such as Binutils and, for Windows
targets, MinGW-w64. A revision identifies that package composition; it is not a build
counter and does not choose the component versions by itself.

## Package ownership

Package ownership answers a different question from build success: **which files are
part of the product?**

A path belongs in a package because it has a concrete responsibility, for example:

- a public command;
- a helper required by a public command;
- runtime data used by the tool;
- a target sysroot/runtime deliberately distributed with the toolchain;
- a non-system host runtime dependency;
- a public header deliberately exposed by that package.

Development headers, static libraries, examples, editor integrations and other files
installed by upstream projects are not kept merely because they exist in staging.
[Tool packages](TOOLS.md) documents the selected product surface for each family.

## Runtime closure

After package-selection roots are known, **runtime closure** follows their dynamic host
runtime dependencies recursively. A required non-system dependency is copied into the
package unless it is already package-owned or the tool/package design removes that
runtime edge.

Runtime closure makes the selected product complete; it does not decide what the
product is. This distinction prevents the dependency scanner from pulling unrelated
upstream payload into a package.

Linux closure works with ELF dependencies, macOS with Mach-O load commands and Windows
with PE imports. [Packages](PACKAGES.md#runtime-closure) defines the platform rules.

## Self-contained and relocatable

A package is **self-contained** when it does not require undeclared non-system host
runtime files from the build machine. The operating system still supplies its normal
base runtime.

A package is **relocatable** when it continues to work after extraction to a different
root. Temporary source, build, staging, Homebrew/MSYS2 and runner paths therefore cannot
be runtime requirements.

Self-containment does not mean that every platform service or SDK is copied into the
package. A platform-owned prerequisite that cannot or should not be distributed as
package payload is declared explicitly with `requires.*` metadata and exercised by the
native product test that depends on it.

## Metadata and exact inventory

Every finalized package contains two complementary files:

- `info.txt` describes semantic identity, public entries, capabilities, important
  contents, build choices, external requirements and source provenance;
- `manifest.txt` describes the exact finalized filesystem tree, including normalized
  object kinds/modes and content or link-target digests.

`info.txt` answers what the package is and what it promises. `manifest.txt` answers
exactly which package objects implement it.

The producer emits the same logical package as `tar.xz`, `tar.gz` and `zip`, verifies
each archive against the finalized tree and writes their digests to `SHA256SUMS`.

## Validation layers

Validation happens at several different boundaries:

1. **repository regressions** protect producer rules and synthetic edge cases;
2. **common package validation** checks metadata, paths, manifests, archives and shared
   runtime-closure mechanics;
3. **tool-specific product tests** execute the completed package and prove the declared
   capabilities on the selected native platform;
4. **checksum verification** confirms the final archive bytes before upload/publication.

A parser or synthetic fixture cannot substitute for a native product test. Conversely,
a native command succeeding does not replace the package-contract checks that protect
archive representation and metadata.

## Build records

Workflow build records are diagnostic evidence, not package payload. They preserve the
requested identity, repository commit/tree, source provenance, phase logs, environment
information, configuration files and available package/output inventories so a failed
build can be diagnosed without changing the package contract.

See [Build records](BUILD_RECORDS.md) for the exact record layout.
