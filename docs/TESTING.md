# Testing

`cup-components` separates package-format checks from native product qualification.
A synthetic fixture can prove a parser, archive or closure rule; it cannot prove that a
real compiler, debugger or linker built for a platform actually works there. Conversely,
a successful tool invocation does not prove that the archive, metadata and publication
contract are correct.

The test surfaces therefore follow the same ownership split as the producer itself:
shared package mechanics are checked once, finished packages are tested natively, and a
small regression suite covers repository behavior that can be exercised without an
upstream rebuild.

## Shared package contract

The common contract is exercised with:

```sh
bash scripts/test/test-package-contract.sh
```

It uses small package trees and locally generated objects to exercise common behavior:
package identity/revision validation, `info.txt` and `manifest.txt`, path/object admission,
archive equivalence, runtime closure/search-path rewriting, package-owned Python support
and other package mechanisms owned by `scripts/package/package-common.sh`. Source
acquisition has its own repository regression because download/cache/retry behavior is a
separate producer boundary.

These fixtures intentionally stop at the common boundary. Tool-specific payload choices
and platform behavior belong to the native package checks.

## Native package qualification

Every completed package is tested on the host that produced it before publication.
The family entry points are:

| Family | POSIX | Windows |
| --- | --- | --- |
| GCC | `scripts/test/test-gcc.sh` | `scripts/test/test-gcc-windows.ps1` |
| GNU ld | `scripts/test/test-ld.sh` | `scripts/test/test-ld-windows.ps1` |
| GDB | `scripts/test/test-gdb.sh` | `scripts/test/test-gdb-windows.ps1` |
| LLVM family | `scripts/test/test-llvm-tool.sh` | `scripts/test/test-llvm-tool-windows.ps1` |
| Valgrind | `scripts/test/test-valgrind.sh` | — |

These checks execute the package rather than infer capability from builder text. They
verify the public entries and the behavior promised by `features.*`, plus the ownership
and relocation properties needed by that tool.

GCC compiles and links representative C/C++ programs, exercises LTO and declared runtime
features, checks target-prefixed tools/sysroots where applicable, and validates physical
relocation. GNU ld performs a real native-format link and checks the deliberately small
standalone linker surface. GDB exercises Python/TUI/runtime ownership, packaged
`gdbserver` remote debugging and relocation.

The LLVM-family check selects the relevant product contract. Clang performs real
compile/link/runtime probes, package-owned resource and compiler-runtime checks, LTO and
relocation. LLD performs a real ELF, PE/COFF or Mach-O link through the public frontend
for its host. LLDB exercises Python, target/process behavior, DAP and package-owned remote
server behavior where declared. clangd runs a bounded LSP session with a real compilation
database; clang-format checks formatting/style behavior; clang-tidy exercises its Python
helpers and source-rewrite path. Valgrind exercises the public wrapper, Memcheck, retained
runtime tooling, client headers/pkg-config metadata and relocation.

A relocation test makes the previous package root physically unavailable before the
relocated command is accepted. This prevents a package from passing while still reading
its original staging path.

## Diagnostic capability reporters

`scripts/test/package-capabilities.sh` and
`scripts/test/package-capabilities-windows.ps1` summarize `info.txt` together with the
physical package. They are diagnostic helpers shared by native checks, not an independent
source of product truth. Tool-specific qualification decides pass/fail from actual
package behavior.

## Repository regressions

Run the local regression suite with:

```sh
tests/run.sh
```

The suite is intentionally small. It exercises observable repository behavior that does
not require rebuilding a full upstream tool: supported-input rejection before build
state is created, build-record lifecycle/provenance, a synthetic end-to-end GNU ld build/finalizer,
source acquisition/retry behavior, package-owned Python pruning, deterministic archives,
and package/catalog publication semantics including revision ordering, immutability,
idempotence and rolling-catalog recovery.

Regression tests must not freeze implementation spelling. They do not grep builders or
workflow YAML for particular lines, extract private functions by name, or mutate source
text to prove that another test notices the edit. A property that is only meaningful on
a finished tool package belongs to the native package qualification instead.

## Publication checks

The package publisher validates `publication.txt`, the three archive digests and the
managed release-asset set before a draft becomes public. The catalog activation path
then proves the already-published package release and copies only its concrete discovery
data into `catalog.cfg`.

Catalog tests use a local GitHub fixture to exercise the public scripts as a lifecycle:
immutable package publication, idempotent re-entry, semantic version ordering, derived
`stable`, source-catalog revision changes, rolling publication anti-rollback and
post-delete/pre-rename recovery.

## Evidence boundary

Local checks can establish shell/package algorithms and synthetic failure behavior, but
they cannot substitute for the final native matrix. In particular, parsing PowerShell is
not Windows execution, Linux fixtures do not qualify Mach-O behavior, and a synthetic
builder cannot prove that a new upstream release still configures and builds successfully.

For that reason the release evidence is the combination of repository checks, the actual
platform build, the final package contract and the tool-specific native qualification.
[Build records](BUILD_RECORDS.md) describes the diagnostic evidence retained when one of
those phases fails.
