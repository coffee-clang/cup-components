# cup-components documentation

`cup-components` is the producer repository for CUP tool packages. This documentation
is organized around the package lifecycle and repository responsibilities rather than
around individual scripts.

If you are new to the repository, read **Concepts**, **Specification** and **Packages**
first. The remaining pages explain tool-specific payloads, build environments, testing
and workflow evidence.

## Understand the producer

- [Concepts](CONCEPTS.md) — source, staging, package selection, runtime closure,
  relocatability, self-containment, metadata and the boundary with CUP.
- [Specification](SPECIFICATION.md) — supported tools/platforms, version selection,
  host/target combinations, package identity, generic package revisions and source verification.
- [Packages](PACKAGES.md) — package filesystem rules, `info.txt`, `manifest.txt`,
  archive formats, runtime closure and package-owned Python.
- [Tool packages](TOOLS.md) — the payload and deliberate capabilities owned by GCC,
  GNU `ld`, GDB, the LLVM-family tools and Valgrind.
- [Catalog](CATALOG.md) — package activation, derived stable selection, serialized source
  updates, rolling publication and administrative recovery.

These documents describe producer contracts. Tool-specific implementation
choices that do not affect a package contract remain in the builder scripts.

## Build and validate

- [Build](BUILD.md) — GitHub workflows, direct builders, source acquisition, staging,
  finalization, outputs and publication.
- [Dependencies](DEPENDENCIES.md) — build environments, upstream inputs and the
  distinction between build, runtime and logical-composition dependencies.
- [Testing](TESTING.md) — common package validation, native tool-package checks and
  repository regressions.
- [Build records](BUILD_RECORDS.md) — run identity, phase logs, source provenance,
  diagnostics and package/build inventories saved by workflows.

## Reading paths

To understand a finished package:

```text
Concepts → Specification → Packages → Tool packages → Catalog
```

To work on a producer or diagnose a build:

```text
Concepts → Build → Dependencies → Testing → Build records
```

## Sources of truth

The documentation explains contracts and mechanisms. Inventories that change as part
of normal maintenance stay with the files that own them:

- supported package scopes, default source versions and known source digests: `scripts/package/package-common.sh`;
- workflow inputs and runner selection: `.github/workflows/`;
- exact Linux builder packages: `docker/*.Dockerfile`;
- exact Windows builder packages: `scripts/setup/msys2-*-packages.txt`;
- exact macOS setup: `scripts/setup/setup-macos-builder.sh`;
- repository regressions: `tests/regression/`.

This avoids maintaining a second copy of operational inventories in prose while still
documenting what those inventories mean. Tests likewise protect observable producer
behavior rather than the textual shape of the scripts that implement it.
